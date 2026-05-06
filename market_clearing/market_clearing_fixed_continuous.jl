# FIXED HORIZON MARKET CLEARING SIMULATION
# Continuous fixed-market schedule with limited foresight:
# the visible horizon shrinks from the maximum to a minimum,
# then resets when the next day-ahead market opens.

using YAML
using JuMP
using HiGHS
using Plots
using Statistics
using Distributions

include("src/model_setup.jl")
include("src/market_model.jl")
include("src/visualisation.jl")

begin
local current_look_ahead

# Declare all loop variables as local
local clearing_count, m, q_val, g_planned_val, Qd_val, λ, SOC_val, prev_q_financial, storage_soc_carryover, prev_g_dispatch, startup_remaining

# Load configuration
cfg = YAML.load_file("input_data_rolling.yaml")
apply_simulation_month!(cfg)

# Extract parameters
rh_params = cfg["rolling_horizon"]
sim_days = Int(rh_params["simulation_days"])
max_look_ahead = Int(rh_params["look_ahead_window"])
min_look_ahead = Int(get(rh_params, "fixed_horizon_min_window", 13))
reclear_freq = Int(rh_params["reclear_frequency"])
gate_closure = Int(rh_params["gate_closure"])
forecast_noise = float(rh_params["forecast_noise_std"])
simulation_start_hour = Int(get(rh_params, "simulation_start_hour", 0))

@assert max_look_ahead >= reclear_freq "look_ahead_window must be at least reclear_frequency"
@assert min_look_ahead >= reclear_freq "fixed_horizon_min_window must be at least reclear_frequency"
@assert max_look_ahead >= min_look_ahead "look_ahead_window must be at least fixed_horizon_min_window"

simulated_delivery_hours = calculate_comparable_delivery_hours(cfg)
total_hours = simulated_delivery_hours + max_look_ahead

println("Fixed Horizon Market Clearing - Periodic Reset Mode")
println("Simulation: $sim_days days from $(lpad(simulation_start_hour, 2, '0')):00 | Reclear frequency: every $reclear_freq hour(s)")
println("Visible horizon follows fixed market calendar: $max_look_ahead -> ... -> $min_look_ahead -> $max_look_ahead")
println("Comparable delivered hours: $simulated_delivery_hours")
println("Compare to rolling horizon where the forward window stays at $max_look_ahead hours")
println("Gate closure: $gate_closure hour(s) | Peak+Wind flexible, Base+Mid+Solar locked during gate closure")
println()

data = load_input_data("input_data_rolling.yaml")
Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full = load_and_expand_timeseries(cfg, total_hours)

m_fixed = Model(HiGHS.Optimizer)
define_sets!(m_fixed, data)
IG = m_fixed.ext[:sets][:IG]
ID = m_fixed.ext[:sets][:ID]

all_results = Dict{Symbol,Any}()
all_results[:clearing_times] = Int[]
all_results[:prices] = Dict{Int, Vector{Float64}}()
all_results[:dispatch] = Dict{Int, Dict}()
all_results[:storage_energy_capacity] = float(cfg["batteryStorage"]["energyCapacity"])
all_results[:clearing_details] = Dict{Int, Dict}()

prev_g_dispatch = Dict{String, Float64}()
disp_gen_names = Set{String}(String(gname) for (gname, _) in cfg["dispatchableGenerators"])

for g in IG
    if g in disp_gen_names
        gdata = cfg["dispatchableGenerators"][g]
        init_fraction = float(get(gdata, "initGen", 0.5))
        prev_g_dispatch[g] = Q_gen_full[(g, 0)] * init_fraction
    else
        prev_g_dispatch[g] = Q_gen_full[(g, 0)]
    end
end

prev_q_financial = Dict{Tuple{String,Int},Float64}()
for g in IG
    for h in 1:max_look_ahead
        prev_q_financial[(g, h)] = 0.0
    end
end

startup_remaining = Dict{String, Int}()
for (gname, gdata) in cfg["dispatchableGenerators"]
    g = String(gname)
    if g in IG && haskey(gdata, "startupTime")
        startup_remaining[g] = 0
    end
end

forecast_error_per_hour = Dict{Int, Float64}()
storage_soc_carryover = float(cfg["batteryStorage"]["initialSOC"]) * float(cfg["batteryStorage"]["energyCapacity"])
all_executed_prices = Float64[]

clearing_count = 0
current_look_ahead = max_look_ahead

for global_hour in 1:reclear_freq:simulated_delivery_hours
    clearing_count += 1
    actual_executed_hours = min(reclear_freq, current_look_ahead, simulated_delivery_hours - global_hour + 1)

    Pr_gen_window, Q_gen_window, Pr_dem_window, Q_dem_window = get_window_timeseries(
        Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full,
        global_hour, current_look_ahead, IG, ID
    )

    disp_gen = cfg["dispatchableGenerators"]
    for (gname, gdata) in disp_gen
        g = String(gname)
        if g in IG && haskey(gdata, "startupTime")
            startup_time = Int(gdata["startupTime"])
            was_running = prev_g_dispatch[g] >= 1e-6

            if was_running
                startup_remaining[g] = 0
            elseif get(startup_remaining, g, 0) > 0
                startup_remaining[g] = max(0, startup_remaining[g] - reclear_freq)
            else
                hours_off = reclear_freq
                if clearing_count > 1 && haskey(all_results[:clearing_details], clearing_count - 1)
                    prev_clearing = all_results[:clearing_details][clearing_count - 1]
                    prev_g_planned = prev_clearing[:g_planned]

                    for h in reclear_freq:-1:1
                        if prev_g_planned[g, h] >= 1e-6
                            hours_off = reclear_freq - h
                            break
                        end
                    end
                end

                startup_remaining[g] = max(0, startup_time - hours_off)
            end

            if startup_remaining[g] > 0
                for h in 1:min(startup_remaining[g], current_look_ahead)
                    Q_gen_window[(g, h)] = 0.0
                end
            end
        end
    end

    if forecast_noise > 0.0
        add_wind_forecast_noise!(Q_gen_window, cfg, forecast_noise, IG, current_look_ahead, forecast_error_per_hour, global_hour)
    end

    var_gen_names = Set{String}(String(gname) for (gname, _) in cfg["variableGenerators"])
    for g in IG
        if g in var_gen_names
            for h in 1:actual_executed_hours
                executed_global_hour = global_hour + (h - 1)
                Q_gen_window[(g, h)] = Q_gen_full[(g, executed_global_hour)]
            end
        end
    end

    m = Model(HiGHS.Optimizer)
    set_silent(m)

    define_sets!(m, data)
    m.ext[:sets][:JH] = 1:current_look_ahead

    if clearing_count == 1
        Q_prev = Dict{Tuple{String,Int},Float64}()
        for g in IG
            for h in 1:current_look_ahead
                Q_prev[(g, h)] = prev_q_financial[(g, h)]
            end
        end
    else
        Q_prev = prepare_Q_prev_for_next_window(prev_q_financial, current_look_ahead, IG, reclear_freq)
    end

    m.ext[:timeseries] = Dict{Symbol,Any}()
    m.ext[:timeseries][:Pr_gen] = Pr_gen_window
    m.ext[:timeseries][:Q_gen] = Q_gen_window
    m.ext[:timeseries][:Pr_dem] = Pr_dem_window
    m.ext[:timeseries][:Q_dem] = Q_dem_window
    m.ext[:timeseries][:Q_prev] = Q_prev

    process_parameters!(m, data)
    m.ext[:parameters][:storage_initial_soc] = storage_soc_carryover

    effective_gate_closure = (clearing_count == 1) ? 0 : gate_closure
    m.ext[:parameters][:gate_closure] = effective_gate_closure

    flexible_generators = Set{String}(["Peak", "Wind"])
    for (gname, remaining) in startup_remaining
        if remaining > 0
            push!(flexible_generators, String(gname))
        end
    end
    m.ext[:parameters][:flexible_generators] = flexible_generators
    m.ext[:parameters][:generator_initial_dispatch] = prev_g_dispatch

    build_market_clearing!(m)
    optimize!(m)

    status = termination_status(m)
    @assert status == OPTIMAL "Optimization failed with status: $status"

    q_val = value.(m.ext[:variables][:q])
    g_planned_val = value.(m.ext[:variables][:g_planned])
    Qd_val = value.(m.ext[:variables][:Qd])

    λ = dual.(m.ext[:constraints][:energy_balance])
    prices_window = [λ[h] for h in 1:current_look_ahead]

    storage_initial_soc_dual = dual(m.ext[:constraints][:soc_h1])

    Qch_val = value.(m.ext[:variables][:Qch])
    Qdis_val = value.(m.ext[:variables][:Qdis])
    SOC_val = value.(m.ext[:variables][:SOC])

    push!(all_results[:clearing_times], global_hour)
    all_results[:prices][clearing_count] = prices_window
    all_results[:dispatch][clearing_count] = Dict(g => [g_planned_val[g, h] for h in 1:current_look_ahead] for g in IG)
    append!(all_executed_prices, prices_window[1:actual_executed_hours])

    all_results[:clearing_details][clearing_count] = Dict(
        :current_hour => global_hour,
        :look_ahead => current_look_ahead,
        :executed_hours => actual_executed_hours,
        :Q_prev => Q_prev,
        :q => q_val,
        :g_planned => g_planned_val,
        :prices => prices_window,
        :demand_base => [Qd_val["Base", h] for h in 1:current_look_ahead],
        :demand_flex => [Qd_val["Flex", h] for h in 1:current_look_ahead],
        :charging => [Qch_val[h] for h in 1:current_look_ahead],
        :discharging => [Qdis_val[h] for h in 1:current_look_ahead],
        :storage_soc_start => m.ext[:parameters][:storage_initial_soc],
        :storage_initial_soc_dual => storage_initial_soc_dual,
        :storage_soc_path => [SOC_val[h] for h in 1:current_look_ahead],
        :storage_soc_end_executed => SOC_val[actual_executed_hours],
        :storage_soc_end_window => SOC_val[current_look_ahead],
        :wind_available_h1 => Q_gen_window[("Wind", 1)],
        :wind_executed_h1 => g_planned_val["Wind", 1],
        :wind_curtailment_h1 => max(0.0, Q_gen_window[("Wind", 1)] - g_planned_val["Wind", 1])
    )

    wind_curtailment_h1 = max(0.0, Q_gen_window[("Wind", 1)] - g_planned_val["Wind", 1])
    if !haskey(all_results, :curtailment_energy)
        all_results[:curtailment_energy] = Float64[]
    end
    if wind_curtailment_h1 > 1e-6
        push!(all_results[:curtailment_energy], wind_curtailment_h1)
    end

    prev_q_financial = extract_window_commitments(g_planned_val, IG, current_look_ahead)

    for g in IG
        prev_g_dispatch[g] = g_planned_val[g, actual_executed_hours]
    end

    storage_soc_carryover = SOC_val[actual_executed_hours]

    if clearing_count <= 5 || clearing_count % 50 == 0
        λ_h1 = round(prices_window[1]; digits=1)
        if λ_h1 == -0.0
            λ_h1 = 0.0
        end
        println("Clearing $clearing_count (global hour $global_hour): Look-ahead $current_look_ahead h | Price h=1: $λ_h1 EUR/MWh | SOC_end: $(round(storage_soc_carryover; digits=1)) MWh")
    end

    next_look_ahead = current_look_ahead - reclear_freq
    current_look_ahead = next_look_ahead >= min_look_ahead ? next_look_ahead : max_look_ahead
end

println()
println("========================================")
println("SIMULATION COMPLETE")
println("========================================")

total_clearings = clearing_count
curtailment_events = haskey(all_results, :curtailment_energy) ? length(all_results[:curtailment_energy]) : 0
total_curtailment = haskey(all_results, :curtailment_energy) ? sum(all_results[:curtailment_energy]) : 0.0
if curtailment_events > 0
    println("[SUMMARY] Wind curtailment in h=1: ", curtailment_events, " hours with curtailment, totaling ", round(total_curtailment; digits=2), " MWh across ", total_clearings, " clearings.")
else
    println("[SUMMARY] No wind curtailment in h=1.")
end

println("Mode: Fixed Horizon with periodic day-ahead reset")
println("Total days simulated: $sim_days")
println("Total clearings: $clearing_count")

avg_price = mean(all_executed_prices)
min_price = minimum(all_executed_prices)
max_price = maximum(all_executed_prices)
println()
println("Price statistics (executed hours only):")
println("  Average: $(round(avg_price; digits=2)) EUR/MWh")
println("  Min: $(round(min_price; digits=2)) EUR/MWh")
println("  Max: $(round(max_price; digits=2)) EUR/MWh")
println()

p = plot_rolling_horizon_results(all_results)
savefig(p, "fixed_horizon_rolling_fixed_results.png")
println("Plot saved to: fixed_horizon_rolling_fixed_results.png")

display(p)
println()

print_battery_diagnostics(all_results)
pt = plot_price_storage_timing_diagnostics(all_results)
savefig(pt, "fixed_horizon_price_storage_timing.png")
println("Price/storage timing plot saved to: fixed_horizon_price_storage_timing.png")
display(pt)
println()

print_storage_value_diagnostics(all_results)
ps = plot_storage_value_diagnostics(all_results)
savefig(ps, "fixed_horizon_storage_value.png")
println("Storage value plot saved to: fixed_horizon_storage_value.png")
display(ps)
println()

end

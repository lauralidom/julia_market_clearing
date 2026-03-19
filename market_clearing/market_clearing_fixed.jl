# FIXED HORIZON MARKET CLEARING SIMULATION
# Multiple clearings with FIXED endpoint (shrinking look-ahead)
# Runs for ALL simulation days (default 30) for fair comparison with rolling horizon
# Each day is independent with shrinking horizon


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

# Declare all loop variables as local
local clearing_count, m, q_val, g_planned_val, Qd_val, λ, SOC_val, prev_q_financial, storage_soc_carryover, prev_g_dispatch, initial_horizon, startup_remaining

# Load configuration
cfg = YAML.load_file("input_data_rolling.yaml")
sim_days = Int(cfg["rolling_horizon"]["simulation_days"])
apply_simulation_month!(cfg)

# Extract parameters
rh_params = cfg["rolling_horizon"]
reclear_freq = Int(rh_params["reclear_frequency"])
gate_closure = Int(rh_params["gate_closure"])
forecast_noise = float(rh_params["forecast_noise_std"])

# Setup
look_ahead = 24  # Initial horizon = 24 hours (same as rolling)
num_clearings_per_day = div(24, reclear_freq)  # Number of reclearing events within 24h

println("Fixed Horizon Market Clearing - Rolling Fixed Mode")
println("Initial look-ahead: $look_ahead hours | Reclear frequency: every $reclear_freq hour(s)")
println("Look-ahead SHRINKS with each clearing (endpoint stays at hour 24)")
println("Running for $sim_days days separately")
println("Compare to rolling horizon where 24h window slides forward continuously")
println("Gate closure: $gate_closure hour(s) | Peak+Wind flexible, Base+Mid+Solar locked during gate closure")
println()

# Load entire simulation period (sim_days * 24 hours + 1 prep hour)
total_hours = sim_days * 24 + 1

# Load the base data structure
data = load_input_data("input_data_rolling.yaml")

# Load and expand time series for entire simulation
Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full = load_and_expand_timeseries(cfg, total_hours)

# Initialise sets and parameters (stay same across all windows)
m_fixed = Model(HiGHS.Optimizer)
define_sets!(m_fixed, data)
IG = m_fixed.ext[:sets][:IG]
ID = m_fixed.ext[:sets][:ID]

# Storage for results across all clearings
all_results = Dict{Symbol,Any}()
all_results[:clearing_times] = Int[]                        # Global hour of each clearing
all_results[:prices] = Dict{Int, Vector{Float64}}()         # prices[clearing] = [λ per hour]
all_results[:dispatch] = Dict{Int, Dict}()                  # dispatch[clearing][generator] = g_planned values
all_results[:storage_energy_capacity] = float(cfg["batteryStorage"]["energyCapacity"])

# Store daily end SOCs for reporting
all_results[:daily_end_soc] = Float64[]

# Detailed clearing data for analysis
all_results[:clearing_details] = Dict{Int, Dict}()

# Initialise generator dispatch for ramping constraints
prev_g_dispatch = Dict{String, Float64}()
disp_gen_names = Set{String}(String(gname) for (gname, _) in cfg["dispatchableGenerators"])

for g in IG
    if g in disp_gen_names
        # Read initGen from config (fraction of capacity)
        gdata = cfg["dispatchableGenerators"][g]
        init_fraction = float(get(gdata, "initGen", 0.5))  # default to 50% if not specified
        prev_g_dispatch[g] = Q_gen_full[(g, 0)] * init_fraction
    else
        # Variable generators: use their hour 0 availability
        prev_g_dispatch[g] = Q_gen_full[(g, 0)]
    end
end

# Initialize financial positions for gate closure (only matters for rolling_fixed)
prev_q_financial = Dict{Tuple{String,Int},Float64}()
# For first clearing in fixed rolling mode, initialize to starting dispatch
initial_horizon = 24
for g in IG
    for h in 1:initial_horizon
        prev_q_financial[(g, h)] = prev_g_dispatch[g]
    end
end

# Initialize startup tracking for dispatchable generators
startup_remaining = Dict{String, Int}()
for (gname, gdata) in cfg["dispatchableGenerators"]
    g = String(gname)
    if g in IG && haskey(gdata, "startupTime")
        startup_remaining[g] = 0  # Start warm and ready
    end
end

# Storage for accumulated results across all days
accumulated_costs = Dict{String, Float64}()
accumulated_generation = Dict{String, Float64}()
all_daily_prices = Float64[]

# ========== MAIN DAY LOOP ==========
# Run each day as a separate 24-hour market (like independent daily markets)

# Initialize wind forecast error state for AR(1) smoothing (fixed horizon)
forecast_error_per_hour = Dict{Int, Float64}()

# Keep battery SOC continuous across days in the fixed-horizon simulation.
# The market horizon still resets daily; only the physical storage state carries over.
storage_soc_carryover = float(cfg["batteryStorage"]["initialSOC"]) * float(cfg["batteryStorage"]["energyCapacity"])

clearing_count = 0

for current_day in 1:sim_days

    # Reset state for this day (each day is independent)
    # Start each day with same initial conditions for fair comparison
    prev_g_dispatch = Dict{String, Float64}()
    for g in IG
        if g in disp_gen_names
            gdata = cfg["dispatchableGenerators"][g]
            init_fraction = float(get(gdata, "initGen", 0.5))
            # Use this day's hour 0 capacity
            day_start_hour = (current_day - 1) * 24
            prev_g_dispatch[g] = Q_gen_full[(g, day_start_hour)] * init_fraction
        else
            day_start_hour = (current_day - 1) * 24
            prev_g_dispatch[g] = Q_gen_full[(g, day_start_hour)]
        end
    end
    
    # Reset financial positions for this day
    # All hours start with zero financial position (no position passed between days)
    prev_q_financial = Dict{Tuple{String,Int},Float64}()
    initial_horizon = 24
    for g in IG
        for h in 1:initial_horizon
            prev_q_financial[(g, h)] = 0.0
        end
    end
    
    # Reset startup state
    startup_remaining = Dict{String, Int}()
    for (gname, gdata) in cfg["dispatchableGenerators"]
        g = String(gname)
        if g in IG && haskey(gdata, "startupTime")
            startup_remaining[g] = 0  # Start warm and ready each day
        end
    end
    
    # Battery state stays continuous across days
    day_start_soc = storage_soc_carryover
    day_end_soc = storage_soc_carryover
    day_first_price = 0.0
    day_first_charge = 0.0
    day_first_discharge = 0.0
    
    # Define clearing schedule for this day
    # Multiple clearings with shrinking horizon within the day
    # On the last day only run the first clearing (1 executed hour) to mirror the rolling horizon,
    # which cannot start a full 24h window in the final 23 hours of the simulation.
    clearing_iterations = current_day == sim_days ? (1:1) : (1:num_clearings_per_day)
    clearing_hours = [1 + (i-1)*reclear_freq for i in clearing_iterations]
    clearing_horizons = [24 - (i-1)*reclear_freq for i in clearing_iterations]
    
    # ========== CLEARING LOOP FOR THIS DAY ==========
    for (iteration_idx, relative_hour) in zip(clearing_iterations, clearing_hours)
        clearing_count += 1
        current_look_ahead = clearing_horizons[iteration_idx]
        
        # Convert relative hour (1-24) to global hour in full timeseries
        global_hour = (current_day - 1) * 24 + relative_hour
        
        # Extract window time series using global hour
        Pr_gen_window, Q_gen_window, Pr_dem_window, Q_dem_window = get_window_timeseries(
            Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full,
            global_hour, current_look_ahead, IG, ID
        )
        
        # Apply startup time constraints
        disp_gen = cfg["dispatchableGenerators"]
        for (gname, gdata) in disp_gen
            g = String(gname)
            if g in IG && haskey(gdata, "startupTime")
                startup_time = Int(gdata["startupTime"])
                was_running = prev_g_dispatch[g] >= 1e-6
                
                # Update startup timer based on previous state
                if was_running
                    startup_remaining[g] = 0
                elseif get(startup_remaining, g, 0) > 0
                    startup_remaining[g] = max(0, startup_remaining[g] - reclear_freq)
                else
                    # Generator was off - determine startup time needed
                    hours_off = reclear_freq
                    if iteration_idx > 1
                        # Look at previous clearing within this day
                        prev_relative_hour = clearing_hours[iteration_idx - 1]
                        for h in reclear_freq:-1:1
                            # Check if generator was on
                            check_global_hour = (current_day - 1) * 24 + prev_relative_hour + (h - 1)
                            if haskey(all_results[:clearing_details], clearing_count - 1)
                                prev_clearing = all_results[:clearing_details][clearing_count - 1]
                                prev_g_planned = prev_clearing[:g_planned]
                                if prev_g_planned[g, h] >= 1e-6
                                    hours_off = reclear_freq - h
                                    break
                                end
                            end
                        end
                    end
                    startup_remaining[g] = max(0, startup_time - hours_off)
                end
                
                # Force capacity to zero during startup period
                if startup_remaining[g] > 0
                    for h in 1:min(startup_remaining[g], current_look_ahead)
                        Q_gen_window[(g, h)] = 0.0
                    end
                end
            end
        end
        
        # Add forecast noise to wind (AR(1) smoothing, fixed horizon)
        if forecast_noise > 0.0
            add_wind_forecast_noise!(Q_gen_window, cfg, forecast_noise, IG, current_look_ahead, forecast_error_per_hour, global_hour)
        end
        
        # Override executed hours with realized values
        # This corrects forecast errors: executed hours use actual wind/solar availability
        var_gen_names = Set{String}(String(gname) for (gname, _) in cfg["variableGenerators"])
        for g in IG
            if g in var_gen_names
                for h in 1:reclear_freq
                    check_global_hour = global_hour + (h - 1)
                    if check_global_hour <= (current_day * 24)
                        Q_gen_window[(g, h)] = Q_gen_full[(g, check_global_hour)]
                    end
                end
            end
        end
        
        # Create new model for this window
        m = Model(HiGHS.Optimizer)
        set_silent(m)
        
        # Define sets and parameters for this window
        define_sets!(m, data)
        
        # Manually populate time series for this window
        m.ext[:sets][:JH] = 1:current_look_ahead
        
        # Prepare Q_prev (financial positions from previous clearing)
        # Drop executed hours and reindex remaining positions
        Q_prev = prepare_Q_prev_for_next_window(prev_q_financial, current_look_ahead, IG, reclear_freq)
        
        # Store time series for this window
        m.ext[:timeseries] = Dict{Symbol,Any}()
        m.ext[:timeseries][:Pr_gen] = Pr_gen_window
        m.ext[:timeseries][:Q_gen] = Q_gen_window
        m.ext[:timeseries][:Pr_dem] = Pr_dem_window
        m.ext[:timeseries][:Q_dem] = Q_dem_window
        m.ext[:timeseries][:Q_prev] = Q_prev
        
        # Process parameters
        process_parameters!(m, data)
        
        # Pass storage SOC carryover
        m.ext[:parameters][:storage_initial_soc] = storage_soc_carryover
        
        # Pass gate closure parameter
        effective_gate_closure = (iteration_idx == 1) ? 0 : gate_closure
        m.ext[:parameters][:gate_closure] = effective_gate_closure
        
        # Pass list of generators exempt from gate closure
        flexible_generators = Set{String}(["Peak", "Wind"])
        for (gname, remaining) in startup_remaining
            if remaining > 0
                push!(flexible_generators, String(gname))
            end
        end
        m.ext[:parameters][:flexible_generators] = flexible_generators
        
        # Pass generator initial dispatch for ramping constraints
        m.ext[:parameters][:generator_initial_dispatch] = prev_g_dispatch
        
        # Build and solve
        build_market_clearing!(m)
        optimize!(m)
        
        status = termination_status(m)
        
        @assert status == OPTIMAL "Optimization failed with status: $status"
        
        # Extract results
        q_val = value.(m.ext[:variables][:q])
        g_planned_val = value.(m.ext[:variables][:g_planned])
        Qd_val = value.(m.ext[:variables][:Qd])
        
        # Extract prices (dual variables of energy balance)
        λ = dual.(m.ext[:constraints][:energy_balance])
        
        prices_window = [λ[h] for h in 1:current_look_ahead]
        
        # Extract battery variables for storage
        Qch_val = value.(m.ext[:variables][:Qch])
        Qdis_val = value.(m.ext[:variables][:Qdis])
        SOC_val = value.(m.ext[:variables][:SOC])
        
        # Store results
        push!(all_results[:clearing_times], global_hour)
        all_results[:prices][clearing_count] = prices_window
        all_results[:dispatch][clearing_count] = Dict(g => [g_planned_val[g, h] for h in 1:current_look_ahead] for g in IG)
        
        # Store detailed data for this clearing
        # Execute either reclear_freq hours OR remaining hours (whichever is smaller)
        actual_executed_hours = min(reclear_freq, current_look_ahead)

        if iteration_idx == 1
            day_first_price = prices_window[1]
            day_first_charge = Qch_val[1]
            day_first_discharge = Qdis_val[1]
        end

        day_end_soc = SOC_val[actual_executed_hours]
        
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
            :storage_soc_path => [SOC_val[h] for h in 1:current_look_ahead],
            :storage_soc_end_executed => SOC_val[actual_executed_hours],
            :storage_soc_end_window => SOC_val[current_look_ahead],
            :wind_available_h1 => Q_gen_window[("Wind", 1)],
            :wind_executed_h1 => g_planned_val["Wind", 1],
            :wind_curtailment_h1 => max(0.0, Q_gen_window[("Wind", 1)] - g_planned_val["Wind", 1])
        )

        # Print if curtailment is nonzero (tolerance 1e-6)
        wind_curtailment_h1 = max(0.0, Q_gen_window[("Wind", 1)] - g_planned_val["Wind", 1])
        if !haskey(all_results, :curtailment_energy)
            all_results[:curtailment_energy] = Float64[]
        end
        if wind_curtailment_h1 > 1e-6
            push!(all_results[:curtailment_energy], wind_curtailment_h1)
        end
        
        # Update state for next clearing within this day
        if iteration_idx < length(clearing_iterations)
            # Extract updated position for next window as financial position
            prev_q_financial = extract_window_commitments(g_planned_val, IG, current_look_ahead)
            
            # Extract dispatch at the end of executed hours for ramping
            for g in IG
                prev_g_dispatch[g] = g_planned_val[g, actual_executed_hours]
            end
            
            # Storage state continuity
            storage_soc_carryover = day_end_soc
        end

    end  # End clearing loop for this day
    
    # Accumulate daily results for averaging
    # Take only the executed hours from each clearing to avoid double-counting
    day_prices = Float64[]
    day_clearing_start = clearing_count - num_clearings_per_day + 1
    for i in 1:num_clearings_per_day
        clearing_idx = day_clearing_start + i - 1
        actual_exec_hrs = all_results[:clearing_details][clearing_idx][:executed_hours]
        executed_slice = 1:actual_exec_hrs
        append!(day_prices, all_results[:prices][clearing_idx][executed_slice])
    end
    
    append!(all_daily_prices, day_prices)

    day_avg_price = mean(day_prices)
    day_min_price = minimum(day_prices)
    day_max_price = maximum(day_prices)
    λ_h1 = round(day_first_price; digits=1)
    if λ_h1 == -0.0
        λ_h1 = 0.0
    end
    println("Day $current_day/$sim_days | P(h1): $λ_h1 €/MWh | Avg/Min/Max: $(round(day_avg_price; digits=1))/$(round(day_min_price; digits=1))/$(round(day_max_price; digits=1)) €/MWh | SOC: $(round(day_start_soc; digits=1))->$(round(day_end_soc; digits=1)) MWh | Ch/Dis(h1): $(round(day_first_charge; digits=1))/$(round(day_first_discharge; digits=1)) MW")
        # Store daily end SOC for reporting
        push!(all_results[:daily_end_soc], day_end_soc)

    # Carry the realized end-of-day SOC into the next day.
    storage_soc_carryover = day_end_soc
    
end  # End day loop

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

# Summary statistics across all days
println("Mode: Rolling Fixed (shrinking horizon within each day)")
println("Total days simulated: $sim_days")
println("Clearings per day: $num_clearings_per_day")
println("Total clearings: $clearing_count")

avg_price = mean(all_daily_prices)
min_price = minimum(all_daily_prices)
max_price = maximum(all_daily_prices)
println()
println("Price statistics (across all $sim_days days):")
println("  Average: $(round(avg_price; digits=2)) €/MWh")
println("  Min: $(round(min_price; digits=2)) €/MWh")
println("  Max: $(round(max_price; digits=2)) €/MWh")
println()

p = plot_rolling_horizon_results(all_results)
savefig(p, "fixed_horizon_rolling_fixed_results.png")
println("Plot saved to: fixed_horizon_rolling_fixed_results.png")

display(p)
println()

end

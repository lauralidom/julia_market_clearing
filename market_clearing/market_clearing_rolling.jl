# ROLLING HORIZON MARKET CLEARING SIMULATION

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
local clearing_count, m, q_val, g_planned_val, Qd_val, λ, SOC_val, prev_q_financial, storage_soc_carryover

# Load configuration
cfg = YAML.load_file("input_data_rolling.yaml")
apply_simulation_month!(cfg)

# Extract rolling horizon parameters
rh_params = cfg["rolling_horizon"]
sim_days = Int(rh_params["simulation_days"])
look_ahead = Int(rh_params["look_ahead_window"])
reclear_freq = Int(rh_params["reclear_frequency"])
gate_closure = Int(rh_params["gate_closure"])
forecast_noise = float(rh_params["forecast_noise_std"])


# Add 1 hour for prep hour (hour 0)
total_hours = sim_days * 24 + 1

println("Rolling Horizon Market Clearing Simulation")
println("Simulation: $sim_days days + 1 prep hour | Look-ahead: $look_ahead hours | Reclear frequency: every $reclear_freq hour(s)")
println("Gate closure: $gate_closure hour(s) | Peak+Wind flexible, Base+Mid+Solar locked during gate closure")
println()

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

# Detailed clearing data for analysis
all_results[:clearing_details] = Dict{Int, Dict}()

# Initialise generator dispatch for ramping constraints
# Use initial dispatch levels from config to avoid artificial ramping constraints in first clearing
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

# Set q_prev = 0 for all hours in first clearing
# All initial positions will be captured as q trades in the first clearing
# The ramping constraint (using g_init) handles physical continuity independently
prev_q_financial = Dict{Tuple{String,Int},Float64}()
for g in IG
    for h in 1:look_ahead
        # All hours start fresh - no previous intraday position
        prev_q_financial[(g, h)] = 0.0
    end
end

# Initialize startup tracking for dispatchable generators
# startup_remaining = hours until generator can produce (0 = ready, >0 = warming up)
startup_remaining = Dict{String, Int}()
for (gname, gdata) in cfg["dispatchableGenerators"]
    g = String(gname)
    if g in IG && haskey(gdata, "startupTime")
        # Start with generators warm and ready (running at 100%)
        startup_remaining[g] = 0
    end
end

# Initialise storage state across windows from input
storage_soc_carryover = float(cfg["batteryStorage"]["initialSOC"]) * float(cfg["batteryStorage"]["energyCapacity"])


# MAIN ROLLING HORIZON LOOP
# Start from hour 1 (skip hour 0 which is prep hour with zero demand)

clearing_count = 0
# Initialize wind forecast error state for AR(1) smoothing
forecast_error_per_hour = Dict{Int, Float64}()

for start_hour in 1:reclear_freq:(total_hours - look_ahead)
    clearing_count += 1
    current_hour = start_hour                                             
    
    # Print clearing header (verbose for first 5, then every 50th)
    if clearing_count <= 5 || clearing_count % 50 == 0
        print("Clearing $clearing_count (global hour $current_hour): ")
    end
    
    # Extract window time series
    Pr_gen_window, Q_gen_window, Pr_dem_window, Q_dem_window = get_window_timeseries(
        Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full,
        current_hour, look_ahead, IG, ID
    )
    
    # Apply startup time constraints
    # When a generator shuts down and later wants to restart, it needs startup_time hours
    disp_gen = cfg["dispatchableGenerators"]
    for (gname, gdata) in disp_gen
        g = String(gname)
        if g in IG && haskey(gdata, "startupTime")
            startup_time = Int(gdata["startupTime"])
            was_running = prev_g_dispatch[g] >= 1e-6
            
            # Update startup timer based on previous state
            if was_running
                # Generator was running at end of last period → warm and ready
                startup_remaining[g] = 0
            elseif get(startup_remaining, g, 0) > 0
                # Generator in startup process → decrement timer
                startup_remaining[g] = max(0, startup_remaining[g] - reclear_freq)
            else
                # Generator was off at end of last period and not already in startup
                # Need to find when it shut down to calculate how long it's been off
                hours_off = reclear_freq  # Default: assume off for entire executed period
                
                if clearing_count > 1 && haskey(all_results[:clearing_details], clearing_count - 1)
                    prev_clearing = all_results[:clearing_details][clearing_count - 1]
                    prev_g_planned = prev_clearing[:g_planned]
                    
                    # Scan backwards through executed hours to find LAST hour it was running
                    for h in reclear_freq:-1:1
                        if prev_g_planned[g, h] >= 1e-6
                            # Found last hour it was ON
                            hours_off = reclear_freq - h
                            break
                        end
                    end
                    # If never found (always off), hours_off = reclear_freq (correct default)
                end
                
                # Start countdown, accounting for hours already spent off
                startup_remaining[g] = max(0, startup_time - hours_off)
            end
            
            # If still in startup period, force capacity to zero only for hours still warming up
            if startup_remaining[g] > 0
                if clearing_count <= 5 || clearing_count % 50 == 0
                    println("  [$g starting up: $(startup_remaining[g]) hours remaining]")
                end
                # Force capacity to zero only for hours where generator is still warming up
                # After warmup completes, generator becomes available within the look-ahead window
                for h in 1:min(startup_remaining[g], look_ahead)
                    Q_gen_window[(g, h)] = 0.0
                end
            end
        end
    end
    
    # Add autocorrelated forecast noise to wind (AR(1) smoothing across windows)
    if forecast_noise > 0.0
        add_wind_forecast_noise!(Q_gen_window, cfg, forecast_noise, IG, look_ahead, forecast_error_per_hour, current_hour)
    end
    
    # Override executed hours (1 to reclear_freq) with REALIZED renewable values
    # At delivery, there's no uncertainty - we dispatch based on actual wind/solar availability
    # This ensures all clearing frequencies dispatch identical total renewable energy
    var_gen_names = Set{String}(String(gname) for (gname, _) in cfg["variableGenerators"])
    for g in IG
        if g in var_gen_names
            for h in 1:reclear_freq
                global_hour = current_hour + (h - 1)
                # Use the true value from the full timeseries (no noise)
                Q_gen_window[(g, h)] = Q_gen_full[(g, global_hour)]
            end
        end
    end
    
    # Create new model for this window
    m = Model(HiGHS.Optimizer)
    set_silent(m)  # Suppress HiGHS solver output
    
    # Define sets and parameters for this window
    define_sets!(m, data)
    
    # Manually populate time series for this window
    m.ext[:sets][:JH] = 1:look_ahead
    
    # Prepare Q_prev: Drop the executed hours (given by reclear_freq hours) and reindex 
    # the remaining financial positions relative to the new clearing time
    # For first clearing: use prev_q_financial directly (no shifting needed)
    # For subsequent clearings: shift window forward
    if clearing_count == 1
        # First clearing: use initialization directly
        Q_prev = Dict{Tuple{String,Int},Float64}()
        for g in IG
            for h in 1:look_ahead
                Q_prev[(g, h)] = prev_q_financial[(g, h)]
            end
        end
    else
        # Subsequent clearings: shift window forward
        Q_prev = prepare_Q_prev_for_next_window(prev_q_financial, look_ahead, IG, reclear_freq)
    end
    
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
    # For the first clearing, disable gate closure to allow all generators to find initial equilibrium
    # (there's no previous market clearing to enforce gate closure against)
    effective_gate_closure = (clearing_count == 1) ? 0 : gate_closure
    m.ext[:parameters][:gate_closure] = effective_gate_closure
    
    # Pass list of generators exempt from gate closure (Peak, Wind, and any in startup)
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
    q_val = value.(m.ext[:variables][:q])           # adjustment variable
    g_planned_val = value.(m.ext[:variables][:g_planned])  # updated position
    Qd_val = value.(m.ext[:variables][:Qd])     # served demand
    
    # Extract prices (dual variables of energy balance)
    λ = dual.(m.ext[:constraints][:energy_balance])
    
    prices_window = [λ[h] for h in 1:look_ahead]
    
    # Extract battery variables for storage
    Qch_val = value.(m.ext[:variables][:Qch])
    Qdis_val = value.(m.ext[:variables][:Qdis])
    SOC_val = value.(m.ext[:variables][:SOC])
    
    # Store results
    push!(all_results[:clearing_times], current_hour)
    all_results[:prices][clearing_count] = prices_window
    all_results[:dispatch][clearing_count] = Dict(g => [g_planned_val[g, h] for h in 1:look_ahead] for g in IG)
    
    # Store detailed data for this clearing (including demand and storage)
    all_results[:clearing_details][clearing_count] = Dict(
        :current_hour => current_hour,
        :executed_hours => reclear_freq,
        :look_ahead => look_ahead,
        :Q_prev => Q_prev,
        :q => q_val,
        :g_planned => g_planned_val,
        :prices => prices_window,
        :demand_base => [Qd_val["Base", h] for h in 1:look_ahead],
        :demand_flex => [Qd_val["Flex", h] for h in 1:look_ahead],
        :charging => [Qch_val[h] for h in 1:look_ahead],
        :discharging => [Qdis_val[h] for h in 1:look_ahead],
        :storage_soc_start => m.ext[:parameters][:storage_initial_soc],
        :storage_soc_path => [SOC_val[h] for h in 1:look_ahead],
        :storage_soc_end_executed => SOC_val[reclear_freq],
        :storage_soc_end_window => SOC_val[look_ahead],
        :wind_available_h1 => Q_gen_window[("Wind", 1)],
        :wind_executed_h1 => g_planned_val["Wind", 1],
        :wind_curtailment_h1 => max(0.0, Q_gen_window[("Wind", 1)] - g_planned_val["Wind", 1])
    )

    # Accumulate curtailment mismatches for summary reporting
    wind_curtailment_h1 = max(0.0, Q_gen_window[("Wind", 1)] - g_planned_val["Wind", 1])
    if !haskey(all_results, :curtailment_energy)
        all_results[:curtailment_energy] = Float64[]
    end
    if wind_curtailment_h1 > 1e-6
        push!(all_results[:curtailment_energy], wind_curtailment_h1)
    end
    
    # Extract updated position for next window as financial position
    # g_planned[g,h] from this clearing becomes q_prev[g,h] in next clearing
    prev_q_financial = extract_window_commitments(g_planned_val, IG, look_ahead)

    # Extract dispatch at the end of executed hours for ramping constraint continuity
    # The dispatch at hour reclear_freq becomes the initial dispatch for next clearing's hour 1
    for g in IG
        prev_g_dispatch[g] = g_planned_val[g, reclear_freq]
    end

    
    # Storage state continuity: pass executed hours SOC to next clearing
    # After reclear_freq hours, we need SOC at the end of those executed hours
    SOC_val = value.(m.ext[:variables][:SOC])
    storage_soc_carryover = SOC_val[reclear_freq]  # SOC after executing reclear_freq hours
    
    # KIND OF COMPLICATED LOGIC FOR PRINTING THE PRICE SETTER
    # Print diagnostics for hour 1 and final executed hour (h=reclear_freq)
    h = 1
    λ_h1 = round(prices_window[h]; digits=2)
    if λ_h1 == -0.0
        λ_h1 = 0.0
    end

    P_cap = m.ext[:parameters][:storage_power_capacity]
    E_cap = m.ext[:parameters][:storage_energy_capacity]

    Qch_val  = value.(m.ext[:variables][:Qch])
    Qdis_val = value.(m.ext[:variables][:Qdis])
    SOC_val  = value.(m.ext[:variables][:SOC])

    soc_end = round(SOC_val[h]; digits=1)

    if clearing_count <= 5 || clearing_count % 50 == 0
        println("Clearing $clearing_count (global hour $current_hour): Price h=1: $λ_h1 €/MWh | SOC_end: $soc_end MWh | Ch=$(round(Qch_val[h]; digits=1)) | Dis=$(round(Qdis_val[h]; digits=1))")
    end
end

println()

# Summary statistics - collect all prices from all clearings
all_prices = vcat([all_results[:prices][c] for c in 1:clearing_count if haskey(all_results[:prices], c)]...)
avg_price = mean(all_prices)
min_price = minimum(all_prices)
max_price = maximum(all_prices)
println("Price statistics:")
println("  Average: $(round(avg_price; digits=2)) €/MWh")
println("  Min: $(round(min_price; digits=2)) €/MWh")
println("  Max: $(round(max_price; digits=2)) €/MWh")
println()

# Plot results

total_clearings = clearing_count
curtailment_events = haskey(all_results, :curtailment_energy) ? length(all_results[:curtailment_energy]) : 0
total_curtailment = haskey(all_results, :curtailment_energy) ? sum(all_results[:curtailment_energy]) : 0.0
if curtailment_events > 0
    println("[SUMMARY] Wind curtailment in h=1: ", curtailment_events, " hours with curtailment, totaling ", round(total_curtailment; digits=2), " MWh across ", total_clearings, " clearings.")
else
    println("[SUMMARY] No wind curtailment in h=1.")
end
p = plot_rolling_horizon_results(all_results)
savefig(p, "rolling_horizon_results.png")
println("Plot saved to: rolling_horizon_results.png")
display(p)
println()

end  

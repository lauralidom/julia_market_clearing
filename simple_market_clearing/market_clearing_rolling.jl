# ROLLING HORIZON MARKET CLEARING SIMULATION

using YAML
using JuMP
using HiGHS
using Plots
using Statistics

include("src/model_setup.jl")
include("src/market_model.jl")
include("src/visualisation.jl")

begin 

# Declare all loop variables as local
local clearing_count, m, q_val, g_planned_val, Qd_val, λ, SOC_val, prev_q_financial, storage_soc_carryover

# Load configuration
cfg = YAML.load_file("input_data_rolling.yaml")

# Extract rolling horizon parameters
rh_params = cfg["rolling_horizon"]
sim_days = Int(rh_params["simulation_days"])
look_ahead = Int(rh_params["look_ahead_window"])
reclear_freq = Int(rh_params["reclear_frequency"])
forecast_noise = float(rh_params["forecast_noise_std"])

# Add 1 hour for prep hour (hour 0)
total_hours = sim_days * 24 + 1

println("Rolling Horizon Market Clearing Simulation")
println("Simulation: $sim_days days + 1 prep hour | Look-ahead: $look_ahead hours | Reclear frequency: every $reclear_freq hour(s)")
println()

# Load the base data structure
data = load_input_data("input_data_rolling.yaml")

# Load and expand time series for entire simulation
Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full = load_and_expand_timeseries(cfg, total_hours)

# Initialize sets and parameters (stay same across all windows)
m_fixed = Model(HiGHS.Optimizer)
define_sets!(m_fixed, data)
IG = m_fixed.ext[:sets][:IG]
ID = m_fixed.ext[:sets][:ID]

# Storage for results across all clearings
all_results = Dict{Symbol,Any}()
all_results[:clearing_times] = Int[]                        # Global hour of each clearing
all_results[:prices] = Dict{Int, Vector{Float64}}()         # prices[clearing] = [λ per hour]
all_results[:dispatch] = Dict{Int, Dict}()                  # dispatch[clearing][generator] = g_planned values
all_results[:infeasible_clearings] = Int[]                  # which clearings were infeasible

# Detailed clearing data for analysis
all_results[:clearing_details] = Dict{Int, Dict}()

# Set q_prev to 0 for first clearing
# q_prev[g,h] = financial position = previous g_planned value
prev_q_financial = Dict{Tuple{String,Int},Float64}()
for g in IG
    for h in 1:look_ahead
        prev_q_financial[(g, h)] = 0.0
    end
end

# Initialise storage state across windows
storage_soc_carryover = 0.0  # updated each clearing

#Initialise dictionary to hold locked hour wind availability
var_gen = cfg["variableGenerators"]
prev_Q_gen_locked = Dict{String,Float64}()
for (gname, _) in var_gen
    g = String(gname)
    if g in IG
        prev_Q_gen_locked[g] = NaN
    end
end

# MAIN ROLLING HORIZON LOOP

clearing_count = 0

for start_hour in 0:reclear_freq:(total_hours - look_ahead)
    clearing_count += 1
    current_hour = start_hour                                             
    
    # Print clearing header
    print("Clearing $clearing_count (global hour $current_hour): ")
    
    # Extract window time series
    Pr_gen_window, Q_gen_window, Pr_dem_window, Q_dem_window = get_window_timeseries(
        Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full,
        current_hour, look_ahead, IG, ID
    )
    
    # Inject previous clearing’s next-hour wind availability into current locked hour
    if clearing_count > 1
        for (gname, _) in var_gen
            g = String(gname)
            if g in IG
                Q_gen_window[(g, 1)] = prev_Q_gen_locked[g]
            end
        end
    end

    # Add forecast noise
    if forecast_noise > 0.0
        add_wind_forecast_noise!(Q_gen_window, cfg, forecast_noise, IG, look_ahead)
    end

    # Save availability for the hour that will become locked next clearing
    h_lock_next = 1 + reclear_freq
    for (gname, _) in var_gen
        g = String(gname)
        if g in IG
            prev_Q_gen_locked[g] = Q_gen_window[(g, h_lock_next)]
        end
    end
    
    # Create new model for this window
    m = Model(HiGHS.Optimizer)
    set_silent(m)  # Suppress HiGHS solver output
    
    # Define sets and parameters for this window
    define_sets!(m, data)
    
    # Manually populate time series for this window
    m.ext[:sets][:JH] = 1:look_ahead
    
    # Prepare Q_prev: shift all commitments forward by reclear_freq hours
    # This is the financial position from previous clearing
    Q_prev = prepare_Q_prev_for_next_window(prev_q_financial, look_ahead, IG, reclear_freq)
    
    # Store time series for this window
    m.ext[:timeseries] = Dict{Symbol,Any}()
    m.ext[:timeseries][:Pr_gen] = Pr_gen_window
    m.ext[:timeseries][:Q_gen] = Q_gen_window
    m.ext[:timeseries][:Pr_dem] = Pr_dem_window
    m.ext[:timeseries][:Q_dem] = Q_dem_window
    m.ext[:timeseries][:Q_prev] = Q_prev
    
    # Ensure no NaN values in Q_prev (from infeasible solutions)
    for key in keys(Q_prev)
        if isnan(Q_prev[key])
            Q_prev[key] = 0.0
        end
    end
    
    # Process parameters
    process_parameters!(m, data)
    
    # Pass storage SOC carryover
    m.ext[:parameters][:storage_initial_soc] = storage_soc_carryover
    
    # Build and solve
    build_market_clearing!(m)
    optimize!(m)
    
    status = termination_status(m)
    if status != OPTIMAL
        println("[WARNING] Non-optimal: $status")
        push!(all_results[:infeasible_clearings], clearing_count)
        # Skip this clearing if infeasible - keep previous commitments
        continue
    else
        println("Optimal")
    end
    
    # Extract results
    q_val = value.(m.ext[:variables][:q])           # adjustment variable
    g_planned_val = value.(m.ext[:variables][:g_planned])  # updated position
    Qd_val = value.(m.ext[:variables][:Qd])     # served demand
    
    # Extract prices (dual variables of energy balance)
    λ = dual.(m.ext[:constraints][:energy_balance])
    
    # DEBUG: Print generation and demand for local hours 1 and 2
    if clearing_count <= 3  # Only print for first few clearings
        global_h1 = current_hour
        global_h2 = current_hour + 1
        
        println("  Local h=1 (Global hour $global_h1) - LOCKED:")
        for g in IG
            gen_val = g_planned_val[g, 1]
            q_prev_val = m.ext[:timeseries][:Q_prev][(String(g), 1)]
            q_adj = q_val[g, 1]
            println("    $g: q_prev=$(round(q_prev_val; digits=1)), q=$(round(q_adj; digits=1)), g_planned=$(round(gen_val; digits=1)) MW")
        end
        # Print demand by segment (base + flex)
        demand_base_h1 = Qd_val["Base", 1]
        demand_flex_h1 = Qd_val["Flex", 1]
        total_demand = demand_base_h1 + demand_flex_h1
        total_gen = sum(g_planned_val[g, 1] for g in IG)
        println("  Total Demand: Base=$(round(demand_base_h1; digits=1)) MW + Flex=$(round(demand_flex_h1; digits=1)) MW = $(round(total_demand; digits=1)) MW | Total Generation: $(round(total_gen; digits=1)) MW")
        # Print battery charge/discharge
        Qch_val = value.(m.ext[:variables][:Qch])
        Qdis_val = value.(m.ext[:variables][:Qdis])
        println("  Battery: Charge=$(round(Qch_val[1]; digits=1)) MW, Discharge=$(round(Qdis_val[1]; digits=1)) MW")
        
        println("  Local h=2 (Global hour $global_h2) - FLEXIBLE:")
        for g in IG
            gen_val = g_planned_val[g, 2]
            q_prev_val = m.ext[:timeseries][:Q_prev][(String(g), 2)]
            q_adj = q_val[g, 2]
            println("    $g: q_prev=$(round(q_prev_val; digits=1)), q=$(round(q_adj; digits=1)), g_planned=$(round(gen_val; digits=1)) MW")
        end
        # Print demand by segment (base + flex)
        demand_base_h2 = Qd_val["Base", 2]
        demand_flex_h2 = Qd_val["Flex", 2]
        total_demand_h2 = demand_base_h2 + demand_flex_h2
        total_gen_h2 = sum(g_planned_val[g, 2] for g in IG)
        price_h2 = round(λ[2]; digits=2)
        println("  Total Demand: Base=$(round(demand_base_h2; digits=1)) MW + Flex=$(round(demand_flex_h2; digits=1)) MW = $(round(total_demand_h2; digits=1)) MW | Total Generation: $(round(total_gen_h2; digits=1)) MW | Price: $price_h2 €/MWh")
        # Print battery charge/discharge
        Qch_val = value.(m.ext[:variables][:Qch])
        Qdis_val = value.(m.ext[:variables][:Qdis])
        println("  Battery: Charge=$(round(Qch_val[2]; digits=1)) MW, Discharge=$(round(Qdis_val[2]; digits=1)) MW")
    end
    prices_window = [λ[h] for h in 1:look_ahead]
    
    # Extract battery variables for storage
    Qch_val = value.(m.ext[:variables][:Qch])
    Qdis_val = value.(m.ext[:variables][:Qdis])
    
    # Store results
    push!(all_results[:clearing_times], current_hour)
    all_results[:prices][clearing_count] = prices_window
    all_results[:dispatch][clearing_count] = Dict(g => [g_planned_val[g, h] for h in 1:look_ahead] for g in IG)
    
    # Store detailed data for this clearing (including demand and storage)
    all_results[:clearing_details][clearing_count] = Dict(
        :current_hour => current_hour,
        :Q_prev => Q_prev,
        :q => q_val,
        :g_planned => g_planned_val,
        :prices => prices_window,
        :demand_base => [Qd_val["Base", h] for h in 1:look_ahead],
        :demand_flex => [Qd_val["Flex", h] for h in 1:look_ahead],
        :charging => [Qch_val[h] for h in 1:look_ahead],
        :discharging => [Qdis_val[h] for h in 1:look_ahead],
        :storage_soc_start => m.ext[:parameters][:storage_initial_soc]
    )
    
    # Extract updated position for next window as financial position
    # g_planned[g,h] from this clearing becomes q_prev[g,h] in next clearing
    prev_q_financial = extract_window_commitments(g_planned_val, IG, look_ahead)
    
    # Storage state continuity: pass executed hour SOC to next clearing
    SOC_val = value.(m.ext[:variables][:SOC])
    storage_soc_carryover = SOC_val[1]  # SOC after executing hour 1 (the only realized hour)
    
    # Print clearing summary
    λ_h1 = round(prices_window[1]; digits=2)
    soc_display = round(storage_soc_carryover; digits=1)
    println("Price: $λ_h1 €/MWh | Storage SOC: $soc_display MWh")
end

println()
println("Simulation Complete")
println("Total clearings: $clearing_count")
if !isempty(all_results[:infeasible_clearings])
    println("INFEASIBLE CLEARINGS: $(join(all_results[:infeasible_clearings], ", "))")
else
    println("All clearings optimal")
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
p = plot_rolling_horizon_results(all_results)
savefig(p, "rolling_horizon_results.png")
println("Plot saved to: rolling_horizon_results.png")
display(p)
println()

# Export analysis to Excel
export_clearing_analysis_to_excel(all_results, clearing_count, IG, "clearing_analysis.xlsx")
end  

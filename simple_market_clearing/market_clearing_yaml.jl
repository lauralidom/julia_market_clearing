using YAML
using JuMP
using HiGHS
using Plots
using Statistics

# Step 1: load input data from YAML
function load_input_data(path::String)
    # Read the YAML file into a nested Julia Dict/Array structure
    cfg = YAML.load_file(path)

    # Internal data dictionary that we pass to the other functions
    data = Dict{Symbol,Any}()

    # time: number of hours in the representative day
    T = Int(cfg["nTimesteps"])
    data[:T] = T

    # generators: separate blocks for dispatchable and variable generators
    data[:dispatchableGenerators] = cfg["dispatchableGenerators"]
    data[:variableGenerators]     = get(cfg, "variableGenerators", Dict())

    # demand segments: Base and Flex demand, each with a bid and hourly quantities
    data[:demandSegments] = cfg["demand"]["segments"]

    # storage parameters
    data[:batteryStorage] = get(cfg, "batteryStorage", nothing)


    return data
end

# Step 2a: create lists for the variables (sets)
function define_sets!(m::Model, data::Dict{Symbol,Any})
    # Store all sets in a dedicated dictionary attached to the model
    m.ext[:sets] = Dict{Symbol,Any}()

    T        = data[:T]
    disp_gen = data[:dispatchableGenerators]
    var_gen  = data[:variableGenerators]
    dem      = data[:demandSegments]

    # time periods JH = {1,...,T}
    m.ext[:sets][:JH] = 1:T

    # generators IG = list of all generator names (dispatchable + variable)
    IG = String[]
    for g in keys(disp_gen)
        push!(IG, String(g))
    end
    for g in keys(var_gen)
        push!(IG, String(g))
    end
    m.ext[:sets][:IG] = IG

    # demand segments ID = list of all demand segment names (Base, Flex)
    ID = String[]
    for d in keys(dem)
        push!(ID, String(d))
    end
    m.ext[:sets][:ID] = ID

    return m
end

# Step 2b: process time-series data (turn YAML parameters into hourly prices/quantities)
function process_time_series_data!(m::Model, data::Dict{Symbol,Any})
    disp_gen = data[:dispatchableGenerators]
    var      = data[:variableGenerators]
    dem      = data[:demandSegments]

    JH = m.ext[:sets][:JH]
    IG = m.ext[:sets][:IG]
    ID = m.ext[:sets][:ID]

    # generator prices P_gen and hourly maximum quantities Q_gen[g,h]
    # stored as dictionaries keyed by (generator, hour)
    Pr_gen = Dict{Tuple{String,Int},Float64}()  # marginal cost / bid price
    Q_gen  = Dict{Tuple{String,Int},Float64}()  # available capacity per hour

    # dispatchable generators: one price and one capacity, repeated every hour
    for (gname, gdata_any) in disp_gen
        g = String(gname)
        P = float(gdata_any["bidPrice"])   # constant bid price P [EUR/MWh]
        Q = float(gdata_any["capacity"])   # constant capacity Q [MW]

        for h in JH
            Pr_gen[(g,h)] = P
            Q_gen[(g,h)]  = Q
        end
    end

    # variable generators (e.g. Wind): price is constant, quantity follows a profile
    for (gname, gdata_any) in var
        g = String(gname)
        P = float(gdata_any["bidPrice"])   # bid price (often 0 or negative)
        Q = float(gdata_any["capacity"])   # installed capacity [MW]
        profile_any = gdata_any["profile"] # availability factors per hour
        profile = [float(x) for x in profile_any]

        length(profile) == length(JH) || error("Profile for $g must have length $(length(JH)).")

        for h in JH
            af = profile[h]                # availability factor in hour h
            Pr_gen[(g,h)] = P
            Q_gen[(g,h)]  = Q * af         # available capacity = Q * profile[h]
        end
    end

    # demand side: prices Pr_dem and maximum quantities Q_dem[d,h]
    Pr_dem = Dict{Tuple{String,Int},Float64}()  # willingness to pay
    Q_dem  = Dict{Tuple{String,Int},Float64}()  # max demand per segment and hour

    # each demand segment has one bid price and an hourly quantity profile
    for (dname, ddata_any) in dem
        d = String(dname)
        P = float(ddata_any["bidPrice"])        # value of demand segment [EUR/MWh]
        q_any = ddata_any["quantity"]           # hourly max quantity
        q_vec = [float(x) for x in q_any]

        length(q_vec) == length(JH) || error("Quantity vector for demand segment $d must have length $(length(JH)).")

        for h in JH
            Pr_dem[(d,h)] = P
            Q_dem[(d,h)]  = q_vec[h]
        end
    end

    # store all time series in the model extension for later use
    m.ext[:timeseries] = Dict{Symbol,Any}()
    m.ext[:timeseries][:Pr_gen] = Pr_gen
    m.ext[:timeseries][:Q_gen]  = Q_gen
    m.ext[:timeseries][:Pr_dem] = Pr_dem
    m.ext[:timeseries][:Q_dem]  = Q_dem

    return m
end


# Step 2c: scalar parameters
function process_parameters!(m::Model, data::Dict{Symbol,Any})
    
    m.ext[:parameters] = Dict{Symbol,Any}()

    # Store storage parameters
    if data[:batteryStorage] !== nothing
        storage = data[:batteryStorage]
        m.ext[:parameters][:storage_energy_capacity] = float(storage["energyCapacity"])
        m.ext[:parameters][:storage_power_capacity] = float(storage["powerCapacity"])
        m.ext[:parameters][:storage_efficiency] = float(storage["efficiency"])
        m.ext[:parameters][:storage_initial_soc] = float(storage["initialSOC"]) * float(storage["energyCapacity"])
        m.ext[:parameters][:has_storage] = true
    else
        m.ext[:parameters][:has_storage] = false
    end
    
    return m
end

# Step 3: build market-clearing model
# initialise dictionaries for variables, expressions and constraints
function build_market_clearing!(m::Model)
    m.ext[:variables]   = Dict{Symbol,Any}()
    m.ext[:expressions] = Dict{Symbol,Any}()
    m.ext[:constraints] = Dict{Symbol,Any}()

    # load sets and time series from previous steps
    JH = m.ext[:sets][:JH]
    IG = m.ext[:sets][:IG]
    ID = m.ext[:sets][:ID]

    Pr_gen = m.ext[:timeseries][:Pr_gen]
    Q_gen  = m.ext[:timeseries][:Q_gen]
    Pr_dem = m.ext[:timeseries][:Pr_dem]
    Q_dem  = m.ext[:timeseries][:Q_dem]

    # decision variables:
    # Qg[g,h] = dispatched generation of unit g in hour h [MW]
    # Qd[d,h] = served demand of segment d in hour h [MW]
    Qd = m.ext[:variables][:Qd] = @variable(m, Qd[d in ID, h in JH] >= 0)
    Qg = m.ext[:variables][:Qg] = @variable(m, Qg[g in IG, h in JH] >= 0)

    # Storage variables
    has_storage = m.ext[:parameters][:has_storage]
    if has_storage
        E_cap = m.ext[:parameters][:storage_energy_capacity]
        P_cap = m.ext[:parameters][:storage_power_capacity]
        η = m.ext[:parameters][:storage_efficiency]
        
        # Qch[h] = charging power in hour h [MW]
        # Qdis[h] = discharging power in hour h [MW]
        # SOC[h] = state of charge at end of hour h [MWh]
        Qch = m.ext[:variables][:Qch] = @variable(m, 0 <= Qch[h in JH] <= P_cap)
        Qdis = m.ext[:variables][:Qdis] = @variable(m, 0 <= Qdis[h in JH] <= P_cap)
        SOC = m.ext[:variables][:SOC] = @variable(m, 0 <= SOC[h in JH] <= E_cap)
        SOC_init = m.ext[:parameters][:storage_initial_soc]
    end

    # OBJECTIVE: maximise welfare (value of demand minus generation cost)
    # sum_d,h P_dem(d) * Qd[d,h]  -  sum_g,h P_gen(g,h) * Qg[g,h]
    m.ext[:objective] = @objective(m, Max,
        sum(Pr_dem[(String(d),h)] * Qd[d,h] for d in ID, h in JH) -
        sum(Pr_gen[(String(g),h)] * Qg[g,h] for g in IG, h in JH)
    )

    # energy balance: in each hour, total generation equals total served demand
    #if storage, add storage charging/discharging
     if has_storage
        m.ext[:constraints][:energy_balance] = @constraint(
            m, [h in JH],
            sum(Qg[g,h] for g in IG) + Qdis[h] - Qch[h] - sum(Qd[d,h] for d in ID) == 0
        )
    else
    m.ext[:constraints][:energy_balance] = @constraint(
        m, [h in JH],
        sum(Qg[g,h] for g in IG) - sum(Qd[d,h] for d in ID) == 0
    )
    end

    # generator limits: generation cannot exceed available capacity Q_gen[g,h]
    m.ext[:constraints][:gen_limits] = @constraint(
        m, [g in IG, h in JH],
        Qg[g,h] <= Q_gen[(String(g),h)]
    )

    # demand limits: served demand cannot exceed maximum quantity Q_dem[d,h]
    m.ext[:constraints][:dem_limits] = @constraint(
        m, [d in ID, h in JH],
        Qd[d,h] <= Q_dem[(String(d),h)]
    )

    # Storage constraints
    if has_storage
        η = m.ext[:parameters][:storage_efficiency]
        
        # State of charge dynamics: SOC[h] = SOC[h-1] + η*Qch[h] - Qdis[h]/η
        # For first hour h=1, use initial SOC
        @constraint(m, SOC[1] == SOC_init + η * Qch[1] - Qdis[1] / η)
        
        for h in 2:length(JH)
            @constraint(m, SOC[h] == SOC[h-1] + η * Qch[h] - Qdis[h] / η)
        end
        
        # Cyclic constraint: end where you started (optional, but good for daily optimization)
        @constraint(m, SOC[end] == 0)
    end

    return m
end

# Step 4: solve model and plot prices
data = load_input_data("input_data.yaml")  # adjust filename if needed

# create the optimisation model with HiGHS as the solver
m = Model(HiGHS.Optimizer)

# build the sets, time series and parameters based on the YAML data
define_sets!(m, data)
process_time_series_data!(m, data)
process_parameters!(m, data)

# create variables, constraints and objective, then solve
build_market_clearing!(m)
optimize!(m)

println("Termination status: ", termination_status(m))
println("Objective value: ", objective_value(m))


# extract optimal dispatch for generators and demand segments
Qg_val = value.(m.ext[:variables][:Qg])
Qd_val = value.(m.ext[:variables][:Qd])

# Extract storage results if available
if m.ext[:parameters][:has_storage]
    Qch_val = value.(m.ext[:variables][:Qch])
    Qdis_val = value.(m.ext[:variables][:Qdis])
    SOC_val = value.(m.ext[:variables][:SOC])
end

# compute hourly market-clearing prices as duals of the energy balance constraints
JH = m.ext[:sets][:JH]
λ  = dual.(m.ext[:constraints][:energy_balance])   # hourly prices [EUR/MWh]

hours  = collect(JH)
prices = [λ[h] for h in JH]

# Dispatch check for any hour, to print
println("\n=== Hour 3 dispatch check ===")
h = 3
println("Wind generation: ", value(m.ext[:variables][:Qg]["Wind", h]))
println("Base generation: ", value(m.ext[:variables][:Qg]["Base", h]))
println("Peak generation: ", value(m.ext[:variables][:Qg]["Peak", h]))
println("Total generation: ", sum(value(m.ext[:variables][:Qg][g, h]) for g in m.ext[:sets][:IG]))
println("Total demand: ", sum(value(m.ext[:variables][:Qd][d, h]) for d in m.ext[:sets][:ID]))
if m.ext[:parameters][:has_storage]
    println("Charging: ", value(m.ext[:variables][:Qch][h]))
    println("Discharging: ", value(m.ext[:variables][:Qdis][h]))
end

#--------------------------
# Function to plot market equilibrium
function plot_market_equilibrium(m::Model, h::Int)
    # Extract the necessary data
    Pr_gen = m.ext[:timeseries][:Pr_gen]
    Q_gen  = m.ext[:timeseries][:Q_gen]
    Pr_dem = m.ext[:timeseries][:Pr_dem]
    Q_dem  = m.ext[:timeseries][:Q_dem]
    
    IG = m.ext[:sets][:IG]
    ID = m.ext[:sets][:ID]

    # Collect generator (supply) data for hour h
    supply_prices = Float64[]
    supply_quantities = Float64[]
    for g in IG
        push!(supply_prices, Pr_gen[(g, h)])
        push!(supply_quantities, Q_gen[(g, h)])
    end

    # Collect demand data for hour h
    demand_prices = Float64[]
    demand_quantities = Float64[]
    for d in ID
        push!(demand_prices, Pr_dem[(d, h)])
        push!(demand_quantities, Q_dem[(d, h)])
    end

    # Sort supply by price (ascending - merit order)
    supply_order = sortperm(supply_prices)
    supply_prices = supply_prices[supply_order]
    supply_quantities = supply_quantities[supply_order]
    
    # Sort demand by price (descending)
    demand_order = sortperm(demand_prices, rev=true)
    demand_prices = demand_prices[demand_order]
    demand_quantities = demand_quantities[demand_order]
    
    # Create step functions for supply curve
    supply_x = Float64[]
    supply_y = Float64[]
    cumsum_q = 0.0
    for i in 1:length(supply_prices)
        # Horizontal line at current price level
        push!(supply_x, cumsum_q)
        push!(supply_y, supply_prices[i])
        cumsum_q += supply_quantities[i]
        push!(supply_x, cumsum_q)
        push!(supply_y, supply_prices[i])
    end
    
    # Create step functions for demand curve
    demand_x = Float64[]
    demand_y = Float64[]
    cumsum_q = 0.0
    for i in 1:length(demand_prices)
        # Horizontal line at current price level
        push!(demand_x, cumsum_q)
        push!(demand_y, demand_prices[i])
        cumsum_q += demand_quantities[i]
        push!(demand_x, cumsum_q)
        push!(demand_y, demand_prices[i])
    end
    
    # Plot
    p = plot(xlabel="Quantity (MW)", ylabel="Price (EUR/MWh)", 
             title="Market Equilibrium - Hour $h", legend=:best, 
             xlims = (0, maximum([supply_x; demand_x])), 
             ylims = (0, maximum([supply_y; demand_y]) * 1.05))
    
    plot!(p, supply_x, supply_y, label="Supply", color=:blue, linewidth=2)
    plot!(p, demand_x, demand_y, label="Demand", color=:red, linewidth=2)
    
    return p
end

#-----
# Create comprehensive visualization
if m.ext[:parameters][:has_storage]
    # Plot 1: Market prices with storage operation overlay
    p1 = plot(hours, prices, 
            xlabel="Hour", ylabel="Price (EUR/MWh)", 
            title="Market Prices & Storage Operation",
            label="Price", color=:black, lw=2, legend=:topleft)

    # Create a second y-axis for storage power
    p1_twin = twinx(p1)

    # Overlay charging/discharging as bars
    charge_bars = [Qch_val[h] > 0.1 ? Qch_val[h] : NaN for h in JH]
    discharge_bars = [Qdis_val[h] > 0.1 ? Qdis_val[h] : NaN for h in JH]

    bar!(p1_twin, hours, charge_bars, 
        alpha=0.3, color=:blue, 
        label="Charging", ylabel="Storage Power (MW)")
    bar!(p1_twin, hours, discharge_bars, 
        alpha=0.3, color=:red, 
        label="Discharging")
    
    # Plot 2: State of Charge
    p2 = plot(hours, [SOC_val[h] for h in JH], 
              xlabel="Hour", ylabel="Energy (MWh)", 
              title="Battery State of Charge",
              label="SOC", color=:green, lw=2, fill=(0, 0.2, :green))
    hline!(p2, [m.ext[:parameters][:storage_energy_capacity]], 
           label="Max Capacity", ls=:dash, color=:red)
    
    # Plot 3: Generation stack
    IG = m.ext[:sets][:IG]
    gen_data = Dict{String, Vector{Float64}}()
    for g in IG
        gen_data[g] = [value(m.ext[:variables][:Qg][g,h]) for h in JH]
    end

    # Define consistent colors
    gen_colors = [:steelblue, :lightgreen, :coral, :orange]

    # Manual stacking order: Base -> Wind -> Peak -> Storage
    stack_order = ["Base", "Wind", "Peak"]

    # Build matrix for areaplot (each row is a generator, each column is an hour)
    stack_matrix = zeros(length(stack_order), length(JH))
    for (i, g) in enumerate(stack_order)
        if g in IG
            stack_matrix[i, :] = gen_data[g]
        end
    end

    # Add storage discharge as another row
    discharge_vec = [Qdis_val[h] for h in JH]
    if maximum(discharge_vec) > 0.1
        stack_matrix = vcat(stack_matrix, discharge_vec')
        labels = [stack_order; "Storage Discharge"]
    else
        labels = stack_order
    end

    # Calculate max y for limits
    ID = m.ext[:sets][:ID]
    total_demand = [sum(value(m.ext[:variables][:Qd][d,h]) for d in ID) for h in JH]
    charging_vec = [Qch_val[h] for h in JH]
    max_y = maximum(total_demand .+ charging_vec) * 1.1

    # Create stacked area plot
    p3 = plot(xlabel="Hour", ylabel="Power (MW)",
            title="Generation & Demand Stack",
            legend=:topright,
            ylims=(0, max_y))

    # Stack manually using areaplot with seriestype
    for i in 1:size(stack_matrix, 1)
        if i == 1
            plot!(p3, hours, stack_matrix[i, :],
                fillrange=0, label=labels[i], 
                color=gen_colors[i], alpha=0.8, linewidth=0)
        else
            cumsum_prev = vec(sum(stack_matrix[1:i-1, :], dims=1))
            cumsum_curr = vec(sum(stack_matrix[1:i, :], dims=1))
            plot!(p3, hours, cumsum_curr,
                fillrange=cumsum_prev, label=labels[i],
                color=gen_colors[i], alpha=0.8, linewidth=0)
        end
    end

    # Add demand line on top
    plot!(p3, hours, total_demand .+ charging_vec,
        label="Demand + Charging", color=:black, lw=3, ls=:dash)
    
    # Plot 4: Merit order for a specific hour
    p4 = plot_market_equilibrium(m, 3)  # can change hour
    
    # Combine all plots
    plot(p1, p2, p3, p4, layout=(2,2), size=(1400, 1000), 
        left_margin=5Plots.mm, bottom_margin=5Plots.mm, 
        top_margin=3Plots.mm, right_margin=5Plots.mm)
    
else
    # Without storage: simpler visualization
    p1 = plot(hours, prices, 
              xlabel="Hour", ylabel="Price (EUR/MWh)", 
              title="Market-clearing price per hour",
              marker=:circle, legend=false)
    
    p2 = plot_market_equilibrium(m, 3) # can change hour
    
    plot(p1, p2, layout=(1,2), size=(1200, 400))
end

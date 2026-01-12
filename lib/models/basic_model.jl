module BasicModel

using JuMP
using HiGHS

	# Step 2a: create lists for the variables (sets) - note the !, we are modifying the model.

#=
    Why do we create sets here?
    1. They are attached to the model via the ext (extension) dictionary.
    2. They are (actually not) then used in step 2a as collections to iterate through in order to add even more to the model via m.ext for all of the timeseries data for bids over time.
    3. They are used to create variables in the creation of the clearing model itself (Step 3).
=#


function define_sets!(m::Model, data::Dict{Symbol,Any})
    # Store all sets in a dedicated dictionary attached to the model
    m.ext[:sets] = Dict{Symbol,Any}()

    T        = data[:T]
    disp_gen = data[:dispatchableGenerators]
    var_gen  = data[:variableGenerators]
    dem      = data[:demandSegments]

    # time periods JH = {1,...,T} - CH is the same (clearing hours) for the basic model
    m.ext[:sets][:CH] = m.ext[:sets][:JH] = 1:T

    # generators IG = list of all generator names (dispatchable + variable)
    IG = String[]
    for g in keys(disp_gen) # ["Base", "Peak"]
        push!(IG, String(g))
    end
    for g in keys(var_gen) # ["Wind"]
        push!(IG, String(g))
    end
    m.ext[:sets][:IG] = IG

    # demand segments ID = list of all demand segment names (Base, Flex)
    ID = String[]
    for d in keys(dem) # ["Base", "Flex"]
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

    JH = m.ext[:sets][:JH] # JH is used
    IG = m.ext[:sets][:IG] # i think that IG and ID are actually not used in this function - it's working from the YAML-based dict directly
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

        length(profile) == length(JH) || error("Profile for $g must have length $(length(JH)).") # Note use of julia-style || as conditional here.


        # This block modifies the capacity with the availability factor (profile) from the config
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

        length(q_vec) == length(JH) || error("Quantity vector for demand segment $d must have length $(length(JH)).") # Note use of julia-style || as conditional here.

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


# Step 2c: scalar parameters AKA add storage, at least for now. How will this change when storage actually bids as a market player? Likely they belong in the above bids, but they're more complex, b/c for example they can't charge and discharge at the same time.
function process_parameters!(m::Model, data::Dict{Symbol,Any})
    
    m.ext[:parameters] = Dict{Symbol,Any}()

    # Store storage parameters
    if data[:batteryStorage] !== nothing
        storage = data[:batteryStorage]
        m.ext[:parameters][:storage_energy_capacity] = float(storage["energyCapacity"])
        m.ext[:parameters][:storage_power_capacity] = float(storage["powerCapacity"])
        m.ext[:parameters][:storage_efficiency] = float(storage["efficiency"])
        m.ext[:parameters][:storage_initial_soc] = float(storage["initialSOC"]) * float(storage["energyCapacity"])
        m.ext[:parameters][:storage_end_soc] = float(storage["endSOC"]) * float(storage["energyCapacity"])
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
        SOC_end = m.ext[:parameters][:storage_end_soc]
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
        @constraint(m, SOC[end] == SOC_end)
    end

    # Question: is there an explicit "you can't charge and discharge at the same timestep" constraint? Maybe this isn't needed explicitly.

    return m
end

# it would be nice if here we could make the config switch between some different model options

function build(data)

	# create the optimisation model with HiGHS as the solver
	m = Model(HiGHS.Optimizer)

	# build the sets, time series and parameters based on the YAML data
	define_sets!(m, data)
	process_time_series_data!(m, data)
	process_parameters!(m, data)

	# create variables, constraints and objective, then solve
	build_market_clearing!(m)

	return m
end

end;
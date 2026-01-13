module RollingModelWithRampRates

using JuMP
using HiGHS

include("../helpers/helper_input_data.jl")

# NOTE: THIS IS A COPY OF THE ROLLING MODEL with an attempt to incorporate ramp rate constraints - TA 2025-12-31

	# Step 2a: create lists for the variables (sets) - note the !, we are modifying the model.

#=
    Why do we create sets here?
    1. They are attached to the model via the ext (extension) dictionary.
    2. They are (actually not) then used in step 2a as collections to iterate through in order to add even more to the model via m.ext for all of the timeseries data for bids over time.
    3. They are used to create variables in the creation of the clearing model itself (Step 3).
=#


function define_sets!(m::Model, data::Dict{Symbol,Any}, start_at_period::Int)
    # Store all sets in a dedicated dictionary attached to the model
    m.ext[:sets] = Dict{Symbol,Any}()

    T        = data[:T]
    disp_gen = data[:dispatchableGenerators]
    var_gen  = data[:variableGenerators]
    dem      = data[:demandSegments]

    days = data[:clearForDays]
    clearingInterval = data[:clearingInterval]
    clearingWindow = data[:clearingWindow]

    # time periods JH = {1,...,T}
    m.ext[:sets][:JH] = 1:T*days # all periods in the whole set, this is not great as there is an assumption here that 24 is always the input data length and they are hours - TODO: fix this
    m.ext[:sets][:CH] = start_at_period : (clearingWindow + start_at_period  - 1)   # periods for this clearing window, note -1 b/c 1 indexed
    m.ext[:sets][:ClearingInterval] = clearingInterval     # clearing interval dictates how often we clear the market

    # generators IG = list of all generator names (dispatchable + variable)
    IG = String[]
    DG = String[]
    for g in keys(disp_gen) # ["Base", "Peak"]
        push!(IG, String(g))
        push!(DG, String(g))
    end
    m.ext[:sets][:DG] = DG
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
function process_time_series_data!(m::Model, data::Dict{Symbol,Any}, start_at_period::Int)
    disp_gen = data[:dispatchableGenerators]
    var      = data[:variableGenerators]
    dem      = data[:demandSegments]

    JH = m.ext[:sets][:JH] # JH is the number of hours/periods across all periods in the set (potentially many days)
    CH = m.ext[:sets][:CH] # (adds start_at_period to each element of CH vector), minus 1 because 1 indexed # CH is the number of hours/periods for the clearing window

    # generator prices P_gen and hourly maximum quantities Q_gen[g,h]
    # stored as dictionaries keyed by (generator, hour)
    Pr_gen = Dict{Tuple{String,Int},Float64}()  # marginal cost / bid price
    Q_gen  = Dict{Tuple{String,Int},Float64}()  # available capacity per hour

    # dispatchable generators: one price and one capacity, repeated every hour
    for (gname, gdata_any) in disp_gen
        g = String(gname)
        P = float(gdata_any["bidPrice"])   # constant bid price P [EUR/MWh]
        Q = float(gdata_any["capacity"])   # constant capacity Q [MW]

        for h in CH
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

        # length(profile) == length(JH) || error("Profile for $g must have length $(length(JH)).") # Note: this condition does not apply, we will be duplicating the data for now if it is not long enough.


        # This block modifies the capacity with the availability factor (profile) from the config
        for h in CH
            profileH = (h % length(profile)) + 1 # modulo operator here makes af below repeat the input profile to fill +1 b/c these are not zero indexed
            af = profile[profileH]                # availability factor in hour profileH
            Pr_gen[(g,h)] = P
            Q_gen[(g,h)]  = Q * af         # available capacity = Q * profile[h]
        end

        println("NOISE LEVEL HERE:::", haskey(data,:noiseLevel) && data[:noiseLevel])

        if haskey(data,:noiseLevel) && data[:noiseLevel] > 0
            noise_std = float(data[:noiseLevel]) 
            HelperInputData.add_noise!(Q_gen, g, Q, noise_std, CH[1], CH[length(CH)])
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

        # length(q_vec) == length(JH) || error("Quantity vector for demand segment $d must have length $(length(JH)).") # Note: this condition does not apply, we will be duplicating the data for now if it is not long enough.

        for h in CH
            demandH = (h % length(q_vec)) + 1 # modulo here repeats the data in the demand quantity input over the requested days +1 b/c these are not zero index
            Pr_dem[(d,h)] = P
            Q_dem[(d,h)]  = q_vec[demandH] # similar to above, use the demandH here to repeat demand profile each day
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
function process_parameters!(m::Model, data::Dict{Symbol,Any},previous_hour_data)
    
    m.ext[:parameters] = Dict{Symbol,Any}()

    # Store storage parameters
    if data[:batteryStorage] !== nothing
        storage = data[:batteryStorage]
        m.ext[:parameters][:storage_energy_capacity] = float(storage["energyCapacity"])
        m.ext[:parameters][:storage_power_capacity] = float(storage["powerCapacity"])
        m.ext[:parameters][:storage_efficiency] = float(storage["efficiency"])
        m.ext[:parameters][:storage_initial_soc] = haskey(previous_hour_data,:SOC) ? previous_hour_data[:SOC] : float(storage["initialSOC"]) * float(storage["energyCapacity"])
        
        if haskey(storage, "useEndSOCRange") && storage["useEndSOCRange"]
            m.ext[:parameters][:storage_end_soc_high] = float(storage["endSOCRange"][2]) * float(storage["energyCapacity"])
            m.ext[:parameters][:storage_end_soc_low] = float(storage["endSOCRange"][1]) * float(storage["energyCapacity"])
            m.ext[:parameters][:use_end_soc_range] = true
        else
            m.ext[:parameters][:storage_end_soc] = float(storage["endSOC"]) * float(storage["energyCapacity"])
            m.ext[:parameters][:use_end_soc_range] = false
        end
        m.ext[:parameters][:has_storage] = true
    else
        m.ext[:parameters][:has_storage] = false
    end

    m.ext[:parameters][:ramp_rate] = Dict{String,Float64}()
    m.ext[:parameters][:previous_hour_dispatch] = Dict{String,Float64}()
    for (g, gen_config) in data[:dispatchableGenerators]
        m.ext[:parameters][:ramp_rate][g] = float(max(gen_config["rampRate"] *.01 * 60 * gen_config["capacity"], gen_config["capacity"]))
        m.ext[:parameters][:previous_hour_dispatch][g] = previous_hour_data[:Q_gen][g]
    end

    m.ext[:parameters][:storage_value] = data[:storageValue]
    
    return m
end

# Step 3: build market-clearing model
# initialise dictionaries for variables, expressions and constraints
function build_market_clearing!(m::Model, start_at_period::Int)
    m.ext[:variables]   = Dict{Symbol,Any}()
    m.ext[:expressions] = Dict{Symbol,Any}()
    m.ext[:constraints] = Dict{Symbol,Any}()

    # load sets and time series from previous steps
    # note that this section now selects the data from the time slice we are interested in
    CH = m.ext[:sets][:CH] # (adds start_at_period to each element of CH vector), minus 1 because 1 indexed
    IG = m.ext[:sets][:IG] # set of all generators, including VRES
    DG = m.ext[:sets][:DG] # set of only dispatchable generators, for additional constraints
    ID = m.ext[:sets][:ID]

    Pr_gen = m.ext[:timeseries][:Pr_gen]
    Q_gen  = m.ext[:timeseries][:Q_gen]
    Pr_dem = m.ext[:timeseries][:Pr_dem]
    Q_dem  = m.ext[:timeseries][:Q_dem]

    # decision variables:
    # Qg[g,h] = dispatched generation of unit g in hour h [MW]
    # Qd[d,h] = served demand of segment d in hour h [MW]
    Qd = m.ext[:variables][:Qd] = @variable(m, Qd[d in ID, h in CH] >= 0)
    Qg = m.ext[:variables][:Qg] = @variable(m, Qg[g in IG, h in CH] >= 0)

    # Storage variables
    has_storage = m.ext[:parameters][:has_storage]
    if has_storage
        E_cap = m.ext[:parameters][:storage_energy_capacity]
        P_cap = m.ext[:parameters][:storage_power_capacity]
        η = m.ext[:parameters][:storage_efficiency]
        
        # Qch[h] = charging power in hour h [MW]
        # Qdis[h] = discharging power in hour h [MW]
        # SOC[h] = state of charge at end of hour h [MWh]
        Qch = m.ext[:variables][:Qch] = @variable(m, 0 <= Qch[h in CH] <= P_cap)
        Qdis = m.ext[:variables][:Qdis] = @variable(m, 0 <= Qdis[h in CH] <= P_cap)
        SOC = m.ext[:variables][:SOC] = @variable(m, 0 <= SOC[h in CH] <= E_cap)
        SOC_init = m.ext[:parameters][:storage_initial_soc]
    end

    # OBJECTIVE: maximise welfare (value of demand minus generation cost)
    # sum_d,h P_dem(d) * Qd[d,h]  -  sum_g,h P_gen(g,h) * Qg[g,h]
    m.ext[:objective] = @objective(m, Max,
        (m.ext[:parameters][:storage_value] * SOC[CH[length(CH)]]) + # note this line add a valuation to the stored energy at the end of the window - just a preset parameter for now
        sum(Pr_dem[(String(d),h)] * Qd[d,h] for d in ID, h in CH) -
        sum(Pr_gen[(String(g),h)] * Qg[g,h] for g in IG, h in CH)
    )

    # energy balance: in each hour, total generation equals total served demand
    #if storage, add storage charging/discharging
    if has_storage
        m.ext[:constraints][:energy_balance] = @constraint(
            m, [h in CH],
            sum(Qg[g,h] for g in IG) + Qdis[h] - Qch[h] - sum(Qd[d,h] for d in ID) == 0
        )
    else
        m.ext[:constraints][:energy_balance] = @constraint(
            m, [h in CH],
            sum(Qg[g,h] for g in IG) - sum(Qd[d,h] for d in ID) == 0
        )
    end

    # generator limits: generation cannot exceed available capacity Q_gen[g,h]
    m.ext[:constraints][:gen_limits] = @constraint(
        m, [g in IG, h in CH],
        Qg[g,h] <= Q_gen[(String(g),h)]
    )

    # using DG here so this only applies to the dispatchable gens

    m.ext[:constraints][:ramp_limits] = @constraint(
        m, [g in DG, h in range(CH[1],CH[1])], # for the first hour
        m.ext[:parameters][:previous_hour_dispatch][g] - m.ext[:parameters][:ramp_rate][g] <= Qg[g,h] <= m.ext[:parameters][:previous_hour_dispatch][g] + m.ext[:parameters][:ramp_rate][g]
    )

    m.ext[:constraints][:ramp_limits] = @constraint(
        m, [g in DG, h in CH[2:end] ], # start with the second hour
        Qg[g,h] <= Qg[g,h-1] + m.ext[:parameters][:ramp_rate][g]
    )

     m.ext[:constraints][:ramp_limits] = @constraint(
        m, [g in DG, h in CH[2:end] ], # start with the second hour
        Qg[g,h] >= Qg[g,h-1] - m.ext[:parameters][:ramp_rate][g]
    )

    # demand limits: served demand cannot exceed maximum quantity Q_dem[d,h]
    m.ext[:constraints][:dem_limits] = @constraint(
        m, [d in ID, h in CH],
        Qd[d,h] <= Q_dem[(String(d),h)]
    )

    # Storage constraints
    if has_storage
        η = m.ext[:parameters][:storage_efficiency]
        
        # State of charge dynamics: SOC[h] = SOC[h-1] + η*Qch[h] - Qdis[h]/η
        # For first hour h=start_at_period, use initial SOC
        #  feed forward the SOC result from the previous round
        println("constrain this storage to start at the initial SOC $SOC_init")
        @constraint(m, SOC[start_at_period] == SOC_init + η * Qch[start_at_period] - Qdis[start_at_period] / η)
        
        # interperiod constraints for hours 2+
        for h in range(start_at_period + 1,(start_at_period -1)+length(CH))
            @constraint(m, SOC[h] == SOC[h-1] + η * Qch[h] - Qdis[h] / η)
        end
        
        # Cyclic constraint: end at a specific SOC or within a range
        # TODO: think about whether this would ever leave SOC not at low end of range (realize all the value in the storage) - maybe this is fixed by explicitly pricing the storage
        if m.ext[:parameters][:use_end_soc_range]
            @constraint(m, SOC[start_at_period+length(CH) - 1] <= m.ext[:parameters][:storage_end_soc_high])
            @constraint(m, SOC[start_at_period+length(CH) - 1] >= m.ext[:parameters][:storage_end_soc_low])
        else
            @constraint(m, SOC[start_at_period+length(CH) - 1] == m.ext[:parameters][:storage_end_soc])
        end
    end

    # Question: is there an explicit "you can't charge and discharge at the same timestep" constraint? Maybe this isn't needed explicitly.

    return m
end

# the config switches between some different model options

function build_for_hour(data, hour::Int, previous_hour_data)

	# create the optimisation model with HiGHS as the solver

    m = Model(HiGHS.Optimizer)

	# build the sets, time series and parameters based on the YAML data
	define_sets!(m, data, hour)
	process_time_series_data!(m, data, hour)
	process_parameters!(m, data, previous_hour_data)

	# create variables, constraints and objective, then solve
	build_market_clearing!(m, hour)

	return m
end

end;
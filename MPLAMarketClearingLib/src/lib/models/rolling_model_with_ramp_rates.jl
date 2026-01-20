module RollingModelWithRampRates

using JuMP
using HiGHS

include("../helpers/helper_input_data.jl")

# NOTE: THIS IS A COPY OF THE ROLLING MODEL which incorporates ramp rate constraints - TA 2025-12-31

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

    disp_gen = data[:dispatchableGenerators]
    var_gen  = data[:variableGenerators]
    dem      = data[:demandSegments]

    days = data[:clearForDays]
    clearingInterval = data[:clearingInterval]
    clearingWindow = data[:clearingWindow]

    # time periods JH = {1,...,T}
    m.ext[:sets][:JH] = 1:data[:timePeriodsPerDay]*days # all periods in the whole set
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

    JH = m.ext[:sets][:JH] # JH is the number of periods across all periods in the set (potentially many days)
    CH = m.ext[:sets][:CH] # CH is the number of periods for the clearing window

    # generator prices P_gen and hourly maximum quantities Q_gen[g,h]
    # stored as dictionaries keyed by (generator, time period)
    Pr_gen = Dict{Tuple{String,Int},Float64}()  # marginal cost / bid price
    Q_gen  = Dict{Tuple{String,Int},Float64}()  # available capacity per time period

    # dispatchable generators: one price and one capacity, repeated every time period
    for (gname, gdata_any) in disp_gen
        g = String(gname)
        P = float(gdata_any["bidPrice"])   # constant bid price P [EUR/MWh]
        Q = float(gdata_any["capacity"])   # constant capacity Q [MW]

        for t in CH
            Pr_gen[(g,t)] = P
            Q_gen[(g,t)]  = Q
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
        for t in CH
            profileH = (t % length(profile)) + 1 # modulo operator here makes af below repeat the input profile to fill +1 b/c these are not zero indexed
            af = profile[profileH]                # availability factor in hour profileH
            Pr_gen[(g,t)] = P
            Q_gen[(g,t)]  = Q * af         # available capacity = Q * profile[t]
        end

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

        for t in CH
            demandH = (t % length(q_vec)) + 1 # modulo here repeats the data in the demand quantity input over the requested days +1 b/c these are not zero index
            Pr_dem[(d,t)] = P
            Q_dem[(d,t)]  = q_vec[demandH] # similar to above, use the demandH here to repeat demand profile each day
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
function process_parameters!(m::Model, data::Dict{Symbol,Any},previous_time_period_data)
    
    m.ext[:parameters] = Dict{Symbol,Any}()

    # Store storage parameters
    if data[:batteryStorage] !== nothing
        storage = data[:batteryStorage]
        m.ext[:parameters][:storage_energy_capacity] = float(storage["energyCapacity"])
        m.ext[:parameters][:storage_power_capacity] = float(storage["powerCapacity"])
        m.ext[:parameters][:storage_efficiency] = float(storage["efficiency"])
        m.ext[:parameters][:storage_initial_soc] = haskey(previous_time_period_data,:SOC) ? previous_time_period_data[:SOC] : float(storage["initialSOC"]) * float(storage["energyCapacity"])
        
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
    m.ext[:parameters][:previous_time_period_dispatch] = Dict{String,Float64}()
    timePeriodMinutes = 24*60 / data[:timePeriodsPerDay] # minutes per day / time periods per day
    for (g, gen_config) in data[:dispatchableGenerators]
        m.ext[:parameters][:ramp_rate][g] = float(max(gen_config["rampRate"] *.01 * .5 * timePeriodMinutes * gen_config["capacity"], gen_config["capacity"]))
        m.ext[:parameters][:previous_time_period_dispatch][g] = previous_time_period_data[:Q_gen][g]
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
    # Qg[g,t] = dispatched generation of unit g in time period t [MW]
    # Qd[d,t] = served demand of segment d in time period t [MW]
    Qd = m.ext[:variables][:Qd] = @variable(m, Qd[d in ID, t in CH] >= 0)
    Qg = m.ext[:variables][:Qg] = @variable(m, Qg[g in IG, t in CH] >= 0)

    # Storage variables
    has_storage = m.ext[:parameters][:has_storage]
    if has_storage
        E_cap = m.ext[:parameters][:storage_energy_capacity]
        P_cap = m.ext[:parameters][:storage_power_capacity]
        η = m.ext[:parameters][:storage_efficiency]
        
        # Qch[t] = charging power in  time period t [MW]
        # Qdis[t] = discharging power in  time period t [MW]
        # SOC[t] = state of charge at end of  time period t [MWh]
        Qch = m.ext[:variables][:Qch] = @variable(m, 0 <= Qch[t in CH] <= P_cap)
        Qdis = m.ext[:variables][:Qdis] = @variable(m, 0 <= Qdis[t in CH] <= P_cap)
        SOC = m.ext[:variables][:SOC] = @variable(m, 0 <= SOC[t in CH] <= E_cap)
        SOC_init = m.ext[:parameters][:storage_initial_soc]
    end

    # OBJECTIVE: maximise welfare (value of demand minus generation cost)
    # sum_d,t P_dem(d) * Qd[d,t]  -  sum_g,t P_gen(g,t) * Qg[g,t]
    m.ext[:objective] = @objective(m, Max,
        (m.ext[:parameters][:storage_value] * SOC[CH[length(CH)]]) + # note this line add a valuation to the stored energy at the end of the window - just a preset parameter for now
        sum(Pr_dem[(String(d),t)] * Qd[d,t] for d in ID, t in CH) -
        sum(Pr_gen[(String(g),t)] * Qg[g,t] for g in IG, t in CH)
    )

    # energy balance: in each  time period, total generation equals total served demand
    #if storage, add storage charging/discharging
    if has_storage
        m.ext[:constraints][:energy_balance] = @constraint(
            m, [t in CH],
            sum(Qg[g,t] for g in IG) + Qdis[t] - Qch[t] - sum(Qd[d,t] for d in ID) == 0
        )
    else
        m.ext[:constraints][:energy_balance] = @constraint(
            m, [t in CH],
            sum(Qg[g,t] for g in IG) - sum(Qd[d,t] for d in ID) == 0
        )
    end

    # generator limits: generation cannot exceed available capacity Q_gen[g,t]
    m.ext[:constraints][:gen_limits] = @constraint(
        m, [g in IG, t in CH],
        Qg[g,t] <= Q_gen[(String(g),t)]
    )

    # using DG here so this only applies to the dispatchable gens

    m.ext[:constraints][:ramp_limits] = @constraint(
        m, [g in DG, t in range(CH[1],CH[1])], # for the first hour
        m.ext[:parameters][:previous_time_period_dispatch][g] - m.ext[:parameters][:ramp_rate][g] <= Qg[g,t] <= m.ext[:parameters][:previous_time_period_dispatch][g] + m.ext[:parameters][:ramp_rate][g]
    )

    m.ext[:constraints][:ramp_limits] = @constraint(
        m, [g in DG, t in CH[2:end] ], # start with the second hour
        Qg[g,t] <= Qg[g,t-1] + m.ext[:parameters][:ramp_rate][g]
    )

     m.ext[:constraints][:ramp_limits] = @constraint(
        m, [g in DG, t in CH[2:end] ], # start with the second hour
        Qg[g,t] >= Qg[g,t-1] - m.ext[:parameters][:ramp_rate][g]
    )

    # demand limits: served demand cannot exceed maximum quantity Q_dem[d,t]
    m.ext[:constraints][:dem_limits] = @constraint(
        m, [d in ID, t in CH],
        Qd[d,t] <= Q_dem[(String(d),t)]
    )

    # Storage constraints
    if has_storage
        η = m.ext[:parameters][:storage_efficiency]
        
        # State of charge dynamics: SOC[t] = SOC[t-1] + η*Qch[t] - Qdis[t]/η
        # For first hour t=start_at_period, use initial SOC
        #  feed forward the SOC result from the previous round
        @constraint(m, SOC[start_at_period] == SOC_init + η * Qch[start_at_period] - Qdis[start_at_period] / η)
        
        # interperiod constraints for hours 2+
        for t in range(start_at_period + 1,(start_at_period -1)+length(CH))
            @constraint(m, SOC[t] == SOC[t-1] + η * Qch[t] - Qdis[t] / η)
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

function build_for_time_period(data, time_period::Int, previous_time_period_data)

	# create the optimisation model with HiGHS as the solver

    m = Model(HiGHS.Optimizer)
    set_silent(m)
	# build the sets, time series and parameters based on the YAML data
	define_sets!(m, data, time_period)
	process_time_series_data!(m, data, time_period)
	process_parameters!(m, data, previous_time_period_data)

	# create variables, constraints and objective, then solve
	build_market_clearing!(m, time_period)

	return m
end

end;
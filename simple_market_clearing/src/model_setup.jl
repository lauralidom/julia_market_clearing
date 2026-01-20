
# MODEL SETUP AND FUNCTIONS

using JuMP
using YAML

# 0: Load Input Data from YAML
function load_input_data(path::String)
    # Read the YAML file into a nested Julia Dict/Array structure
    cfg = YAML.load_file(path)

    # Internal data dictionary to pass to the other functions
    data = Dict{Symbol,Any}()

    # generators: separate blocks for dispatchable and variable generators
    data[:dispatchableGenerators] = cfg["dispatchableGenerators"]
    data[:variableGenerators]     = get(cfg, "variableGenerators", Dict())

    # demand segments: Base and Flex demand, each with a bid and hourly quantities
    data[:demandSegments] = cfg["demand"]["segments"]

    # storage parameters
    data[:batteryStorage] = get(cfg, "batteryStorage", nothing)

    return data
end


# 1: Define Sets (indices for generators, demand, time periods)
# stored in m.ext[:sets] to be used by build_market_clearing!()
function define_sets!(m::Model, data::Dict{Symbol,Any})
    # Store all sets in a dedicated dictionary attached to the model
    m.ext[:sets] = Dict{Symbol,Any}()

    disp_gen = data[:dispatchableGenerators]
    var_gen  = data[:variableGenerators]
    dem      = data[:demandSegments]

    # Note: JH (time periods) is set dynamically in rolling horizon loop
    # Will be overwritten to 1:look_ahead during each iteration

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

# 2: Load and Expand Time Series (extend input data to full simulation horizon)
function load_and_expand_timeseries(cfg::Dict, total_hours::Int)    
    disp_gen = cfg["dispatchableGenerators"]
    var_gen = cfg["variableGenerators"]
    dem = cfg["demand"]["segments"]
    
    # Initialise dictionaries
    Pr_gen_full = Dict{Tuple{String,Int},Float64}()
    Q_gen_full = Dict{Tuple{String,Int},Float64}()
    Pr_dem_full = Dict{Tuple{String,Int},Float64}()
    Q_dem_full = Dict{Tuple{String,Int},Float64}()
    
    # Dispatchable generators: constant price and capacity across all hours
    for (gname, gdata_any) in disp_gen
        g = String(gname)
        P = float(gdata_any["bidPrice"])
        Q = float(gdata_any["capacity"])
        # Hour 0: prep hour
        Pr_gen_full[(g, 0)] = P
        Q_gen_full[(g, 0)] = Q
        # Hours 1 onwards
        for h in 1:total_hours-1
            Pr_gen_full[(g, h)] = P
            Q_gen_full[(g, h)] = Q
        end
    end
    
    # Variable generators: expand profile cyclically across all hours
    for (gname, gdata_any) in var_gen
        g = String(gname)
        P = float(gdata_any["bidPrice"])
        Q = float(gdata_any["capacity"])
        profile_any = gdata_any["profile"]
        profile = [float(x) for x in profile_any]
        daily_length = length(profile)
        
        # Hour 0: prep hour, use first hour of profile
        hour_in_day = 1
        af = profile[hour_in_day]
        Pr_gen_full[(g, 0)] = P
        Q_gen_full[(g, 0)] = Q * af
        
        # Hours 1 onwards
        for h in 1:total_hours-1
            hour_in_day = mod(h - 1, daily_length) + 1
            af = profile[hour_in_day]
            Pr_gen_full[(g, h)] = P
            Q_gen_full[(g, h)] = Q * af
        end
    end
    
    # Demand segments: expand quantities cyclically across all hours
    # Hour 0 is a prep hour with 0 demand
    for (dname, ddata_any) in dem
        d = String(dname)
        P = float(ddata_any["bidPrice"])
        q_any = ddata_any["quantity"]
        q_vec = [float(x) for x in q_any]
        daily_length = length(q_vec)
        
        # Hour 0: zero demand
        Pr_dem_full[(d, 0)] = P
        Q_dem_full[(d, 0)] = 0.0
        
        # Hours 1 onwards: cycle through demand profile
        for h in 1:total_hours-1
            hour_in_day = mod(h - 1, daily_length) + 1
            Pr_dem_full[(d, h)] = P
            Q_dem_full[(d, h)] = q_vec[hour_in_day]
        end
    end
    
    return Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full
end

# 3: Extract Rolling Window from Full Time Series
function get_window_timeseries(Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full, 
                                start_hour::Int, window_length::Int, 
                                IG::Vector, ID::Vector)
    Pr_gen_window = Dict{Tuple{String,Int},Float64}()
    Q_gen_window = Dict{Tuple{String,Int},Float64}()
    Pr_dem_window = Dict{Tuple{String,Int},Float64}()
    Q_dem_window = Dict{Tuple{String,Int},Float64}()
    
    for h_model in 1:window_length
        h_global = start_hour + h_model - 1
        
        for g in IG
            Pr_gen_window[(g, h_model)] = Pr_gen_full[(g, h_global)]
            Q_gen_window[(g, h_model)] = Q_gen_full[(g, h_global)]
        end
        
        for d in ID
            Pr_dem_window[(d, h_model)] = Pr_dem_full[(d, h_global)]
            Q_dem_window[(d, h_model)] = Q_dem_full[(d, h_global)]
        end
    end
    
    return Pr_gen_window, Q_gen_window, Pr_dem_window, Q_dem_window
end

# 4: Add wind forecast noise to simulate uncertainty
# Uses t-distribution (df=5) with square root decay for realistic forecast errors
# Hour 1: no noise (forecast = realized wind)
# Hour 24: maximum noise (std_dev = max_std)
# Noise decreases with concave curve (sqrt) as we get closer to real-time
function add_wind_forecast_noise!(Q_gen_window::Dict, cfg::Dict, max_noise_std::Float64, 
                                   IG::Vector, window_length::Int)
    if max_noise_std == 0.0
        return  # no noise
    end
    
    var_gen = cfg["variableGenerators"]
    t_dist = TDist(5)  # t-distribution with 5 degrees of freedom (fat tails)
    
    for (gname, gdata_any) in var_gen
        g = String(gname)
        if g in IG
            Q = float(gdata_any["capacity"])
            
            for h in 1:window_length
                # Hour 1: no noise (forecast equals realized wind)
                if h == 1
                    continue
                end
                
                # Calculate time-dependent std dev using square root decay
                # Hour 2 → small noise, Hour 24 → max noise
                time_factor = sqrt((h - 1) / (window_length - 1))
                std_dev = max_noise_std * time_factor
                
                # Current forecast (availability factor)
                current_af = Q_gen_window[(g, h)] / Q
                
                # Add t-distributed noise (fatter tails than Gaussian)
                noise = rand(t_dist) * std_dev
                new_af = clamp(current_af + noise, 0.0, 1.0)
                
                Q_gen_window[(g, h)] = Q * new_af
            end
        end
    end
end

# 5: Extract updated position (g_planned) as next financial position
function extract_window_commitments(g_planned_val, IG::Vector, window_length::Int)
    q_prev_next = Dict{Tuple{String,Int},Float64}()
    
    for g in IG
        for h in 1:window_length
            # Current updated position becomes next financial position
            q_prev_next[(g, h)] = g_planned_val[g, h]
        end
    end
    
    return q_prev_next
end

# 6: Prepare Financial Position for Next Window
function prepare_Q_prev_for_next_window(prev_q_financial::Dict, window_length::Int, IG::Vector, reclear_freq::Int)
    Q_prev = Dict{Tuple{String,Int},Float64}()
    
    for g in IG
        for h in 1:window_length
            if h <= window_length - reclear_freq
                # Hours 1 to (window_length - reclear_freq): shift forward from previous window
                # Previous hour (h + reclear_freq) becomes current hour h's financial baseline
                Q_prev[(g, h)] = prev_q_financial[(g, h + reclear_freq)]
            else
                # Last reclear_freq hours (new hours entering): no prior commitment
                Q_prev[(g, h)] = 0.0
            end
        end
    end
    
    return Q_prev
end

# 7: Process Parameters for storage
function process_parameters!(m::Model, data::Dict{Symbol,Any})
    m.ext[:parameters] = Dict{Symbol,Any}()

    # Store storage parameters
    if data[:batteryStorage] !== nothing
        storage = data[:batteryStorage]
        m.ext[:parameters][:storage_energy_capacity] = float(storage["energyCapacity"])
        m.ext[:parameters][:storage_power_capacity] = float(storage["powerCapacity"])
        m.ext[:parameters][:storage_efficiency] = float(storage["efficiency"])
        m.ext[:parameters][:storage_initial_soc] = float(storage["initialSOC"]) * float(storage["energyCapacity"])
    else
        error("Storage configuration required but not found in data")
    end
    
    return m
end

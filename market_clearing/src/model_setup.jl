
# MODEL SETUP AND FUNCTIONS

using JuMP
using YAML
using CSV
using DataFrames
using Dates
using Distributions

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

# 0.1: Derive simulation date range from a single month input in YAML.
# Updates rolling_horizon.simulation_days and all CSV-backed start/end dates.
function apply_simulation_month!(cfg::Dict)
    rh = get(cfg, "rolling_horizon", nothing)
    if rh === nothing
        return cfg
    end

    sim_month = Int(get(rh, "simulation_month", 1))
    if sim_month < 1 || sim_month > 12
        error("rolling_horizon.simulation_month must be between 1 and 12")
    end

    # Dataset is fixed to 2025, so only month is configurable.
    month_start = Date(2025, sim_month, 1)
    month_end = lastdayofmonth(month_start)
    start_dt = DateTime(month_start)
    end_dt = DateTime(month_end) + Hour(23)

    # Keep simulation_days consistent with selected month.
    rh["simulation_days"] = day(month_end)

    iso_fmt = dateformat"yyyy-mm-dd HH:MM:SS"
    euro_fmt = dateformat"dd/mm/yyyy HH:MM"
    start_iso = Dates.format(start_dt, iso_fmt)
    end_iso = Dates.format(end_dt, iso_fmt)
    start_euro = Dates.format(start_dt, euro_fmt)
    end_euro = Dates.format(end_dt, euro_fmt)

    # Variable generators (wind/solar): ISO datetime format.
    if haskey(cfg, "variableGenerators")
        for (_, gdata_any) in cfg["variableGenerators"]
            if haskey(gdata_any, "dataFile")
                gdata_any["startDate"] = start_iso
                gdata_any["endDate"] = end_iso
            end
        end
    end

    # Demand: European datetime format.
    if haskey(cfg, "demand") && haskey(cfg["demand"], "dataFile")
        cfg["demand"]["startDate"] = start_euro
        cfg["demand"]["endDate"] = end_euro
    end

    return cfg
end

# 0.5: Helper function to load CSV data with date filtering
function load_csv_timeseries(filepath::String, column::String, date_column::String, 
                              start_date::String, end_date::String, expected_hours::Int,
                              config_format::DateFormat, csv_format::DateFormat;
                              conversion_factor::Float64=1.0)
    # Read CSV file (has header row), silencing warnings about bad values at end of file
    df = CSV.read(filepath, DataFrame, 
                  stringtype=String,
                  silencewarnings=true,
                  types=Dict(Symbol(column) => Float64))
    
    # Check if columns exist
    if !hasproperty(df, Symbol(date_column))
        error("Date column $date_column not found in $filepath")
    end
    if !hasproperty(df, Symbol(column))
        error("Data column $column not found in $filepath")
    end
    
    # Remove rows with missing data values (from parsing errors like #DIV/0!)
    df = dropmissing(df, Symbol(column))
    
    # Parse date range for filtering
    start_dt = DateTime(start_date, config_format)
    end_dt = DateTime(end_date, config_format)

    # Parse CSV timestamps robustly across known dataset formats.
    parse_csv_datetime(date_str::String) = begin
        local dt
        try
            dt = DateTime(date_str, csv_format)
            return dt
        catch
        end
        try
            dt = DateTime(date_str, dateformat"yyyy-mm-dd HH:MM:SS")
            return dt
        catch
        end
        try
            dt = DateTime(date_str, dateformat"yyyy-mm-dd HH:MM")
            return dt
        catch
        end
        try
            dt = DateTime(date_str, dateformat"dd/mm/yyyy HH:MM")
            return dt
        catch
            return missing
        end
    end
    
    # Parse date column
    parsed_dates = Vector{Union{DateTime, Missing}}(undef, nrow(df))
    for i in 1:nrow(df)
        date_str = string(df[i, Symbol(date_column)])
        parsed_dates[i] = parse_csv_datetime(date_str)
    end
    df[!, :parsed_date] = parsed_dates
    
    # Remove rows with invalid dates
    df = dropmissing(df, :parsed_date)
    
    # Filter by date range
    filtered_df = filter(row -> row.parsed_date >= start_dt && row.parsed_date <= end_dt, df)
    
    # Extract values and apply conversion factor (e.g., kW to MW: divide by 1000)
    values = filtered_df[!, Symbol(column)] .* conversion_factor
    
    # Validate it's right amount
    if length(values) != expected_hours
        error("Filtered CSV has $(length(values)) rows for date range $start_date to $end_date, but $expected_hours hours are needed")
    end
    
    conversion_note = conversion_factor != 1.0 ? " (converted by factor $conversion_factor)" : ""
    println("  → Loaded $(length(values)) hourly values from $start_date to $end_date$conversion_note")
    
    return values
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
    dem_config = cfg["demand"]
    
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
    
    # Variable generators: either load from CSV or expand profile cyclically
    for (gname, gdata_any) in var_gen
        g = String(gname)
        P = float(gdata_any["bidPrice"])
        Q = float(gdata_any["capacity"])
        
        # Check if we should load from CSV file(s)
        if haskey(gdata_any, "dataFile") && haskey(gdata_any, "dataColumn")
            # Load data from CSV
            # Wind/Solar use ISO format: yyyy-mm-dd HH:MM:SS
            date_column = get(gdata_any, "dateColumn", "StartDateTime")
            start_date = get(gdata_any, "startDate", "2025-01-01 00:00:00")
            end_date_config = get(gdata_any, "endDate", "2025-12-31 23:00:00")
            conversion_factor = get(gdata_any, "conversionFactor", 1.0)
            
            # Calculate actual end date based on simulation length
            iso_format = dateformat"yyyy-mm-dd HH:MM:SS"
            start_dt = DateTime(start_date, iso_format)
            actual_end_dt = start_dt + Hour(total_hours - 2)
            end_date = Dates.format(actual_end_dt, iso_format)
            
            # Support multiple files (for combining wind sources)
            datafiles = gdata_any["dataFile"]
            if isa(datafiles, String)
                datafiles = [datafiles]  # Convert single file to array
            end
            
            column = gdata_any["dataColumn"]
            
            # Load and sum all files
            timeseries_values = zeros(Float64, total_hours - 1)
            for filepath in datafiles
                println("Loading $g data from CSV: $filepath (column: $column)")
                println("  Date range: $start_date to $end_date ($(total_hours - 1) hours)")
                file_values = load_csv_timeseries(filepath, column, date_column, start_date, end_date, total_hours - 1,
                                                   iso_format, iso_format, conversion_factor=conversion_factor)
                timeseries_values .+= file_values
            end
            
            if length(datafiles) > 1
                println("  ✓ Combined $(length(datafiles)) files for $g")
            end
            
            # Hour 0: prep hour, use first value
            Pr_gen_full[(g, 0)] = P
            Q_gen_full[(g, 0)] = timeseries_values[1]
            
            # Hours 1 onwards: use CSV data directly (already in MW)
            for h in 1:total_hours-1
                Pr_gen_full[(g, h)] = P
                Q_gen_full[(g, h)] = timeseries_values[h]
            end
        else
            # Use profile (original behavior)
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
    end
    
    # Demand segments: load from CSV or expand quantities cyclically
    # Check if demand has CSV file
    if haskey(dem_config, "dataFile") && haskey(dem_config, "dataColumn")
        # Load total demand from CSV
        # Demand uses European format: dd/mm/yyyy HH:MM
        filepath = dem_config["dataFile"]
        column = dem_config["dataColumn"]
        date_column = get(dem_config, "dateColumn", "StartDateTime")
        start_date = get(dem_config, "startDate", "01/01/2025 00:00")
        end_date_config = get(dem_config, "endDate", "31/12/2025 23:00")
        conversion_factor = get(dem_config, "conversionFactor", 1.0)
        
        # Calculate actual end date based on simulation length
        euro_format = dateformat"dd/mm/yyyy HH:MM"
        start_dt = DateTime(start_date, euro_format)
        actual_end_dt = start_dt + Hour(total_hours - 2)
        end_date = Dates.format(actual_end_dt, euro_format)
        
        println("Loading demand data from CSV: $filepath (column: $column)")
        println("  Date range: $start_date to $end_date ($(total_hours - 1) hours)")
        total_demand = load_csv_timeseries(filepath, column, date_column, start_date, end_date, total_hours - 1,
                                            euro_format, euro_format, conversion_factor=conversion_factor)
        
        # Split demand into segments based on fractions
        for (dname, ddata_any) in dem
            d = String(dname)
            P = float(ddata_any["bidPrice"])
            fraction = float(get(ddata_any, "fraction", 1.0))
            
            # Hour 0: zero demand
            Pr_dem_full[(d, 0)] = P
            Q_dem_full[(d, 0)] = 0.0
            
            # Hours 1 onwards: apply fraction to total demand
            for h in 1:total_hours-1
                Pr_dem_full[(d, h)] = P
                Q_dem_full[(d, h)] = total_demand[h] * fraction
            end
        end
    else
        # Use quantity profiles (original behavior)
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
    t_dist = TDist(10)  # t-distribution with 10 degrees of freedom (fat tails)
    
    for (gname, gdata_any) in var_gen
        g = String(gname)
        # Only apply noise to Wind - other generators like Solar have deterministic profiles
        if g in IG && g == "Wind"
            Q = float(gdata_any["capacity"])
            
            # Apply noise to all hours with time-dependent decay
            for h in 1:window_length
                # Calculate time-dependent std dev using square root decay
                # h=1 → zero noise (real wind), h=window_length → max noise
                if h == 1
                    continue  # No noise at h=1, forecast = reality
                end
                
                time_factor = sqrt((h - 1) / (window_length - 1))
                std_dev = max_noise_std * time_factor
                
                # Current forecast (already in MW, but we work with availability factor for noise)
                current_value = Q_gen_window[(g, h)]
                current_af = current_value / Q
                
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
            # Check if we can access the shifted position from previous window
            prev_hour = h + reclear_freq
            if haskey(prev_q_financial, (g, prev_hour))
                # This hour was seen in previous clearing - shift forward
                # Previous hour (h + reclear_freq) becomes current hour h's financial baseline
                Q_prev[(g, h)] = prev_q_financial[(g, prev_hour)]
            else
                # This is a new hour entering the horizon (only in rolling mode)
                # In rolling_fixed, all hours should have previous commitments
                Q_prev[(g, h)] = 0.0
            end
        end
    end
    
    return Q_prev
end

# 7: Process Parameters for storage and ramping
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
    
    # Store ramping rate parameters for dispatchable generators
    # Ramp rates are specified as fraction of capacity per hour
    disp_gen = data[:dispatchableGenerators]
    ramp_rate = Dict{String, Float64}()
    
    for (gname, gdata) in disp_gen
        g = String(gname)
        capacity = float(gdata["capacity"])
        # If ramping rate is not specified, set to a very large value (no constraint)
        if haskey(gdata, "rampRate")
            ramp_fraction = float(gdata["rampRate"])
            ramp_rate[g] = ramp_fraction * capacity  # Convert to absolute MW/h
        else
            ramp_rate[g] = 1e6
        end
    end
    
    m.ext[:parameters][:ramp_rate] = ramp_rate
    
    return m
end

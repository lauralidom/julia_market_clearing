# COST AND REVENUE CALCULATIONS
using XLSX
using Dates
using DataFrames
using Printf
using Statistics
using Distributions
using CSV

function executed_days(all_results::Dict)
    clearing_details = get(all_results, :clearing_details, Dict())
    total_executed_hours = sum(details[:executed_hours] for details in values(clearing_details))
    return total_executed_hours / 24
end

function normalization_days(all_results::Dict, cfg::Dict)
    sim_days = Int(cfg["rolling_horizon"]["simulation_days"])
    actual_days = executed_days(all_results)
    return haskey(cfg["rolling_horizon"], "comparable_delivery_hours_override") ? actual_days : sim_days
end


function calculate_system_costs(all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    
    # Get generator bid prices
    disp_gen = cfg["dispatchableGenerators"]
    var_gen = cfg["variableGenerators"]
    
    gen_prices = Dict{String, Float64}()
    for (gname, gdata) in disp_gen
        gen_prices[String(gname)] = float(gdata["bidPrice"])
    end
    for (gname, gdata) in var_gen
        gen_prices[String(gname)] = float(gdata["bidPrice"])
    end
    
    # Track costs by generator across ALL delivered hours
    gen_costs = Dict{String, Float64}()
    for g in keys(gen_prices)
        gen_costs[g] = 0.0
    end
    
    # Sum costs across all DELIVERED hours
    # Each clearing may execute a different number of hours (stored in :executed_hours)
    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        g_planned = details[:g_planned]  # Final committed position for each hour
        executed_hours = details[:executed_hours]
        
        # Sum cost for all executed hours in this clearing
        for h in 1:executed_hours
            for (gen, bid_price) in gen_prices
                delivered_dispatch = g_planned[gen, h]  # MWh
                cost = delivered_dispatch * bid_price    # EUR
                gen_costs[gen] += cost
            end
        end
    end
    
    total_cost = sum(values(gen_costs))
    total_hours_delivered = sum(clearing_details[c][:executed_hours] for c in keys(clearing_details))
    
    return Dict(
        :generator_costs => gen_costs,
        :total_cost => total_cost,
        :total_clearings => length(clearing_details),
        :total_hours_delivered => total_hours_delivered
    )
end


function calculate_demand_value(all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    
    # Get demand segment bid prices
    demand_segments = cfg["demand"]["segments"]
    
    dem_prices = Dict{String, Float64}()
    for (dname, ddata) in demand_segments
        dem_prices[String(dname)] = float(ddata["bidPrice"])
    end
    
    # Track value by demand segment across ALL delivered hours
    dem_values = Dict{String, Float64}()
    dem_served = Dict{String, Float64}()
    for d in keys(dem_prices)
        dem_values[d] = 0.0
        dem_served[d] = 0.0
    end
    
    # Map demand segment names to their storage keys in clearing_details
    dem_keys = Dict("Base" => :demand_base, "Flex" => :demand_flex)
    
    # Sum demand value across all DELIVERED hours
    # Each clearing may execute a different number of hours (stored in :executed_hours)
    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        
        # Sum value for all executed hours in this clearing
        for h in 1:executed_hours
            for (dem, bid_price) in dem_prices
                # Get the served demand from the stored array
                demand_key = dem_keys[dem]
                served_demand = details[demand_key][h]  # MWh
                value = served_demand * bid_price  # EUR
                dem_values[dem] += value
                dem_served[dem] += served_demand
            end
        end
    end
    
    total_demand_value = sum(values(dem_values))
    total_demand_served = sum(values(dem_served))
    total_hours_delivered = sum(clearing_details[c][:executed_hours] for c in keys(clearing_details))
    
    return Dict(
        :demand_segment_values => dem_values,
        :demand_segment_served => dem_served,
        :total_demand_value => total_demand_value,
        :total_demand_served => total_demand_served,
        :total_clearings => length(clearing_details),
        :total_hours_delivered => total_hours_delivered
    )
end


function calculate_social_welfare(all_results::Dict, cfg::Dict)
    # Social welfare = total demand value - total generation costs
    demand_results = calculate_demand_value(all_results, cfg)
    cost_results = calculate_system_costs(all_results, cfg)
    
    total_welfare = demand_results[:total_demand_value] - cost_results[:total_cost]
    
    return Dict(
        :total_demand_value => demand_results[:total_demand_value],
        :total_generation_cost => cost_results[:total_cost],
        :social_welfare => total_welfare,
        :demand_details => demand_results,
        :cost_details => cost_results
    )
end


function calculate_adequacy_metrics(all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]

    peak_bid = haskey(cfg, "dispatchableGenerators") &&
               haskey(cfg["dispatchableGenerators"], "Peak") ?
               float(cfg["dispatchableGenerators"]["Peak"]["bidPrice"]) : 150.0

    total_executed_hours = 0
    scarcity_hours = 0
    price_sum = 0.0
    scarcity_price_sum = 0.0
    max_price = -Inf

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        prices = details[:prices]
        executed_hours = details[:executed_hours]

        for h in 1:executed_hours
            p = prices[h]
            total_executed_hours += 1
            price_sum += p
            max_price = max(max_price, p)

            if p > peak_bid
                scarcity_hours += 1
                scarcity_price_sum += p
            end
        end
    end

    scarcity_share = total_executed_hours > 0 ? scarcity_hours / total_executed_hours : 0.0
    avg_exec_price = total_executed_hours > 0 ? price_sum / total_executed_hours : 0.0
    avg_scarcity_price = scarcity_hours > 0 ? scarcity_price_sum / scarcity_hours : 0.0

    return Dict(
        :peak_bid => peak_bid,
        :total_executed_hours => total_executed_hours,
        :scarcity_hours => scarcity_hours,
        :scarcity_share => scarcity_share,
        :avg_executed_price => avg_exec_price,
        :avg_scarcity_price => avg_scarcity_price,
        :max_executed_price => isfinite(max_price) ? max_price : 0.0
    )
end


function calculate_generator_revenues_executed(all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    prices_dict = all_results[:prices]
    dispatch_dict = all_results[:dispatch]
    
    # Track revenue by generator for executed hours only
    gen_revenues = Dict{String, Float64}()
    gen_energy = Dict{String, Float64}()
    
    # Sum revenues across all executed hours
    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        g_planned = details[:g_planned]
        prices = prices_dict[clearing_num]
        executed_hours = details[:executed_hours]
        
        # Get generators from dispatch_dict (regular Dict, easier to iterate)
        gens = collect(keys(dispatch_dict[clearing_num]))
        
        for gen in gens
            if !haskey(gen_revenues, gen)
                gen_revenues[gen] = 0.0
                gen_energy[gen] = 0.0
            end
            
            # Sum over executed hours
            for h in 1:executed_hours
                executed_dispatch = g_planned[gen, h]  # MWh
                price = prices[h]  # EUR/MWh
                revenue = executed_dispatch * price  # EUR
                
                gen_revenues[gen] += revenue
                gen_energy[gen] += executed_dispatch
            end
        end
    end
    
    total_revenue = sum(values(gen_revenues))
    
    return Dict(
        :generator_revenues => gen_revenues,
        :generator_energy => gen_energy,
        :total_revenue => total_revenue,
        :total_clearings => length(clearing_details)
    )
end


function calculate_generator_revenues_full(all_results::Dict)
    dispatch_dict = all_results[:dispatch]
    prices_dict = all_results[:prices]
    clearing_details = all_results[:clearing_details]

    gen_revenues = Dict{String, Float64}()   # sum of all q*price cashflows
    traded_net = Dict{String, Float64}()     # net traded position across all clearings (sum q)
    traded_gross = Dict{String, Float64}()   # gross turnover sum(|q|)
    sold_qty = Dict{String, Float64}()       # total sold quantity (q > 0)
    sold_cash = Dict{String, Float64}()      # total sold cashflow (q > 0)
    buyback_qty = Dict{String, Float64}()    # total bought-back quantity (-q where q < 0)
    buyback_cash = Dict{String, Float64}()   # total buy-back spend (-q*price where q < 0)

    for clearing_num in sort(collect(keys(dispatch_dict)))
        prices = prices_dict[clearing_num]
        details = clearing_details[clearing_num]
        q_val = details[:q]

        # Generators present in this clearing
        gens = collect(keys(dispatch_dict[clearing_num]))

        H = length(prices)
        for gen in gens
            fin_rev = 0.0
            net_trade = 0.0
            gross_trade = 0.0
            
            for h in 1:H
                Δq = q_val[gen, h]
                fin_rev += Δq * prices[h]
                net_trade += Δq
                gross_trade += abs(Δq)
            end

            if !haskey(gen_revenues, gen)
                gen_revenues[gen] = 0.0
                traded_net[gen] = 0.0
                traded_gross[gen] = 0.0
                sold_qty[gen] = 0.0
                sold_cash[gen] = 0.0
                buyback_qty[gen] = 0.0
                buyback_cash[gen] = 0.0
            end

            gen_revenues[gen] += fin_rev
            traded_net[gen] += net_trade
            traded_gross[gen] += gross_trade

            for h in 1:H
                Δq = q_val[gen, h]
                p = prices[h]
                if Δq > 0
                    sold_qty[gen] += Δq
                    sold_cash[gen] += Δq * p
                elseif Δq < 0
                    buy_qty = -Δq
                    buyback_qty[gen] += buy_qty
                    buyback_cash[gen] += buy_qty * p
                end
            end
        end
    end

    total_revenue = sum(values(gen_revenues))

    avg_sell_price = Dict{String, Float64}()
    avg_buyback_price = Dict{String, Float64}()
    for gen in keys(gen_revenues)
        avg_sell_price[gen] = sold_qty[gen] > 0 ? sold_cash[gen] / sold_qty[gen] : 0.0
        avg_buyback_price[gen] = buyback_qty[gen] > 0 ? buyback_cash[gen] / buyback_qty[gen] : 0.0
    end

    return Dict(
        :generator_revenues => gen_revenues,
        :traded_net => traded_net,
        :traded_gross => traded_gross,
        :sold_qty => sold_qty,
        :buyback_qty => buyback_qty,
        :avg_sell_price => avg_sell_price,
        :avg_buyback_price => avg_buyback_price,
        :total_revenue => total_revenue,
        :total_clearings => length(dispatch_dict)
    )
end


function calculate_storage_revenue(all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    prices_dict = all_results[:prices]
    
    # Track revenue components
    # Note: Battery efficiency is already accounted for in the main model
    total_discharge_revenue = 0.0
    total_charging_cost = 0.0
    total_discharge_energy = 0.0
    total_charging_energy = 0.0
    
    # For each clearing, use the stored executed hours
    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        prices = prices_dict[clearing_num]
        executed_hours = details[:executed_hours]
        
        # Sum over all executed hours
        for h in 1:executed_hours
            discharge_mw = details[:discharging][h]
            charge_mw = details[:charging][h]
            price = prices[h]  # EUR/MWh
            
            # Revenue from discharging
            discharge_revenue = discharge_mw * price
            
            # Cost of charging (need to buy power at market price)
            charging_cost = charge_mw * price
            
            total_discharge_revenue += discharge_revenue
            total_charging_cost += charging_cost
            total_discharge_energy += discharge_mw
            total_charging_energy += charge_mw
        end
    end
    
    net_revenue = total_discharge_revenue - total_charging_cost
    
    return Dict(
        :discharge_revenue => total_discharge_revenue,
        :charging_cost => total_charging_cost,
        :net_revenue => net_revenue,
        :total_discharge_energy => total_discharge_energy,
        :total_charging_energy => total_charging_energy,
        :total_clearings => length(clearing_details),
        :avg_discharge_price => total_discharge_energy > 0 ? total_discharge_revenue / total_discharge_energy : 0.0,
        :avg_charging_price => total_charging_energy > 0 ? total_charging_cost / total_charging_energy : 0.0
    )
end


function compute_delivery_hour_ledger(all_results::Dict, cfg::Dict)
    clearing_times = all_results[:clearing_times]
    prices_dict = all_results[:prices]
    details_dict = all_results[:clearing_details]
    dispatch_dict = all_results[:dispatch]

    ledger = Dict{Tuple{String,Int}, Dict{Symbol,Float64}}()
    executed = Dict{Tuple{String,Int}, Float64}()
    exec_price = Dict{Int, Float64}()

    for c_num in sort(collect(keys(details_dict)))
        start = clearing_times[c_num]
        prices = prices_dict[c_num]
        q_val = details_dict[c_num][:q]
        Hlen = length(prices)
        gens = collect(keys(dispatch_dict[c_num]))

        # Aggregate trades for all delivery hours visible in this clearing
        for gen in gens
            for h in 1:Hlen
                globalH = start + (h - 1)
                Δq = q_val[gen, h]
                cash = Δq * prices[h]
                key = (gen, globalH)
                if !haskey(ledger, key)
                    ledger[key] = Dict(:net_qty => 0.0, :gross_qty => 0.0, :cashflow => 0.0)
                end
                L = ledger[key]
                L[:net_qty] += Δq
                L[:gross_qty] += abs(Δq)
                L[:cashflow] += cash
            end
        end

        # No need to add initial positions separately
        # All positions are now captured through q trades across clearings

        # Capture executed position and delivery price for ALL executed hours
        g_planned = details_dict[c_num][:g_planned]
        executed_hours = details_dict[c_num][:executed_hours]
        for h in 1:executed_hours
            globalH = start + (h - 1)
            exec_price[globalH] = prices[h]
            for gen in gens
                executed[(gen, globalH)] = g_planned[gen, h]
            end
        end
    end

    return ledger, executed, exec_price
end


function print_delivery_hour_audit(all_results::Dict, cfg::Dict)
    ledger, executed, _ = compute_delivery_hour_ledger(all_results, cfg)

    # Determine executed hours set
    executed_hours = unique(h for (_, h) in keys(executed))

    # Aggregate by generator
    gens = unique(first(k) for k in keys(executed))
    println()
    println("DELIVERY-HOUR AUDIT (sum of trades vs executed)")
    println("-"^80)
    @printf "%-20s %16s %16s %16s\n" "Generator" "Σ net trades" "Σ executed" "Max |Δ| per hour"
    for gen in sort(collect(gens))
        sum_net = 0.0
        sum_exec = 0.0
        max_gap = 0.0
        for H in sort(collect(executed_hours))
            key = (gen, H)
            netH = haskey(ledger, key) ? ledger[key][:net_qty] : 0.0
            execH = haskey(executed, key) ? executed[key] : 0.0
            sum_net += netH
            sum_exec += execH
            max_gap = max(max_gap, abs(netH - execH))
        end
        @printf "%-20s %16.2f %16.2f %16.4f\n" gen sum_net sum_exec max_gap
    end
    println("-"^80)
end




function calculate_average_daily_metrics(all_results::Dict, cfg::Dict)
    sim_days = Int(cfg["rolling_horizon"]["simulation_days"])
    norm_days = normalization_days(all_results, cfg)
    
    costs = calculate_system_costs(all_results, cfg)
    revenues_exec = calculate_generator_revenues_executed(all_results, cfg)
    revenues_full = calculate_generator_revenues_full(all_results)
    storage = calculate_storage_revenue(all_results, cfg)
    welfare = calculate_social_welfare(all_results, cfg)
    
    # Normalize generator costs to daily average
    daily_gen_costs = Dict{String, Float64}()
    for (gen, cost) in costs[:generator_costs]
        daily_gen_costs[gen] = cost / norm_days
    end
    
    # Normalize generator revenues (executed)
    daily_gen_revenues_exec = Dict{String, Float64}()
    daily_gen_energy_exec = Dict{String, Float64}()
    for (gen, revenue) in revenues_exec[:generator_revenues]
        daily_gen_revenues_exec[gen] = revenue / norm_days
        daily_gen_energy_exec[gen] = revenues_exec[:generator_energy][gen] / norm_days
    end
    
    # Normalize generator revenues (full financial)
    daily_gen_revenues_full = Dict{String, Float64}()
    daily_traded_net = Dict{String, Float64}()
    daily_traded_gross = Dict{String, Float64}()
    for (gen, revenue) in revenues_full[:generator_revenues]
        daily_gen_revenues_full[gen] = revenue / norm_days
        daily_traded_net[gen] = revenues_full[:traded_net][gen] / norm_days
        daily_traded_gross[gen] = revenues_full[:traded_gross][gen] / norm_days
    end
    
    # Normalize storage metrics
    daily_storage = Dict(
        :discharge_revenue => storage[:discharge_revenue] / norm_days,
        :charging_cost => storage[:charging_cost] / norm_days,
        :net_revenue => storage[:net_revenue] / norm_days,
        :discharge_energy => storage[:total_discharge_energy] / norm_days,
        :charging_energy => storage[:total_charging_energy] / norm_days,
        :avg_discharge_price => storage[:avg_discharge_price],  # Price averages don't change
        :avg_charging_price => storage[:avg_charging_price]      # Price averages don't change
    )
    
    # Normalize welfare metrics
    daily_welfare = Dict(
        :social_welfare => welfare[:social_welfare] / norm_days,
        :demand_value => welfare[:total_demand_value] / norm_days,
        :generation_cost => welfare[:total_generation_cost] / norm_days
    )
    
    return Dict(
        :sim_days => sim_days,
        :normalization_days => norm_days,
        :daily_total_cost => costs[:total_cost] / norm_days,
        :daily_gen_costs => daily_gen_costs,
        :daily_gen_revenues_exec => daily_gen_revenues_exec,
        :daily_gen_energy_exec => daily_gen_energy_exec,
        :daily_total_revenue_exec => revenues_exec[:total_revenue] / norm_days,
        :daily_gen_revenues_full => daily_gen_revenues_full,
        :daily_traded_net => daily_traded_net,
        :daily_traded_gross => daily_traded_gross,
        :daily_total_revenue_full => revenues_full[:total_revenue] / norm_days,
        :daily_storage => daily_storage,
        :daily_welfare => daily_welfare
    )
end

function simulation_start_datetime(cfg::Dict)
    rh = cfg["rolling_horizon"]
    sim_month = Int(get(rh, "simulation_month", 1))
    sim_start_hour = Int(get(rh, "simulation_start_hour", 0))
    return DateTime(2025, sim_month, 1, sim_start_hour)
end

function generator_bid_prices(cfg::Dict)
    prices = Dict{String, Float64}()

    for (gname, gdata) in cfg["dispatchableGenerators"]
        prices[String(gname)] = float(gdata["bidPrice"])
    end
    for (gname, gdata) in cfg["variableGenerators"]
        prices[String(gname)] = float(gdata["bidPrice"])
    end

    return prices
end

function demand_bid_prices(cfg::Dict)
    prices = Dict{String, Float64}()
    for (dname, ddata) in cfg["demand"]["segments"]
        prices[String(dname)] = float(ddata["bidPrice"])
    end
    return prices
end

const WIND_FORECAST_ERROR_CACHE = Dict{String, Union{Nothing, Dict{Tuple{Int, Int}, Float64}}}()

function load_wind_forecast_error_lookup(cfg::Dict)
    rh = get(cfg, "rolling_horizon", Dict())
    scenario_path = get(rh, "wind_noise_scenario_path", nothing)
    scenario_path === nothing && return nothing

    path = String(scenario_path)
    if haskey(WIND_FORECAST_ERROR_CACHE, path)
        return WIND_FORECAST_ERROR_CACHE[path]
    end

    if !isfile(path)
        WIND_FORECAST_ERROR_CACHE[path] = nothing
        return nothing
    end

    df = CSV.read(path, DataFrame)
    required_cols = [:window_start_hour, :abs_hour, :forecast_error]
    if !all(col -> hasproperty(df, col), required_cols)
        WIND_FORECAST_ERROR_CACHE[path] = nothing
        return nothing
    end

    lookup = Dict{Tuple{Int, Int}, Float64}()
    for row in eachrow(df)
        lookup[(Int(row.window_start_hour), Int(row.abs_hour))] = Float64(row.forecast_error)
    end

    WIND_FORECAST_ERROR_CACHE[path] = lookup
    return lookup
end

function collect_daily_case_metrics(all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    isempty(clearing_details) && return DataFrame()

    sim_start_dt = simulation_start_datetime(cfg)
    gen_prices = generator_bid_prices(cfg)
    demand_prices = demand_bid_prices(cfg)
    forecast_lookup = load_wind_forecast_error_lookup(cfg)
    day_map = Dict{Date, Dict{Symbol, Any}}()

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        current_hour = Int(details[:current_hour])
        executed_hours = Int(details[:executed_hours])
        look_ahead = Int(get(details, :look_ahead, length(details[:prices])))
        prices = details[:prices]
        soc_path = get(details, :storage_soc_path, Float64[])

        if forecast_lookup !== nothing && look_ahead > 1
            tail_start = max(2, look_ahead - 5)
            for lead_time in 2:look_ahead
                abs_hour = current_hour + lead_time - 1
                if !haskey(forecast_lookup, (current_hour, abs_hour))
                    continue
                end
                err = abs(forecast_lookup[(current_hour, abs_hour)])
                executed_hour_dt = sim_start_dt + Hour(current_hour - 1)
                calendar_day = Date(executed_hour_dt)
                if !haskey(day_map, calendar_day)
                    day_map[calendar_day] = Dict{Symbol, Any}(
                        :calendar_day => calendar_day,
                        :executed_hours => 0,
                        :demand_value_eur => 0.0,
                        :generation_cost_eur => 0.0,
                        :wind_curtailment_mwh => 0.0,
                        :imbalance_mwh => 0.0,
                        :storage_charge_mwh => 0.0,
                        :storage_discharge_mwh => 0.0,
                        :charging_cost_eur => 0.0,
                        :discharge_revenue_eur => 0.0,
                        :total_demand_mwh => 0.0,
                        :flex_demand_mwh => 0.0,
                        :wind_mwh => 0.0,
                        :solar_mwh => 0.0,
                        :renewables_mwh => 0.0,
                        :mid_dispatch_mwh => 0.0,
                        :peak_dispatch_mwh => 0.0,
                        :mid_peak_dispatch_mwh => 0.0,
                        :thermal_dispatch_mwh => 0.0,
                        :net_storage_discharge_mwh => 0.0,
                        :gross_residual_load_proxy_mwh => 0.0,
                        :net_residual_load_proxy_mwh => 0.0,
                        :price_values => Float64[],
                        :visible_abs_forecast_error_sum => 0.0,
                        :visible_abs_forecast_error_count => 0,
                        :tail_abs_forecast_error_sum => 0.0,
                        :tail_abs_forecast_error_count => 0,
                        :last_global_hour => typemin(Int),
                        :end_soc_mwh => 0.0,
                    )
                end
                day = day_map[calendar_day]
                day[:visible_abs_forecast_error_sum] += err
                day[:visible_abs_forecast_error_count] += 1
                if lead_time >= tail_start
                    day[:tail_abs_forecast_error_sum] += err
                    day[:tail_abs_forecast_error_count] += 1
                end
            end
        end

        for h in 1:executed_hours
            global_hour = current_hour + h - 1
            hour_dt = sim_start_dt + Hour(global_hour - 1)
            calendar_day = Date(hour_dt)

            if !haskey(day_map, calendar_day)
                day_map[calendar_day] = Dict{Symbol, Any}(
                    :calendar_day => calendar_day,
                    :executed_hours => 0,
                    :demand_value_eur => 0.0,
                    :generation_cost_eur => 0.0,
                    :wind_curtailment_mwh => 0.0,
                    :imbalance_mwh => 0.0,
                    :storage_charge_mwh => 0.0,
                    :storage_discharge_mwh => 0.0,
                    :charging_cost_eur => 0.0,
                    :discharge_revenue_eur => 0.0,
                    :total_demand_mwh => 0.0,
                    :flex_demand_mwh => 0.0,
                    :wind_mwh => 0.0,
                    :solar_mwh => 0.0,
                    :renewables_mwh => 0.0,
                    :mid_dispatch_mwh => 0.0,
                    :peak_dispatch_mwh => 0.0,
                    :mid_peak_dispatch_mwh => 0.0,
                    :thermal_dispatch_mwh => 0.0,
                    :net_storage_discharge_mwh => 0.0,
                    :gross_residual_load_proxy_mwh => 0.0,
                    :net_residual_load_proxy_mwh => 0.0,
                    :price_values => Float64[],
                    :visible_abs_forecast_error_sum => 0.0,
                    :visible_abs_forecast_error_count => 0,
                    :tail_abs_forecast_error_sum => 0.0,
                    :tail_abs_forecast_error_count => 0,
                    :last_global_hour => typemin(Int),
                    :end_soc_mwh => 0.0,
                )
            end

            day = day_map[calendar_day]
            price = float(prices[h])
            charge = float(details[:charging][h])
            discharge = float(details[:discharging][h])
            demand_base = float(details[:demand_base][h])
            demand_flex = float(details[:demand_flex][h])
            wind = float(details[:g_planned]["Wind", h])
            solar = float(details[:g_planned]["Solar", h])
            base_dispatch = float(details[:g_planned]["Base", h])
            mid_dispatch = float(details[:g_planned]["Mid", h])
            peak_dispatch = float(details[:g_planned]["Peak", h])
            total_demand = demand_base + demand_flex

            generation_cost = 0.0
            for (gen, bid_price) in gen_prices
                generation_cost += float(details[:g_planned][gen, h]) * bid_price
            end

            demand_value =
                demand_base * get(demand_prices, "Base", 0.0) +
                demand_flex * get(demand_prices, "Flex", 0.0)

            day[:executed_hours] += 1
            day[:demand_value_eur] += demand_value
            day[:generation_cost_eur] += generation_cost
            day[:storage_charge_mwh] += charge
            day[:storage_discharge_mwh] += discharge
            day[:charging_cost_eur] += charge * price
            day[:discharge_revenue_eur] += discharge * price
            day[:total_demand_mwh] += total_demand
            day[:flex_demand_mwh] += demand_flex
            day[:wind_mwh] += wind
            day[:solar_mwh] += solar
            day[:renewables_mwh] += wind + solar
            day[:mid_dispatch_mwh] += mid_dispatch
            day[:peak_dispatch_mwh] += peak_dispatch
            day[:mid_peak_dispatch_mwh] += mid_dispatch + peak_dispatch
            day[:thermal_dispatch_mwh] += base_dispatch + mid_dispatch + peak_dispatch
            day[:net_storage_discharge_mwh] += discharge - charge
            day[:gross_residual_load_proxy_mwh] += total_demand - wind - solar
            day[:net_residual_load_proxy_mwh] += total_demand + charge - discharge - wind - solar
            push!(day[:price_values], price)

            # Curtailment is stored in executed-hour form only for h=1 in current runs.
            if h == 1
                day[:wind_curtailment_mwh] += float(get(details, :wind_curtailment_h1, 0.0))
                day[:imbalance_mwh] += float(get(details, :imbalance_h1, 0.0))
            end

            if global_hour >= day[:last_global_hour]
                day[:last_global_hour] = global_hour
                if h <= length(soc_path)
                    day[:end_soc_mwh] = float(soc_path[h])
                else
                    day[:end_soc_mwh] = float(get(details, :storage_soc_end_executed, 0.0))
                end
            end
        end
    end

    rows = NamedTuple[]
    sorted_days = sort(collect(keys(day_map)))
    first_day = first(sorted_days)

    for calendar_day in sorted_days
        day = day_map[calendar_day]
        charge = day[:storage_charge_mwh]
        discharge = day[:storage_discharge_mwh]
        price_values = day[:price_values]
        avg_visible_abs_forecast_error =
            day[:visible_abs_forecast_error_count] > 0 ?
            day[:visible_abs_forecast_error_sum] / day[:visible_abs_forecast_error_count] :
            missing
        avg_tail_abs_forecast_error =
            day[:tail_abs_forecast_error_count] > 0 ?
            day[:tail_abs_forecast_error_sum] / day[:tail_abs_forecast_error_count] :
            missing
        push!(rows, (
            simulation_day = Int(Dates.value(calendar_day - first_day)) + 1,
            calendar_day = calendar_day,
            executed_hours = Int(day[:executed_hours]),
            is_complete_day = Int(day[:executed_hours]) == 24,
            social_welfare_eur = day[:demand_value_eur] - day[:generation_cost_eur],
            generation_cost_eur = day[:generation_cost_eur],
            demand_value_eur = day[:demand_value_eur],
            wind_curtailment_mwh = day[:wind_curtailment_mwh],
            imbalance_mwh = day[:imbalance_mwh],
            storage_throughput_mwh = charge + discharge,
            storage_charge_mwh = charge,
            storage_discharge_mwh = discharge,
            avg_charging_price_eur_per_mwh = charge > 0 ? day[:charging_cost_eur] / charge : 0.0,
            avg_discharging_price_eur_per_mwh = discharge > 0 ? day[:discharge_revenue_eur] / discharge : 0.0,
            storage_revenue_eur = day[:discharge_revenue_eur] - day[:charging_cost_eur],
            end_soc_mwh = day[:end_soc_mwh],
            avg_price_eur_per_mwh = isempty(price_values) ? 0.0 : mean(price_values),
            price_std_eur_per_mwh = length(price_values) >= 2 ? std(price_values) : 0.0,
            price_range_eur_per_mwh = isempty(price_values) ? 0.0 : maximum(price_values) - minimum(price_values),
            max_price_eur_per_mwh = isempty(price_values) ? 0.0 : maximum(price_values),
            total_demand_mwh = day[:total_demand_mwh],
            flex_demand_mwh = day[:flex_demand_mwh],
            wind_mwh = day[:wind_mwh],
            solar_mwh = day[:solar_mwh],
            renewables_mwh = day[:renewables_mwh],
            mid_dispatch_mwh = day[:mid_dispatch_mwh],
            peak_dispatch_mwh = day[:peak_dispatch_mwh],
            mid_peak_dispatch_mwh = day[:mid_peak_dispatch_mwh],
            thermal_dispatch_mwh = day[:thermal_dispatch_mwh],
            net_storage_discharge_mwh = day[:net_storage_discharge_mwh],
            gross_residual_load_proxy_mwh = day[:gross_residual_load_proxy_mwh],
            net_residual_load_proxy_mwh = day[:net_residual_load_proxy_mwh],
            renewable_share_of_demand = day[:total_demand_mwh] > 0 ? day[:renewables_mwh] / day[:total_demand_mwh] : 0.0,
            avg_visible_abs_forecast_error = avg_visible_abs_forecast_error,
            avg_tail_abs_forecast_error = avg_tail_abs_forecast_error,
        ))
    end

    return DataFrame(rows)
end

function sanitize_excel_case_name(case_name::AbstractString)
    safe = replace(lowercase(String(case_name)), r"[^a-z0-9]+" => "_")
    safe = replace(safe, r"^_+|_+$" => "")
    return isempty(safe) ? "case" : safe
end

function sheet_safe_name(name::AbstractString)
    safe = replace(String(name), r"[\[\]\*\?/\\:]" => "_")
    safe = isempty(strip(safe)) ? "Sheet" : strip(safe)
    return String(length(safe) <= 31 ? safe : safe[1:31])
end

function pair_sheet_name(left_name::AbstractString, right_name::AbstractString, existing::Set{String})
    base = sheet_safe_name("$(sanitize_excel_case_name(left_name))_vs_$(sanitize_excel_case_name(right_name))")
    candidate = base
    suffix = 2
    while candidate in existing
        suffix_str = "_$(suffix)"
        truncated = length(base) + length(suffix_str) <= 31 ? base : base[1:(31 - length(suffix_str))]
        candidate = truncated * suffix_str
        suffix += 1
    end
    push!(existing, candidate)
    return String(candidate)
end

function daily_summary_metric_specs()
    return [
        (:social_welfare_eur, "Social Welfare (EUR)"),
        (:generation_cost_eur, "Generation Cost (EUR)"),
        (:demand_value_eur, "Demand Value (EUR)"),
        (:wind_curtailment_mwh, "Curtailment (MWh)"),
        (:imbalance_mwh, "Imbalance (MWh, +up / -down)"),
        (:storage_throughput_mwh, "Storage Throughput (MWh)"),
        (:storage_charge_mwh, "Charge (MWh)"),
        (:storage_discharge_mwh, "Discharge (MWh)"),
        (:avg_charging_price_eur_per_mwh, "Charging Price (EUR/MWh)"),
        (:avg_discharging_price_eur_per_mwh, "Discharging Price (EUR/MWh)"),
        (:storage_revenue_eur, "Storage Revenue (EUR)"),
        (:end_soc_mwh, "End SOC (MWh)"),
    ]
end

function daily_driver_metric_specs()
    return [
        (:avg_price_eur_per_mwh, "Average Price (EUR/MWh)"),
        (:price_std_eur_per_mwh, "Price Std Dev (EUR/MWh)"),
        (:price_range_eur_per_mwh, "Price Range (EUR/MWh)"),
        (:max_price_eur_per_mwh, "Max Price (EUR/MWh)"),
        (:imbalance_mwh, "Imbalance (MWh, +up / -down)"),
        (:total_demand_mwh, "Total Demand (MWh)"),
        (:flex_demand_mwh, "Flex Demand (MWh)"),
        (:wind_mwh, "Wind Output (MWh)"),
        (:solar_mwh, "Solar Output (MWh)"),
        (:renewables_mwh, "Renewables Output (MWh)"),
        (:mid_dispatch_mwh, "Mid Dispatch (MWh)"),
        (:peak_dispatch_mwh, "Peak Dispatch (MWh)"),
        (:mid_peak_dispatch_mwh, "Mid+Peak Dispatch (MWh)"),
        (:thermal_dispatch_mwh, "Thermal Dispatch (MWh)"),
        (:net_storage_discharge_mwh, "Net Storage Discharge (MWh)"),
        (:gross_residual_load_proxy_mwh, "Gross Residual Load Proxy (MWh)"),
        (:net_residual_load_proxy_mwh, "Net Residual Load Proxy (MWh)"),
        (:renewable_share_of_demand, "Renewable Share of Demand"),
        (:avg_visible_abs_forecast_error, "Avg Visible |Forecast Error|"),
        (:avg_tail_abs_forecast_error, "Avg Tail |Forecast Error|"),
    ]
end

function build_daily_pair_dataframe(left_case::AbstractDict, right_case::AbstractDict)
    left_name = String(left_case[:case_name])
    right_name = String(right_case[:case_name])
    left_df = collect_daily_case_metrics(left_case[:all_results], left_case[:cfg])
    right_df = collect_daily_case_metrics(right_case[:all_results], right_case[:cfg])

    rename!(left_df, Dict(name => Symbol("left_", name) for name in names(left_df) if !(Symbol(name) in [:simulation_day, :calendar_day])))
    rename!(right_df, Dict(name => Symbol("right_", name) for name in names(right_df) if !(Symbol(name) in [:simulation_day, :calendar_day])))

    paired = outerjoin(left_df, right_df, on=[:simulation_day, :calendar_day])
    diff_or_missing(left, right) = (ismissing(left) || ismissing(right)) ? missing : Float64(right) - Float64(left)

    for (metric, _) in daily_summary_metric_specs()
        left_col = Symbol("left_", metric)
        right_col = Symbol("right_", metric)
        diff_col = Symbol(metric, "_diff")
        paired[!, diff_col] = [
            diff_or_missing(left, right) for (left, right) in zip(paired[!, left_col], paired[!, right_col])
        ]
    end

    paired[!, :delta_social_welfare_sort] = [
        ismissing(value) ? -Inf : Float64(value) for value in paired.social_welfare_eur_diff
    ]
    sort!(paired, [:delta_social_welfare_sort, :calendar_day], rev=[true, false])
    paired[!, :rank_by_delta_social_welfare] = collect(1:nrow(paired))

    select_cols = Symbol[
        :rank_by_delta_social_welfare,
        :simulation_day,
        :calendar_day,
        :left_executed_hours,
        :right_executed_hours,
        :left_is_complete_day,
        :right_is_complete_day,
    ]
    for (metric, _) in daily_summary_metric_specs()
        push!(select_cols, Symbol("left_", metric))
        push!(select_cols, Symbol("right_", metric))
        push!(select_cols, Symbol(metric, "_diff"))
    end

    return select(paired, select_cols), left_name, right_name
end

function daily_delta_swf_stats_row(pair_df::DataFrame, left_name::AbstractString, right_name::AbstractString;
                                   comparison_type::AbstractString="Pairwise")
    deltas = collect(skipmissing(pair_df.social_welfare_eur_diff))
    n = length(deltas)
    n > 0 || error("Cannot compute daily delta SWF statistics without at least one aligned day.")

    mean_delta = mean(deltas)
    median_delta = median(deltas)
    std_delta = n >= 2 ? std(deltas) : missing
    ci_lower = missing
    ci_upper = missing
    if n >= 2
        se = std(deltas) / sqrt(n)
        crit = quantile(TDist(n - 1), 0.975)
        margin = crit * se
        ci_lower = mean_delta - margin
        ci_upper = mean_delta + margin
    end

    tol = 1e-9
    case_b_better = count(delta -> delta > tol, deltas)
    case_a_better = count(delta -> delta < -tol, deltas)
    equal_days = n - case_a_better - case_b_better

    return (
        comparison_type = String(comparison_type),
        case_a = String(left_name),
        case_b = String(right_name),
        delta_definition = "$(right_name) - $(left_name)",
        aligned_days = n,
        mean_daily_delta_swf_eur = mean_delta,
        median_daily_delta_swf_eur = median_delta,
        std_daily_delta_swf_eur = std_delta,
        ci95_lower_mean_delta_swf_eur = ci_lower,
        ci95_upper_mean_delta_swf_eur = ci_upper,
        share_days_case_b_better = case_b_better / n,
        share_days_case_a_better = case_a_better / n,
        share_days_equal = equal_days / n,
        count_days_case_b_better = case_b_better,
        count_days_case_a_better = case_a_better,
        count_days_equal = equal_days,
    )
end

function build_daily_driver_pair_dataframe(left_case::AbstractDict, right_case::AbstractDict;
                                           comparison_type::AbstractString="Pairwise")
    left_name = String(left_case[:case_name])
    right_name = String(right_case[:case_name])
    left_df = collect_daily_case_metrics(left_case[:all_results], left_case[:cfg])
    right_df = collect_daily_case_metrics(right_case[:all_results], right_case[:cfg])

    rename!(left_df, Dict(name => Symbol("left_", name) for name in names(left_df) if !(Symbol(name) in [:simulation_day, :calendar_day])))
    rename!(right_df, Dict(name => Symbol("right_", name) for name in names(right_df) if !(Symbol(name) in [:simulation_day, :calendar_day])))

    paired = outerjoin(left_df, right_df, on=[:simulation_day, :calendar_day])
    diff_or_missing(left, right) = (ismissing(left) || ismissing(right)) ? missing : Float64(right) - Float64(left)

    for (metric, _) in daily_summary_metric_specs()
        paired[!, Symbol("delta_", metric)] = [
            diff_or_missing(left, right)
            for (left, right) in zip(paired[!, Symbol("left_", metric)], paired[!, Symbol("right_", metric)])
        ]
    end

    for (metric, _) in daily_driver_metric_specs()
        paired[!, Symbol("delta_", metric)] = [
            diff_or_missing(left, right)
            for (left, right) in zip(paired[!, Symbol("left_", metric)], paired[!, Symbol("right_", metric)])
        ]
    end

    paired[!, :delta_social_welfare_sort] = [
        ismissing(value) ? -Inf : Float64(value) for value in paired.delta_social_welfare_eur
    ]
    sort!(paired, [:delta_social_welfare_sort, :calendar_day], rev=[true, false])
    paired[!, :rank_by_delta_social_welfare] = collect(1:nrow(paired))
    paired[!, :comparison_type] .= String(comparison_type)
    paired[!, :case_a] .= left_name
    paired[!, :case_b] .= right_name
    paired[!, :delta_definition] .= "$(right_name) - $(left_name)"

    select_cols = Symbol[
        :comparison_type,
        :case_a,
        :case_b,
        :delta_definition,
        :rank_by_delta_social_welfare,
        :simulation_day,
        :calendar_day,
        :left_executed_hours,
        :right_executed_hours,
        :left_is_complete_day,
        :right_is_complete_day,
        :delta_social_welfare_eur,
        :delta_generation_cost_eur,
        :delta_demand_value_eur,
        :delta_wind_curtailment_mwh,
        :delta_storage_revenue_eur,
        :delta_storage_throughput_mwh,
    ]

    for (metric, _) in daily_driver_metric_specs()
        push!(select_cols, Symbol("left_", metric))
        push!(select_cols, Symbol("right_", metric))
        push!(select_cols, Symbol("delta_", metric))
    end

    return select(paired, select_cols)
end

function case_column_prefix(case_name::AbstractString)
    return sanitize_excel_case_name(case_name)
end

function daily_summary_case_pairs(case_outputs::AbstractVector{<:AbstractDict})
    pairs = Tuple{AbstractDict, AbstractDict}[]

    metadata(case_output) = (
        case_name = String(case_output[:case_name]),
        case_type = String(case_output[:case_type]),
        look_ahead = Int(case_output[:kpis].look_ahead_h),
        storage_energy = float(case_output[:kpis].storage_energy_capacity_mwh),
        storage_power = float(case_output[:kpis].storage_power_capacity_mw),
    )

    entries = [(case_output=case_output, meta=metadata(case_output)) for case_output in case_outputs]

    grouped = Dict{Tuple{Int, Float64, Float64}, Dict{String, AbstractDict}}()
    for entry in entries
        key = (entry.meta.look_ahead, entry.meta.storage_energy, entry.meta.storage_power)
        if !haskey(grouped, key)
            grouped[key] = Dict{String, AbstractDict}()
        end
        grouped[key][entry.meta.case_type] = entry.case_output
    end

    for key in sort(collect(keys(grouped)))
        bucket = grouped[key]
        if haskey(bucket, "fixed") && haskey(bucket, "rolling")
            push!(pairs, (bucket["fixed"], bucket["rolling"]))
        end
    end

    rolling_by_storage = Dict{Tuple{Float64, Float64}, Vector{NamedTuple}}()
    for entry in entries
        entry.meta.case_type == "rolling" || continue
        key = (entry.meta.storage_energy, entry.meta.storage_power)
        if !haskey(rolling_by_storage, key)
            rolling_by_storage[key] = NamedTuple[]
        end
        push!(rolling_by_storage[key], entry)
    end

    for key in sort(collect(keys(rolling_by_storage)))
        bucket = sort(rolling_by_storage[key], by=x -> x.meta.look_ahead)
        if length(bucket) < 2
            continue
        end
        for i in 1:(length(bucket) - 1)
            for j in (i + 1):length(bucket)
                push!(pairs, (bucket[i].case_output, bucket[j].case_output))
            end
        end
    end

    return pairs
end

function daily_summary_rolling_groups(case_outputs::AbstractVector{<:AbstractDict}; min_cases::Int=3)
    groups = Vector{Vector{AbstractDict}}()

    metadata(case_output) = (
        case_type = String(case_output[:case_type]),
        look_ahead = Int(case_output[:kpis].look_ahead_h),
        storage_energy = float(case_output[:kpis].storage_energy_capacity_mwh),
        storage_power = float(case_output[:kpis].storage_power_capacity_mw),
    )

    rolling_by_storage = Dict{Tuple{Float64, Float64}, Vector{NamedTuple}}()
    for case_output in case_outputs
        meta = metadata(case_output)
        meta.case_type == "rolling" || continue
        key = (meta.storage_energy, meta.storage_power)
        if !haskey(rolling_by_storage, key)
            rolling_by_storage[key] = NamedTuple[]
        end
        push!(rolling_by_storage[key], (case_output=case_output, meta=meta))
    end

    for key in sort(collect(keys(rolling_by_storage)))
        bucket = sort(rolling_by_storage[key], by=x -> x.meta.look_ahead)
        if length(bucket) >= min_cases
            push!(groups, [entry.case_output for entry in bucket])
        end
    end

    return groups
end

function build_daily_multicase_dataframe(case_group::AbstractVector{<:AbstractDict})
    length(case_group) >= 2 || error("Need at least two cases for a multi-case daily summary.")

    ordered_cases = sort(collect(case_group), by=case_output -> Int(case_output[:kpis].look_ahead_h))
    case_names = [String(case_output[:case_name]) for case_output in ordered_cases]
    prefixes = [case_column_prefix(name) for name in case_names]

    merged = nothing
    for (case_output, prefix) in zip(ordered_cases, prefixes)
        df = collect_daily_case_metrics(case_output[:all_results], case_output[:cfg])
        rename!(df, Dict(name => Symbol(prefix, "_", name) for name in names(df) if !(Symbol(name) in [:simulation_day, :calendar_day])))
        merged = merged === nothing ? df : outerjoin(merged, df, on=[:simulation_day, :calendar_day])
    end

    sort_symbol = Symbol(prefixes[end], "_social_welfare_eur")
    base_sort_symbol = Symbol(prefixes[1], "_social_welfare_eur")
    merged[!, :delta_social_welfare_sort] = [
        (ismissing(long_val) || ismissing(base_val)) ? -Inf : Float64(long_val) - Float64(base_val)
        for (long_val, base_val) in zip(merged[!, sort_symbol], merged[!, base_sort_symbol])
    ]
    sort!(merged, [:delta_social_welfare_sort, :calendar_day], rev=[true, false])
    merged[!, :rank_by_span_social_welfare] = collect(1:nrow(merged))

    pair_specs = NamedTuple[]
    for i in 1:(length(ordered_cases) - 1)
        for j in (i + 1):length(ordered_cases)
            left_name = case_names[i]
            right_name = case_names[j]
            left_prefix = prefixes[i]
            right_prefix = prefixes[j]
            pair_key = Symbol(left_prefix, "_to_", right_prefix)
            push!(pair_specs, (
                left_name=left_name,
                right_name=right_name,
                left_prefix=left_prefix,
                right_prefix=right_prefix,
                pair_key=pair_key,
                label="$(right_name) - $(left_name)",
            ))
        end
    end

    for pair in pair_specs
        for (metric, _) in daily_summary_metric_specs()
            left_col = Symbol(pair.left_prefix, "_", metric)
            right_col = Symbol(pair.right_prefix, "_", metric)
            diff_col = Symbol(pair.pair_key, "_", metric, "_diff")
            merged[!, diff_col] = [
                (ismissing(left) || ismissing(right)) ? missing : Float64(right) - Float64(left)
                for (left, right) in zip(merged[!, left_col], merged[!, right_col])
            ]
        end
    end

    return merged, ordered_cases, case_names, prefixes, pair_specs
end

function export_daily_summary_to_excel(case_outputs::AbstractVector{<:AbstractDict}; path::String="summary_daily.xlsx")
    pairs = daily_summary_case_pairs(case_outputs)
    rolling_groups = daily_summary_rolling_groups(case_outputs)

    if isempty(pairs) && isempty(rolling_groups)
        XLSX.openxlsx(path, mode="w") do xf
            sh = XLSX.addsheet!(xf, "Summary")
            sh["A1"] = "No daily summary comparisons were available for this run."
        end
        return path
    end

    col_label(n::Int) = begin
        s = ""; x = n
        while x > 0
            x -= 1; s = string(Char('A' + (x % 26))) * s; x ÷= 26
        end
        s
    end
    write_row_at!(sh, r::Int, start_col::Int, values::Vector{Any}) = (for (j, v) in enumerate(values); sh["$(col_label(start_col + j - 1))$(r)"] = v; end)
    write_row!(sh, r::Int, values::Vector{Any}) = write_row_at!(sh, r, 1, values)
    write_text!(sh, r::Int, text::String) = (sh["A$(r)"] = text)

    pair_payloads = NamedTuple[]
    stats_rows = NamedTuple[]
    for (left_case, right_case) in pairs
        pair_df, left_name, right_name = build_daily_pair_dataframe(left_case, right_case)
        driver_df = build_daily_driver_pair_dataframe(left_case, right_case)
        push!(pair_payloads, (
            pair_df=pair_df,
            driver_df=driver_df,
            left_name=left_name,
            right_name=right_name,
        ))
        push!(stats_rows, daily_delta_swf_stats_row(pair_df, left_name, right_name))
    end

    stats_df = DataFrame(stats_rows)
    driver_df_all = isempty(pair_payloads) ? DataFrame() : vcat([payload.driver_df for payload in pair_payloads]..., cols=:union)
    output_dir = dirname(path)
    CSV.write(joinpath(output_dir, "delta_swf_stats.csv"), stats_df)
    CSV.write(joinpath(output_dir, "daily_drivers.csv"), driver_df_all)

    XLSX.openxlsx(path, mode="w") do xf
        index_sheet = XLSX.addsheet!(xf, "Index")
        write_row!(index_sheet, 1, Any["Sheet", "Comparison Type", "Case A", "Case B / Group", "Ranking"])

        stats_sheet = XLSX.addsheet!(xf, "Delta_SWF_Stats")
        write_text!(stats_sheet, 1, "DAILY DELTA SWF STATISTICS")
        write_row!(
            stats_sheet,
            3,
            Any[
                "Comparison Type",
                "Case A",
                "Case B",
                "Delta Definition",
                "Aligned Days",
                "Mean Daily Delta SWF (EUR)",
                "Median Daily Delta SWF (EUR)",
                "Std Dev Daily Delta SWF (EUR)",
                "95% CI Lower",
                "95% CI Upper",
                "Share Days Case B Better",
                "Share Days Case A Better",
                "Share Days Equal",
                "Count Days Case B Better",
                "Count Days Case A Better",
                "Count Days Equal",
            ],
        )
        for (idx, row) in enumerate(stats_rows)
            write_row!(
                stats_sheet,
                4 + idx - 1,
                Any[
                    row.comparison_type,
                    row.case_a,
                    row.case_b,
                    row.delta_definition,
                    row.aligned_days,
                    row.mean_daily_delta_swf_eur,
                    row.median_daily_delta_swf_eur,
                    row.std_daily_delta_swf_eur,
                    row.ci95_lower_mean_delta_swf_eur,
                    row.ci95_upper_mean_delta_swf_eur,
                    row.share_days_case_b_better,
                    row.share_days_case_a_better,
                    row.share_days_equal,
                    row.count_days_case_b_better,
                    row.count_days_case_a_better,
                    row.count_days_equal,
                ],
            )
        end

        driver_sheet = XLSX.addsheet!(xf, "Daily_Drivers")
        write_text!(driver_sheet, 1, "DAILY DRIVER TABLE")
        write_row!(
            driver_sheet,
            3,
            Any[
                "Comparison Type",
                "Case A",
                "Case B",
                "Delta Definition",
                "Rank by Delta SWF",
                "Simulation Day",
                "Calendar Day",
                "Case A Executed Hours",
                "Case B Executed Hours",
                "Case A Complete Day",
                "Case B Complete Day",
                "Delta SWF (EUR)",
                "Delta Generation Cost (EUR)",
                "Delta Demand Value (EUR)",
                "Delta Curtailment (MWh)",
                "Delta Imbalance (MWh, +up / -down)",
                "Delta Storage Revenue (EUR)",
                "Delta Storage Throughput (MWh)",
            ],
        )
        header_row_1 = Any[]
        header_row_2 = Any[]
        for (_, label) in daily_driver_metric_specs()
            append!(header_row_1, Any[label, label, label])
            append!(header_row_2, Any["Case A", "Case B", "Difference"])
        end
        write_row!(driver_sheet, 4, vcat(fill("", 18), header_row_1))
        write_row!(driver_sheet, 5, vcat(fill("", 18), header_row_2))

        driver_row = 6
        for payload in pair_payloads
            for row in eachrow(payload.driver_df)
                values = Any[
                    row.comparison_type,
                    row.case_a,
                    row.case_b,
                    row.delta_definition,
                    row.rank_by_delta_social_welfare,
                    row.simulation_day,
                    string(row.calendar_day),
                    row.left_executed_hours,
                    row.right_executed_hours,
                    row.left_is_complete_day,
                    row.right_is_complete_day,
                    row.delta_social_welfare_eur,
                    row.delta_generation_cost_eur,
                    row.delta_demand_value_eur,
                    row.delta_wind_curtailment_mwh,
                    row.delta_imbalance_mwh,
                    row.delta_storage_revenue_eur,
                    row.delta_storage_throughput_mwh,
                ]
                for (metric, _) in daily_driver_metric_specs()
                    push!(values, row[Symbol("left_", metric)])
                    push!(values, row[Symbol("right_", metric)])
                    push!(values, row[Symbol("delta_", metric)])
                end
                write_row!(driver_sheet, driver_row, values)
                driver_row += 1
            end
        end

        used_sheet_names = Set(["Index", "Delta_SWF_Stats", "Daily_Drivers"])
        index_row = 2

        for payload in pair_payloads
            pair_df = payload.pair_df
            left_name = payload.left_name
            right_name = payload.right_name
            sheet_name = pair_sheet_name(left_name, right_name, used_sheet_names)
            sh = XLSX.addsheet!(xf, sheet_name)

            write_text!(sh, 1, "DAILY SUMMARY")
            write_row!(sh, 2, Any["Case A", left_name])
            write_row!(sh, 3, Any["Case B", right_name])
            write_row!(sh, 4, Any["Difference", "$(right_name) - $(left_name)"])
            write_row!(sh, 5, Any["Ranking", "Sorted from best to worst by daily social welfare difference"])

            header_row_1 = Any["", "", "", "Executed Hours", "Executed Hours", "Complete Day", "Complete Day"]
            header_row_2 = Any["Rank", "Simulation Day", "Calendar Day", left_name, right_name, left_name, right_name]
            for (_, label) in daily_summary_metric_specs()
                append!(header_row_1, Any[label, label, label])
                append!(header_row_2, Any[left_name, right_name, "Difference"])
            end
            write_row!(sh, 7, header_row_1)
            write_row!(sh, 8, header_row_2)

            start_row = 9
            for (offset, row) in enumerate(eachrow(pair_df))
                values = Any[
                    row.rank_by_delta_social_welfare,
                    row.simulation_day,
                    string(row.calendar_day),
                    row.left_executed_hours,
                    row.right_executed_hours,
                    row.left_is_complete_day,
                    row.right_is_complete_day,
                ]
                for (metric, _) in daily_summary_metric_specs()
                    push!(values, row[Symbol("left_", metric)])
                    push!(values, row[Symbol("right_", metric)])
                    push!(values, row[Symbol(metric, "_diff")])
                end
                write_row!(sh, start_row + offset - 1, values)
            end

            write_row!(index_sheet, index_row, Any[sheet_name, "Pairwise", left_name, right_name, "Descending daily SWF difference"])
            index_row += 1
        end

        for case_group in rolling_groups
            merged_df, ordered_cases, case_names, prefixes, pair_specs = build_daily_multicase_dataframe(case_group)
            group_title = join(["$(Int(case_output[:kpis].look_ahead_h))h" for case_output in ordered_cases], "_")
            sheet_name = pair_sheet_name("rolling_group", group_title, used_sheet_names)
            sh = XLSX.addsheet!(xf, sheet_name)

            write_text!(sh, 1, "DAILY SUMMARY")
            write_row!(sh, 2, Any["Comparison Type", "Multi-case rolling look-ahead group"])
            write_row!(sh, 3, Any["Cases", join(case_names, " | ")])
            write_row!(sh, 4, Any["Primary Ranking", "$(case_names[end]) - $(case_names[1]) social welfare difference"])

            header_row_1 = Any["", "", ""]
            header_row_2 = Any["Rank", "Simulation Day", "Calendar Day"]
            for case_name in case_names
                append!(header_row_1, Any["Executed Hours", "Complete Day"])
                append!(header_row_2, Any[case_name, case_name])
            end
            for (_, label) in daily_summary_metric_specs()
                for case_name in case_names
                    push!(header_row_1, label)
                    push!(header_row_2, case_name)
                end
                for pair in pair_specs
                    push!(header_row_1, label)
                    push!(header_row_2, pair.label)
                end
            end
            write_row!(sh, 6, header_row_1)
            write_row!(sh, 7, header_row_2)

            start_row = 8
            for (offset, row) in enumerate(eachrow(merged_df))
                values = Any[
                    row.rank_by_span_social_welfare,
                    row.simulation_day,
                    string(row.calendar_day),
                ]
                for prefix in prefixes
                    push!(values, row[Symbol(prefix, "_executed_hours")])
                    push!(values, row[Symbol(prefix, "_is_complete_day")])
                end
                for (metric, _) in daily_summary_metric_specs()
                    for prefix in prefixes
                        push!(values, row[Symbol(prefix, "_", metric)])
                    end
                    for pair in pair_specs
                        push!(values, row[Symbol(pair.pair_key, "_", metric, "_diff")])
                    end
                end
                write_row!(sh, start_row + offset - 1, values)
            end

            write_row!(
                index_sheet,
                index_row,
                Any[sheet_name, "Rolling group", case_names[1], join(case_names[2:end], " | "), "Descending $(case_names[end]) - $(case_names[1]) daily SWF difference"],
            )
            index_row += 1
        end
    end

    return path
end


function export_full_summary_to_excel(all_results::Dict, cfg::Dict; path::String="economic_summary.xlsx")
    costs = calculate_system_costs(all_results, cfg)
    revenues_exec = calculate_generator_revenues_executed(all_results, cfg)
    revenues_full = calculate_generator_revenues_full(all_results)
    storage = calculate_storage_revenue(all_results, cfg)
    welfare = calculate_social_welfare(all_results, cfg)
    daily_metrics = calculate_average_daily_metrics(all_results, cfg)
    
    sim_days = daily_metrics[:sim_days]
    norm_days = daily_metrics[:normalization_days]
    clearing_details = all_results[:clearing_details]

    # Helpers
    col_label(n::Int) = begin
        s = ""; x = n
        while x > 0
            x -= 1; s = string(Char('A' + (x % 26))) * s; x ÷= 26
        end
        s
    end
    write_row_at!(sh, r::Int, start_col::Int, values::Vector{Any}) = (for (j,v) in enumerate(values); sh["$(col_label(start_col + j - 1))$(r)"] = v; end)
    write_row!(sh, r::Int, values::Vector{Any}) = write_row_at!(sh, r, 1, values)
    write_text_at!(sh, r::Int, col::Int, text::String) = (sh["$(col_label(col))$(r)"] = text)
    write_text!(sh, r::Int, text::String) = write_text_at!(sh, r, 1, text)

    XLSX.openxlsx(path, mode="w") do xf
        sh = XLSX.addsheet!(xf, "Summary")
        row = 1

        # Title
        write_text!(sh, row, "ECONOMIC SUMMARY ($(round(norm_days; digits=3)) normalized days; configured $(sim_days) days)"); row += 2

        # Top summary blocks
        total_executed_energy = sum(values(revenues_exec[:generator_energy]))
        avg_executed_price = total_executed_energy > 0 ? revenues_exec[:total_revenue] / total_executed_energy : 0.0
        total_wind_curtailed = haskey(all_results, :curtailment_energy) ? sum(all_results[:curtailment_energy]) : 0.0
        total_imbalance = haskey(all_results, :imbalance_energy) ? sum(all_results[:imbalance_energy]) : 0.0
        first_clearing = minimum(collect(keys(clearing_details)))
        last_clearing = maximum(collect(keys(clearing_details)))
        initial_soc = clearing_details[first_clearing][:storage_soc_start]
        last_clearing_details = clearing_details[last_clearing]
        final_soc_end_horizon = get(
            last_clearing_details,
            :storage_soc_end_executed,
            get(last_clearing_details, :storage_soc_end_window, 0.0),
        )
        total_storage_losses = storage[:total_charging_energy] - storage[:total_discharge_energy] - (final_soc_end_horizon - initial_soc)

        # SOCIAL WELFARE (A3)
        write_text!(sh, row, "SOCIAL WELFARE"); row += 1
        write_row!(sh, row, Any["Metric", "Total (EUR)", "Per Day (EUR)"]); row += 1
        write_row!(sh, row, Any["Total Demand Value", welfare[:total_demand_value], daily_metrics[:daily_welfare][:demand_value]]); row += 1
        write_row!(sh, row, Any["Total Generation Cost", welfare[:total_generation_cost], daily_metrics[:daily_welfare][:generation_cost]]); row += 1
        write_row!(sh, row, Any["Social Welfare", welfare[:social_welfare], daily_metrics[:daily_welfare][:social_welfare]])

        # GENERAL (E3)
        general_row = 3
        write_text_at!(sh, general_row, 5, "GENERAL"); general_row += 1
        write_row_at!(sh, general_row, 5, Any["Average Executed Price in EUR/MWh", avg_executed_price]); general_row += 1
        write_row_at!(sh, general_row, 5, Any["Total Wind Curtailed (MWh)", total_wind_curtailed]); general_row += 1
        write_row_at!(sh, general_row, 5, Any["Total Imbalance (MWh, +up / -down)", total_imbalance]); general_row += 1

        row = max(row, general_row) + 2

        # PRODUCER REVENUES (Executed-only)
        write_text!(sh, row, "PRODUCER REVENUES (Executed-only)"); row += 1
        write_row!(sh, row, Any["Generator", "Energy (MWh)", "Revenue (EUR)", "Avg Price", "Revenue/Day (EUR)"]); row += 1
        for (gen, revenue) in sort(collect(revenues_exec[:generator_revenues]))
            energy = revenues_exec[:generator_energy][gen]
            avg_price = energy > 0 ? revenue / energy : 0.0
            daily_rev = daily_metrics[:daily_gen_revenues_exec][gen]
            write_row!(sh, row, Any[gen, energy, revenue, avg_price, daily_rev]); row += 1
        end
        write_row!(sh, row, Any["Total", sum(values(revenues_exec[:generator_energy])), revenues_exec[:total_revenue], "", daily_metrics[:daily_total_revenue_exec]]); row += 2

        # TOTAL FINANCIAL REVENUE (incl financial repositions → sum(q*price))
        write_text!(sh, row, "TOTAL FINANCIAL REVENUE (incl financial repositions → sum(q*price))"); row += 1
        write_row!(sh, row, Any["Generator", "Net Revenue", "Net Traded", "Gross Traded", "Revenue/Day"]); row += 1
        for (gen, revenue) in sort(collect(revenues_full[:generator_revenues]))
            net_trade = revenues_full[:traded_net][gen]
            gross_trade = revenues_full[:traded_gross][gen]
            daily_rev = daily_metrics[:daily_gen_revenues_full][gen]
            write_row!(sh, row, Any[gen, revenue, net_trade, gross_trade, daily_rev]); row += 1
        end
        write_row!(sh, row, Any["Total Net Revenue", revenues_full[:total_revenue], "", "", daily_metrics[:daily_total_revenue_full]]); row += 2

        # GENERATOR COSTS (Production Costs)
        write_text!(sh, row, "GENERATOR COSTS (Production Costs)"); row += 1
        write_row!(sh, row, Any["Generator", "Total Cost (EUR)", "Cost/Day (EUR)"]); row += 1
        for (gen, cost) in sort(collect(costs[:generator_costs]))
            daily_cost = daily_metrics[:daily_gen_costs][gen]
            write_row!(sh, row, Any[gen, cost, daily_cost]); row += 1
        end
        write_row!(sh, row, Any["Total System Cost", costs[:total_cost], daily_metrics[:daily_total_cost]]); row += 1
        write_row!(sh, row, Any["Average per Clearing", costs[:total_cost] / costs[:total_clearings], ""]); row += 2

        # GENERATOR PROFITS (Full Revenue - Cost)
        write_text!(sh, row, "GENERATOR PROFITS (Full Revenue - Cost)"); row += 1
        write_row!(sh, row, Any["Generator", "Total Profit (EUR)", "Profit/Day (EUR)"]); row += 1
        total_profit = 0.0
        total_daily_profit = 0.0
        for gen in sort(collect(keys(revenues_full[:generator_revenues])))
            revenue = revenues_full[:generator_revenues][gen]
            cost = haskey(costs[:generator_costs], gen) ? costs[:generator_costs][gen] : 0.0
            profit = revenue - cost
            daily_profit = profit / norm_days
            total_profit += profit
            total_daily_profit += daily_profit
            write_row!(sh, row, Any[gen, profit, daily_profit]); row += 1
        end
        write_row!(sh, row, Any["Total Generator Profit", total_profit, total_daily_profit]); row += 2

        # STORAGE REVENUE
        write_text!(sh, row, "STORAGE REVENUE"); row += 1
        write_row!(sh, row, Any["Metric", "Total", "Per Day"]); row += 1
        write_row!(sh, row, Any["Energy Discharged (MWh)", storage[:total_discharge_energy], daily_metrics[:daily_storage][:discharge_energy]]); row += 1
        write_row!(sh, row, Any["Energy Charged (MWh)", storage[:total_charging_energy], daily_metrics[:daily_storage][:charging_energy]]); row += 1
        write_row!(sh, row, Any["Avg Discharge Price (EUR/MWh)", storage[:avg_discharge_price], ""]); row += 1
        write_row!(sh, row, Any["Avg Charging Price (EUR/MWh)", storage[:avg_charging_price], ""]); row += 1
        write_row!(sh, row, Any["Discharge Revenue (EUR)", storage[:discharge_revenue], daily_metrics[:daily_storage][:discharge_revenue]]); row += 1
        write_row!(sh, row, Any["Charging Cost (EUR)", storage[:charging_cost], daily_metrics[:daily_storage][:charging_cost]]); row += 1
        write_row!(sh, row, Any["Net Storage Revenue (EUR)", storage[:net_revenue], daily_metrics[:daily_storage][:net_revenue]]); row += 1
        write_row!(sh, row, Any["Total Losses (MWh)", total_storage_losses, total_storage_losses / norm_days]); row += 1
        write_row!(sh, row, Any["SOC End of Horizon (MWh)", final_soc_end_horizon, ""]); row += 2

        # DELIVERY-HOUR AUDIT
        write_text!(sh, row, "DELIVERY-HOUR AUDIT (sum of trades vs executed)"); row += 1
        # Recompute audit aggregates
        ledger, executed, _ = compute_delivery_hour_ledger(all_results, cfg)
        executed_hours = unique(h for (_, h) in keys(executed))
        gens = unique(first(k) for k in keys(executed))
        write_row!(sh, row, Any["Generator", "Σ net trades", "Σ executed", "Max |Δ| per hour"]); row += 1
        for gen in sort(collect(gens))
            sum_net = 0.0; sum_exec = 0.0; max_gap = 0.0
            for H in sort(collect(executed_hours))
                key = (gen, H)
                netH = haskey(ledger, key) ? ledger[key][:net_qty] : 0.0
                execH = haskey(executed, key) ? executed[key] : 0.0
                sum_net += netH
                sum_exec += execH
                max_gap = max(max_gap, abs(netH - execH))
            end
            write_row!(sh, row, Any[gen, sum_net, sum_exec, max_gap]); row += 1
        end
    end
    return path
end

function print_cost_summary(all_results::Dict, cfg::Dict)
    costs = calculate_system_costs(all_results, cfg)
    revenues_exec = calculate_generator_revenues_executed(all_results, cfg)
    revenues_full = calculate_generator_revenues_full(all_results)
    storage = calculate_storage_revenue(all_results, cfg)
    welfare = calculate_social_welfare(all_results, cfg)
    adequacy = calculate_adequacy_metrics(all_results, cfg)
    daily_metrics = calculate_average_daily_metrics(all_results, cfg)
    
    sim_days = daily_metrics[:sim_days]
    norm_days = daily_metrics[:normalization_days]

    println()
    println("="^80)
    println("ECONOMIC SUMMARY ($(round(norm_days; digits=3)) normalized days; configured $(sim_days) days)")
    println("="^80)
    println()

    println("PRODUCER REVENUES (Executed-only)")
    println("-"^80)
    @printf "%-20s %12s %12s %12s %12s\n" "Generator" "Energy (MWh)" "Revenue (EUR)" "Avg Price" "Rev/Day (EUR)"
    println("-"^80)
    for (gen, revenue) in sort(collect(revenues_exec[:generator_revenues]))
        energy = revenues_exec[:generator_energy][gen]
        avg_price = energy > 0 ? revenue / energy : 0.0
        daily_rev = daily_metrics[:daily_gen_revenues_exec][gen]
        @printf "%-20s %12.2f %12.2f %12.2f %12.2f\n" gen energy revenue avg_price daily_rev
    end
    println("-"^80)
    @printf "%-20s %12.2f %12.2f %12s %12.2f\n" "Total" sum(values(revenues_exec[:generator_energy])) revenues_exec[:total_revenue] "" daily_metrics[:daily_total_revenue_exec]

    println()
    println("TOTAL FINANCIAL REVENUE (incl financial repositions → sum(q*price))")
    println("-"^80)
    @printf "%-20s %12s %12s %12s %12s %12s %12s\n" "Generator" "Net Revenue" "Net Traded" "Gross Traded" "Avg Sell" "Avg Buy" "Rev/Day"
    println("-"^80)
    for (gen, revenue) in sort(collect(revenues_full[:generator_revenues]))
        net_trade = revenues_full[:traded_net][gen]
        gross_trade = revenues_full[:traded_gross][gen]
        avg_sell = revenues_full[:avg_sell_price][gen]
        avg_buyback = revenues_full[:avg_buyback_price][gen]
        daily_rev = daily_metrics[:daily_gen_revenues_full][gen]
        @printf "%-20s %12.2f %12.2f %12.2f %12.2f %12.2f %12.2f\n" gen revenue net_trade gross_trade avg_sell avg_buyback daily_rev
    end
    println("-"^80)
    @printf "%-20s %12.2f %12s %12s %12s %12s %12.2f\n" "Total Net Revenue" revenues_full[:total_revenue] "" "" "" "" daily_metrics[:daily_total_revenue_full]

    println()
    println("BUY-BACK ANALYSIS (Financial Trades)")
    println("-"^80)
    @printf "%-20s %14s %14s %14s %14s\n" "Generator" "Sold Qty" "Buy-back Qty" "Avg Sell" "Avg Buy-back"
    println("-"^80)
    for gen in sort(collect(keys(revenues_full[:generator_revenues])))
        sold_qty = revenues_full[:sold_qty][gen]
        buy_qty = revenues_full[:buyback_qty][gen]
        avg_sell = revenues_full[:avg_sell_price][gen]
        avg_buy = revenues_full[:avg_buyback_price][gen]
        @printf "%-20s %14.2f %14.2f %14.2f %14.2f\n" gen sold_qty buy_qty avg_sell avg_buy
    end

    println()
    println("GENERATOR COSTS (Production Costs)")
    println("-"^80)
    @printf "%-20s %16s %16s\n" "Generator" "Total Cost (EUR)" "Cost/Day (EUR)"
    println("-"^80)
    for (gen, cost) in sort(collect(costs[:generator_costs]))
        daily_cost = daily_metrics[:daily_gen_costs][gen]
        @printf "%-20s %16.2f %16.2f\n" gen cost daily_cost
    end
    println("-"^80)
    @printf "%-20s %16.2f %16.2f\n" "Total System Cost" costs[:total_cost] daily_metrics[:daily_total_cost]
    @printf "%-20s %16.2f %16.2f\n" "Average per Clearing" (costs[:total_cost] / costs[:total_clearings]) (daily_metrics[:daily_total_cost] / (costs[:total_clearings] / norm_days))

    println()
    println("SOCIAL WELFARE")
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Total Demand Value" welfare[:total_demand_value] daily_metrics[:daily_welfare][:demand_value]
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Total Generation Cost" welfare[:total_generation_cost] daily_metrics[:daily_welfare][:generation_cost]
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Social Welfare" welfare[:social_welfare] daily_metrics[:daily_welfare][:social_welfare]

    total_imbalance = haskey(all_results, :imbalance_energy) ? sum(all_results[:imbalance_energy]) : 0.0
    println()
    println("EXECUTED PRICE / IMBALANCE")
    println("-"^80)
    @printf "%-30s: %12d h\n" "Executed Hours" adequacy[:total_executed_hours]
    @printf "%-30s: %12.2f EUR/MWh\n" "Avg Executed Price" adequacy[:avg_executed_price]
    @printf "%-30s: %12.2f EUR/MWh\n" "Max Executed Price" adequacy[:max_executed_price]
    @printf "%-30s: %12.2f MWh\n" "Total Imbalance (+up / -down)" total_imbalance
    
    println()
    println("GENERATOR PROFITS (Financial Revenue - Production Cost)")
    println("-"^80)
    @printf "%-20s %16s %16s\n" "Generator" "Total Profit (EUR)" "Profit/Day (EUR)"
    println("-"^80)
    total_profit = 0.0
    total_daily_profit = 0.0
    for gen in sort(collect(keys(revenues_full[:generator_revenues])))
        revenue = revenues_full[:generator_revenues][gen]
        cost = haskey(costs[:generator_costs], gen) ? costs[:generator_costs][gen] : 0.0
        profit = revenue - cost
        daily_profit = profit / norm_days
        total_profit += profit
        total_daily_profit += daily_profit
        @printf "%-20s %16.2f %16.2f\n" gen profit daily_profit
    end
    println("-"^80)
    @printf "%-20s %16.2f %16.2f\n" "Total Generator Profit" total_profit total_daily_profit
    @printf "\nNote: Profit = sum(q*price across all clearings) - production cost\n"
    @printf "      Negative profit for wind indicates losses from forecast-based trading.\n"
    
    println()
    println("STORAGE REVENUE")
    println("-"^80)
    @printf "%-30s: %12.2f MWh   (%.2f MWh/day)\n" "Total Energy Discharged" storage[:total_discharge_energy] daily_metrics[:daily_storage][:discharge_energy]
    @printf "%-30s: %12.2f MWh   (%.2f MWh/day)\n" "Total Energy Charged" storage[:total_charging_energy] daily_metrics[:daily_storage][:charging_energy]
    @printf "%-30s: %12.2f EUR/MWh\n" "Avg Discharge Price" storage[:avg_discharge_price]
    @printf "%-30s: %12.2f EUR/MWh\n" "Avg Charging Price" storage[:avg_charging_price]
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Discharge Revenue" storage[:discharge_revenue] daily_metrics[:daily_storage][:discharge_revenue]
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Charging Cost" storage[:charging_cost] daily_metrics[:daily_storage][:charging_cost]
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Net Storage Revenue" storage[:net_revenue] daily_metrics[:daily_storage][:net_revenue]
    @printf "%-30s: %12.2f EUR/clearing\n" "Average per Clearing" (storage[:net_revenue] / storage[:total_clearings])
    
    println()
    println("SYSTEM COSTS & PROFITS (Summary)")
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Total System Cost" costs[:total_cost] daily_metrics[:daily_total_cost]
    total_profit_summary = 0.0
    for gen in sort(collect(keys(revenues_full[:generator_revenues])))
        revenue = revenues_full[:generator_revenues][gen]
        cost = haskey(costs[:generator_costs], gen) ? costs[:generator_costs][gen] : 0.0
        profit = revenue - cost
        daily_profit = profit / norm_days
        total_profit_summary += profit
        @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "$(gen) Profit" profit daily_profit
    end
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Total Generator Profit" total_profit_summary (total_profit_summary / norm_days)

    # Top delivery hours by absolute cashflow
    ledger, _, exec_price = compute_delivery_hour_ledger(all_results, cfg)
    cash_by_hour = Dict{Int, Float64}()
    gross_by_hour = Dict{Int, Float64}()
    for ((_, H), rec) in ledger
        cash_by_hour[H] = get(cash_by_hour, H, 0.0) + rec[:cashflow]
        gross_by_hour[H] = get(gross_by_hour, H, 0.0) + rec[:gross_qty]
    end
    hours_sorted = sort(collect(keys(cash_by_hour)), by=H -> abs(cash_by_hour[H]), rev=true)
    topN = hours_sorted[1:min(5, length(hours_sorted))]

    println()
    println("TOP TRADED HOURS by cashflow")
    println("-"^80)
    @printf "%6s %14s %16s %16s\n" "Hour" "Exec Price" "Total Cashflow" "Total Gross"
    println("-"^80)
    for H in sort(topN)
        priceH = get(exec_price, H, NaN)
        cashH = cash_by_hour[H]
        grossH = gross_by_hour[H]
        @printf "%6d %14.2f %16.2f %16.2f\n" H priceH cashH grossH
    end
    
    println()
    println("="^80)

    # Compact audit at the end
    print_delivery_hour_audit(all_results, cfg)
end

# COST AND REVENUE CALCULATIONS
using XLSX


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
    
    # Get reclear frequency from config to determine how many hours executed per clearing
    reclear_freq = Int(cfg["rolling_horizon"]["reclear_frequency"])
    
    # Sum costs across all DELIVERED hours (accounting for reclear frequency)
    # Each clearing executes reclear_freq hours (hours 1 through reclear_freq)
    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        g_planned = details[:g_planned]  # Final committed position for each hour
        
        # Sum cost for all executed hours in this clearing (1 to reclear_freq)
        for h in 1:reclear_freq
            for (gen, bid_price) in gen_prices
                delivered_dispatch = g_planned[gen, h]  # MWh
                cost = delivered_dispatch * bid_price    # EUR
                gen_costs[gen] += cost
            end
        end
    end
    
    total_cost = sum(values(gen_costs))
    total_hours_delivered = length(clearing_details) * reclear_freq
    
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
    
    # Get reclear frequency from config to determine how many hours executed per clearing
    reclear_freq = Int(cfg["rolling_horizon"]["reclear_frequency"])
    
    # Map demand segment names to their storage keys in clearing_details
    dem_keys = Dict("Base" => :demand_base, "Flex" => :demand_flex)
    
    # Sum demand value across all DELIVERED hours (accounting for reclear frequency)
    # Each clearing executes reclear_freq hours (hours 1 through reclear_freq)
    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        
        # Sum value for all executed hours in this clearing (1 to reclear_freq)
        for h in 1:reclear_freq
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
    total_hours_delivered = length(clearing_details) * reclear_freq
    
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


function calculate_generator_revenues_executed(all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    prices_dict = all_results[:prices]
    dispatch_dict = all_results[:dispatch]
    
    # Track revenue by generator for executed hours only
    gen_revenues = Dict{String, Float64}()
    gen_energy = Dict{String, Float64}()
    
    # Get reclear frequency to determine how many hours executed per clearing
    reclear_freq = Int(cfg["rolling_horizon"]["reclear_frequency"])
    
    # Sum revenues across all executed hours (1 through reclear_freq for each clearing)
    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        g_planned = details[:g_planned]
        prices = prices_dict[clearing_num]
        
        # Get generators from dispatch_dict (regular Dict, easier to iterate)
        gens = collect(keys(dispatch_dict[clearing_num]))
        
        for gen in gens
            if !haskey(gen_revenues, gen)
                gen_revenues[gen] = 0.0
                gen_energy[gen] = 0.0
            end
            
            # Sum over executed hours (1 to reclear_freq)
            for h in 1:reclear_freq
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
            end

            gen_revenues[gen] += fin_rev
            traded_net[gen] += net_trade
            traded_gross[gen] += gross_trade
        end
    end

    total_revenue = sum(values(gen_revenues))

    return Dict(
        :generator_revenues => gen_revenues,
        :traded_net => traded_net,
        :traded_gross => traded_gross,
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
    
    # Get reclear frequency to determine how many hours executed per clearing
    reclear_freq = Int(cfg["rolling_horizon"]["reclear_frequency"])
    
    # For each clearing, use hours 1 through reclear_freq as the executed operations
    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        prices = prices_dict[clearing_num]
        
        # Sum over all executed hours (1 to reclear_freq)
        for h in 1:reclear_freq
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
    
    # Get reclear frequency to determine how many hours are executed per clearing
    reclear_freq = Int(cfg["rolling_horizon"]["reclear_frequency"])

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

        # Capture executed position and delivery price for ALL executed hours (1 to reclear_freq)
        g_planned = details_dict[c_num][:g_planned]
        for h in 1:reclear_freq
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
    println("-"^80)
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
    
    costs = calculate_system_costs(all_results, cfg)
    revenues_exec = calculate_generator_revenues_executed(all_results, cfg)
    revenues_full = calculate_generator_revenues_full(all_results)
    storage = calculate_storage_revenue(all_results, cfg)
    welfare = calculate_social_welfare(all_results, cfg)
    
    # Normalize generator costs to daily average
    daily_gen_costs = Dict{String, Float64}()
    for (gen, cost) in costs[:generator_costs]
        daily_gen_costs[gen] = cost / sim_days
    end
    
    # Normalize generator revenues (executed)
    daily_gen_revenues_exec = Dict{String, Float64}()
    daily_gen_energy_exec = Dict{String, Float64}()
    for (gen, revenue) in revenues_exec[:generator_revenues]
        daily_gen_revenues_exec[gen] = revenue / sim_days
        daily_gen_energy_exec[gen] = revenues_exec[:generator_energy][gen] / sim_days
    end
    
    # Normalize generator revenues (full financial)
    daily_gen_revenues_full = Dict{String, Float64}()
    daily_traded_net = Dict{String, Float64}()
    daily_traded_gross = Dict{String, Float64}()
    for (gen, revenue) in revenues_full[:generator_revenues]
        daily_gen_revenues_full[gen] = revenue / sim_days
        daily_traded_net[gen] = revenues_full[:traded_net][gen] / sim_days
        daily_traded_gross[gen] = revenues_full[:traded_gross][gen] / sim_days
    end
    
    # Normalize storage metrics
    daily_storage = Dict(
        :discharge_revenue => storage[:discharge_revenue] / sim_days,
        :charging_cost => storage[:charging_cost] / sim_days,
        :net_revenue => storage[:net_revenue] / sim_days,
        :discharge_energy => storage[:total_discharge_energy] / sim_days,
        :charging_energy => storage[:total_charging_energy] / sim_days,
        :avg_discharge_price => storage[:avg_discharge_price],  # Price averages don't change
        :avg_charging_price => storage[:avg_charging_price]      # Price averages don't change
    )
    
    # Normalize welfare metrics
    daily_welfare = Dict(
        :social_welfare => welfare[:social_welfare] / sim_days,
        :demand_value => welfare[:total_demand_value] / sim_days,
        :generation_cost => welfare[:total_generation_cost] / sim_days
    )
    
    return Dict(
        :sim_days => sim_days,
        :daily_total_cost => costs[:total_cost] / sim_days,
        :daily_gen_costs => daily_gen_costs,
        :daily_gen_revenues_exec => daily_gen_revenues_exec,
        :daily_gen_energy_exec => daily_gen_energy_exec,
        :daily_total_revenue_exec => revenues_exec[:total_revenue] / sim_days,
        :daily_gen_revenues_full => daily_gen_revenues_full,
        :daily_traded_net => daily_traded_net,
        :daily_traded_gross => daily_traded_gross,
        :daily_total_revenue_full => revenues_full[:total_revenue] / sim_days,
        :daily_storage => daily_storage,
        :daily_welfare => daily_welfare
    )
end


function export_full_summary_to_excel(all_results::Dict, cfg::Dict; path::String="economic_summary.xlsx")
    costs = calculate_system_costs(all_results, cfg)
    revenues_exec = calculate_generator_revenues_executed(all_results, cfg)
    revenues_full = calculate_generator_revenues_full(all_results)
    storage = calculate_storage_revenue(all_results, cfg)
    welfare = calculate_social_welfare(all_results, cfg)
    daily_metrics = calculate_average_daily_metrics(all_results, cfg)
    
    sim_days = daily_metrics[:sim_days]

    # Helpers
    col_label(n::Int) = begin
        s = ""; x = n
        while x > 0
            x -= 1; s = string(Char('A' + (x % 26))) * s; x ÷= 26
        end
        s
    end
    write_row!(sh, r::Int, values::Vector{Any}) = (for (j,v) in enumerate(values); sh["$(col_label(j))$(r)"] = v; end)
    write_text!(sh, r::Int, text::String) = (sh["A$(r)"] = text)

    XLSX.openxlsx(path, mode="w") do xf
        sh = XLSX.addsheet!(xf, "Summary")
        row = 1

        # Title
        write_text!(sh, row, "ECONOMIC SUMMARY ($(sim_days) days simulation)"); row += 2

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

        # SOCIAL WELFARE
        write_text!(sh, row, "SOCIAL WELFARE"); row += 1
        write_row!(sh, row, Any["Metric", "Total (EUR)", "Per Day (EUR)"]); row += 1
        write_row!(sh, row, Any["Total Demand Value", welfare[:total_demand_value], daily_metrics[:daily_welfare][:demand_value]]); row += 1
        write_row!(sh, row, Any["Total Generation Cost", welfare[:total_generation_cost], daily_metrics[:daily_welfare][:generation_cost]]); row += 1
        write_row!(sh, row, Any["Social Welfare", welfare[:social_welfare], daily_metrics[:daily_welfare][:social_welfare]]); row += 2

        # GENERATOR PROFITS (Full Revenue - Cost)
        write_text!(sh, row, "GENERATOR PROFITS (Full Revenue - Cost)"); row += 1
        write_row!(sh, row, Any["Generator", "Total Profit (EUR)", "Profit/Day (EUR)"]); row += 1
        total_profit = 0.0
        total_daily_profit = 0.0
        for gen in sort(collect(keys(revenues_full[:generator_revenues])))
            revenue = revenues_full[:generator_revenues][gen]
            cost = haskey(costs[:generator_costs], gen) ? costs[:generator_costs][gen] : 0.0
            profit = revenue - cost
            daily_profit = profit / sim_days
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
        write_row!(sh, row, Any["Average per Clearing (EUR)", storage[:net_revenue] / storage[:total_clearings], ""]); row += 2

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
    daily_metrics = calculate_average_daily_metrics(all_results, cfg)
    
    sim_days = daily_metrics[:sim_days]

    println()
    println("="^80)
    println("ECONOMIC SUMMARY ($(sim_days) days simulation)")
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
    @printf "%-20s %12s %12s %12s %12s\n" "Generator" "Net Revenue" "Net Traded" "Gross Traded" "Rev/Day"
    println("-"^80)
    for (gen, revenue) in sort(collect(revenues_full[:generator_revenues]))
        net_trade = revenues_full[:traded_net][gen]
        gross_trade = revenues_full[:traded_gross][gen]
        daily_rev = daily_metrics[:daily_gen_revenues_full][gen]
        @printf "%-20s %12.2f %12.2f %12.2f %12.2f\n" gen revenue net_trade gross_trade daily_rev
    end
    println("-"^80)
    @printf "%-20s %12.2f %12s %12s %12.2f\n" "Total Net Revenue" revenues_full[:total_revenue] "" "" daily_metrics[:daily_total_revenue_full]

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
    @printf "%-20s %16.2f %16.2f\n" "Average per Clearing" (costs[:total_cost] / costs[:total_clearings]) (daily_metrics[:daily_total_cost] / (costs[:total_clearings] / sim_days))

    println()
    println("SOCIAL WELFARE")
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Total Demand Value" welfare[:total_demand_value] daily_metrics[:daily_welfare][:demand_value]
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Total Generation Cost" welfare[:total_generation_cost] daily_metrics[:daily_welfare][:generation_cost]
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Social Welfare" welfare[:social_welfare] daily_metrics[:daily_welfare][:social_welfare]
    
    println()
    println("GENERATOR PROFITS (Full Revenue - Cost)")
    println("-"^80)
    @printf "%-20s %16s %16s\n" "Generator" "Total Profit (EUR)" "Profit/Day (EUR)"
    println("-"^80)
    total_profit = 0.0
    total_daily_profit = 0.0
    for gen in sort(collect(keys(revenues_full[:generator_revenues])))
        revenue = revenues_full[:generator_revenues][gen]
        cost = haskey(costs[:generator_costs], gen) ? costs[:generator_costs][gen] : 0.0
        profit = revenue - cost
        daily_profit = profit / sim_days
        total_profit += profit
        total_daily_profit += daily_profit
        @printf "%-20s %16.2f %16.2f\n" gen profit daily_profit
    end
    println("-"^80)
    @printf "%-20s %16.2f %16.2f\n" "Total Generator Profit" total_profit total_daily_profit
    
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
        daily_profit = profit / sim_days
        total_profit_summary += profit
        @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "$(gen) Profit" profit daily_profit
    end
    println("-"^80)
    @printf "%-30s: %12.2f EUR   (%.2f EUR/day)\n" "Total Generator Profit" total_profit_summary (total_profit_summary / sim_days)

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

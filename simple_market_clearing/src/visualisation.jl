# VISUALISATION

using Plots, Statistics, Printf, XLSX

function plot_rolling_horizon_results(all_results::Dict)
    # Plot 1: Price forecasts from clearings 1-4
    clearing_details = all_results[:clearing_details]
    
    p1 = plot(xlabel="Global Hour", ylabel="Price (EUR/MWh)",
              title="Price Forecasts - Clearings 1-4",
              legend=:topright, linewidth=2.5, size=(800, 400))
    
    for clearing_num in 1:4
        if haskey(clearing_details, clearing_num)
            details = clearing_details[clearing_num]
            start_global_hour = details[:current_hour]
            prices = details[:prices]
            
            # Global hours for this clearing
            local_hours = 1:length(prices)
            global_hours = start_global_hour .+ (local_hours .- 1)
            
            # Plot this clearing's price forecast
            plot!(p1, global_hours, prices, label="Clearing $clearing_num", linewidth=2.5)
        end
    end
    
    # Plot dispatch and demand from clearings 2, 3, 4 (3 stacked area subplots)
    dispatch_dict = all_results[:dispatch]
    clearing_details = all_results[:clearing_details]
    p2 = nothing
    
    if haskey(dispatch_dict, 2) && haskey(dispatch_dict, 3) && haskey(dispatch_dict, 4)
        # Create 3 subplots for clearings 2, 3, 4
        subplots = []
        clearing_nums = [2, 3, 4]
        
        for (idx, clearing_num) in enumerate(clearing_nums)
            if !haskey(dispatch_dict, clearing_num) || !haskey(clearing_details, clearing_num)
                continue
            end
            
            clearing_data = dispatch_dict[clearing_num]
            details = clearing_details[clearing_num]
            start_global_hour = details[:current_hour]
            
            # Get all 24 hours of local indices
            local_hours = 1:24
            
            # Extract dispatch for Base, Wind, Peak (in that order for stacking)
            base_gen = get(clearing_data, "Base", zeros(24))[local_hours]
            wind_gen = get(clearing_data, "Wind", zeros(24))[local_hours]
            peak_gen = get(clearing_data, "Peak", zeros(24))[local_hours]
            
            # Extract battery discharge
            discharging = details[:discharging][local_hours]
            
            # Extract demand components
            demand_base = details[:demand_base][local_hours]
            demand_flex = details[:demand_flex][local_hours]
            charging = details[:charging][local_hours]
            
            # Total demand line = base + flex + charging
            total_demand = demand_base .+ demand_flex .+ charging
            
            # Compute cumulative sums for stacking (supply side: Base, Wind, Peak, Discharge)
            base_cum = base_gen
            wind_cum = base_cum .+ wind_gen
            peak_cum = wind_cum .+ peak_gen
            discharge_cum = peak_cum .+ discharging
            
            # Create stacked area plot
            p_sub = plot(title="Clearing $clearing_num (Global Hours $(start_global_hour)-$(start_global_hour+23))",
                        xlabel="Local Hour", ylabel="MW",
                        legend=:topright, size=(480, 350))
            
            # Plot stacked areas (bottom to top: Base, Wind, Peak, Discharge)
            plot!(p_sub, local_hours, base_cum, fill=(0, 0.6, :blue), label="Base", linewidth=0)
            plot!(p_sub, local_hours, wind_cum, fill=(base_cum, 0.6, :green), label="Wind", linewidth=0)
            plot!(p_sub, local_hours, peak_cum, fill=(wind_cum, 0.6, :orange), label="Peak", linewidth=0)
            plot!(p_sub, local_hours, discharge_cum, fill=(peak_cum, 0.6, :yellow), label="Discharge", linewidth=0)
            
            # Add demand line on top
            plot!(p_sub, local_hours, total_demand,
                  label="Demand+Charging", linewidth=2.5, linestyle=:dash, color=:black)
            
            push!(subplots, p_sub)
        end
        
        if length(subplots) == 3
            p2 = plot(subplots[1], subplots[2], subplots[3], layout=(1,3), size=(1400, 400))
        end
    end
    
    # Create new p3: Wind generation evolution across feasible clearings
    # Each clearing line shows its 24-hour wind forecast from its perspective
    p3 = plot(xlabel="Global Hour (Simulation)", ylabel="Wind Generation (MW)",
              title="Wind Generation Forecasts - Rolling Horizon Evolution (Feasible Clearings Only)",
              legend=:topright, linewidth=2)
    
    # Get feasible clearing numbers in order
    feasible_clearings = sort(collect(keys(dispatch_dict)))
    num_feasible = length(feasible_clearings)
    colors = palette(:tab20, num_feasible)
    
    # Create a mapping of clearing_count to clearing_times
    # clearing_times is stored sequentially for each optimal clearing
    clearing_to_hour = Dict{Int, Int}()
    time_idx = 1
    for c_num in 1:length(all_results[:clearing_times]) + length(all_results[:infeasible_clearings])
        if !(c_num in all_results[:infeasible_clearings])
            clearing_to_hour[c_num] = all_results[:clearing_times][time_idx]
            time_idx += 1
        end
    end
    
    # Plot each feasible clearing's wind forecast
    for (color_idx, clearing_num) in enumerate(feasible_clearings)
        clearing_data = dispatch_dict[clearing_num]
        if haskey(clearing_data, "Wind")
            wind_gen = clearing_data["Wind"]
            
            # Get the starting hour for this clearing
            clearing_hour = clearing_to_hour[clearing_num]
            
            # X-axis: global hours from clearing_hour to clearing_hour + look_ahead - 1
            global_hours = clearing_hour:(clearing_hour + length(wind_gen) - 1)
            
            # Plot this clearing's wind forecast
            plot!(p3, global_hours, wind_gen,
                  label="Clearing $clearing_num", color=colors[color_idx], alpha=0.8)
        end
    end
    
    # Combine plots
    if !isnothing(p2)
        plot(p1, p2, p3, layout=(3,1), size=(1000, 900))
    else
        plot(p1, p3, layout=(2,1), size=(1000, 600))
    end
end

function show_clearing_analysis(all_results::Dict, total_clearings::Int, IG::Vector)
    if total_clearings < 2
        println("Not enough clearings to analyze.")
        return
    end
    
    # Select clearings to display: first, middle, last
    selected_clearings = Int[]
    push!(selected_clearings, 1)  # First clearing
    if total_clearings > 2
        push!(selected_clearings, div(total_clearings, 2))  # Middle clearing
    end
    push!(selected_clearings, total_clearings)  # Last clearing
    
    println()
    println("="^80)
    println("DETAILED CLEARING ANALYSIS - Adjustment Market Behavior")
    println("="^80)
    
    for clearing_idx in selected_clearings
        details = all_results[:clearing_details][clearing_idx]
        current_hour = details[:current_hour]
        Q_prev = details[:Q_prev]
        q_val = details[:q]
        g_planned = details[:g_planned]
        prices = details[:prices]
        
        println()
        println("Clearing #$clearing_idx (Global Hour: $current_hour)")
        println("-"^80)
        println()
        
        # Print table header
        println("Hour      q_prev(MW)  λ(€/MWh)    q(MW)   g_plan(MW)    Δ%")
        println("-"^80)
        
        for h in 1:min(24, length(prices))  # Show first 24 hours or less
            for g in IG
                q_prev_val = Q_prev[(g, h)]
                q_adj = q_val[g, h]
                g_plan = g_planned[g, h]
                price = prices[h]
                
                # Calculate adjustment percentage
                δ_pct = if q_prev_val > 0.001
                    (q_adj / q_prev_val) * 100
                else
                    0.0
                end
                
                hour_label = string(g, ":h", h)
                @printf "%8s %12.2f %10.2f %10.2f %10.2f %11.1f%%\n" hour_label q_prev_val price q_adj g_plan δ_pct
            end
        end
        
        println()
    end
    
    println("="^80)
end

function export_clearing_analysis_to_excel(all_results::Dict, total_clearings::Int, IG::Vector, filename::String="clearing_analysis.xlsx")
    if total_clearings < 1
        println("No clearings to export.")
        return
    end
    
    # Select clearings to display: first, middle, last
    selected_clearings = Int[]
    push!(selected_clearings, 1)  # First clearing
    if total_clearings > 2
        push!(selected_clearings, div(total_clearings, 2))  # Middle clearing
    end
    push!(selected_clearings, total_clearings)  # Last clearing
    
    # Create workbook
    XLSX.openxlsx(filename, mode="w") do xf
        
        # Summary sheet
        sheet_summary = xf[1]
        XLSX.rename!(sheet_summary, "Summary")
        sheet_summary["A1"] = "Clearing Analysis Summary"
        sheet_summary["A2"] = "Total Clearings"
        sheet_summary["B2"] = total_clearings
        sheet_summary["A3"] = "Infeasible Clearings"
        sheet_summary["B3"] = length(all_results[:infeasible_clearings])
        if !isempty(all_results[:infeasible_clearings])
            sheet_summary["C3"] = join(all_results[:infeasible_clearings], ", ")
        end
        
        sheet_summary["A5"] = "Generator List"
        for (idx, g) in enumerate(IG)
            sheet_summary["A$(5 + idx)"] = String(g)
        end
        
        # Create sheets for each selected clearing
        for (sheet_idx, clearing_idx) in enumerate(selected_clearings)
            if !haskey(all_results[:clearing_details], clearing_idx)
                continue
            end
            
            details = all_results[:clearing_details][clearing_idx]
            current_hour = details[:current_hour]
            Q_prev = details[:Q_prev]
            q_val = details[:q]
            g_planned = details[:g_planned]
            prices = details[:prices]
            
            # Create new sheet
            if sheet_idx == 1
                sheet = xf[1]
                XLSX.rename!(sheet, "Clearing_$clearing_idx")
            else
                sheet = XLSX.addsheet!(xf, "Clearing_$clearing_idx")
            end
            
            # Header
            sheet["A1"] = "Clearing #$clearing_idx (Global Hour: $current_hour)"
            
            # Column headers
            sheet["A3"] = "Hour"
            sheet["B3"] = "Generator"
            sheet["C3"] = "q_prev (MW)"
            sheet["D3"] = "λ (€/MWh)"
            sheet["E3"] = "q (MW)"
            sheet["F3"] = "g_plan (MW)"
            sheet["G3"] = "Δ (%)"
            
            # Data rows
            row = 4
            for h in 1:min(24, length(prices))
                for g in IG
                    q_prev_val = Q_prev[(String(g), h)]
                    q_adj = q_val[g, h]
                    g_plan = g_planned[g, h]
                    price = prices[h]
                    
                    δ_pct = if q_prev_val > 0.001
                        (q_adj / q_prev_val) * 100
                    else
                        0.0
                    end
                    
                    sheet["A$row"] = h
                    sheet["B$row"] = String(g)
                    sheet["C$row"] = round(q_prev_val; digits=2)
                    sheet["D$row"] = round(price; digits=2)
                    sheet["E$row"] = round(q_adj; digits=2)
                    sheet["F$row"] = round(g_plan; digits=2)
                    sheet["G$row"] = round(δ_pct; digits=1)
                    
                    row += 1
                end
            end
        end
    end
    
    println("✓ Analysis exported to: $filename")
end
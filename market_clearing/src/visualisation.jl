# VISUALISATION

using Plots, Statistics, Printf, XLSX

function plot_rolling_horizon_results(all_results::Dict)
    # Global parameters for all visualizations
    start_clearing = 3  # Can be changed from 1 to 160
    num_clearings_to_show = 5
    
    clearing_details = all_results[:clearing_details]
    dispatch_dict = all_results[:dispatch]
    
    # Calculate global hour range for consistent x-axis across all plots
    clearing_indices = start_clearing:(start_clearing + num_clearings_to_show - 1)
    start_global_hour = clearing_details[start_clearing][:current_hour]
    last_clearing_start = clearing_details[clearing_indices[end]][:current_hour]
    end_global_hour = last_clearing_start + 23
    
    # Plot 1: Price forecasts for the selected clearings
    p1 = plot(xlabel="Global Hour", ylabel="Price (EUR/MWh)",
              title="Price Forecasts - Clearings $start_clearing-$(start_clearing+num_clearings_to_show-1)",
              legend=:topright, linewidth=2.5, size=(1000, 400))
    
    # Define line styles and markers to distinguish overlapping lines
    line_styles = [:solid, :dash, :dot, :dashdot, :dashdotdot]
    markers = [:circle, :square, :diamond, :utriangle, :dtriangle]
    
    for (idx, clearing_num) in enumerate(clearing_indices)
        if haskey(clearing_details, clearing_num)
            details = clearing_details[clearing_num]
            clearing_start_hour = details[:current_hour]
            prices = details[:prices]
            
            # Global hours for this clearing
            local_hours = 1:length(prices)
            global_hours = clearing_start_hour .+ (local_hours .- 1)
            
            # Plot this clearing's price forecast with unique style
            plot!(p1, global_hours, prices, 
                  label="Clearing $clearing_num", 
                  linewidth=2.5,
                  linestyle=line_styles[idx],
                  marker=markers[idx],
                  markersize=4,
                  markerstrokewidth=0,
                  alpha=0.85)
        end
    end
    
    # Set consistent x-axis limits for price plot
    xlims!(p1, start_global_hour - 0.5, end_global_hour + 0.5)
    
    # Plot generator position evolution across consecutive clearings
    # Shows how g_planned and q change for each generator
    generators = ["Mid", "Wind"]
    
    # Create subplots - one for each generator
    subplots = []
    
    for gen_name in generators
        # Create subplot for this generator
        p_gen = plot(title="$gen_name", xlabel="Global Hour", ylabel="Clearing",
                    legend=false, size=(1000, 400),
                    yticks=(0:num_clearings_to_show, ["q_prev", "C$start_clearing", "C$(start_clearing+1)", 
                                                       "C$(start_clearing+2)", "C$(start_clearing+3)", "C$(start_clearing+4)"]),
                    yflip=true, tickfontsize=7, guidefontsize=9, titlefontsize=11)
        
        # First row: q_prev (previous position before the starting clearing)
        if haskey(clearing_details, start_clearing)
            Q_prev_dict = clearing_details[start_clearing][:Q_prev]
            clearing_start_hour = clearing_details[start_clearing][:current_hour]
            
            # Plot q_prev as bars using global hours
            for local_h in 1:24
                global_h = clearing_start_hour + local_h - 1
                value = Q_prev_dict[(gen_name, local_h)]
                
                if value > 0.01
                    bar_color = :orange
                    plot!(p_gen, [global_h-0.4, global_h+0.4], [0, 0], fillrange=[0.4, 0.4], 
                          fillcolor=bar_color, fillalpha=0.6, linewidth=0)
                    # Add text annotation with value
                    if value >= 10  # Only show significant values
                        annotate!(p_gen, global_h, 0, text(@sprintf("%.0f", value), 6, :black))
                    end
                end
            end
        end
        
        # Next rows: q adjustments for each clearing
        for (row_idx, clearing_num) in enumerate(clearing_indices)
            if haskey(clearing_details, clearing_num)
                q_dict = clearing_details[clearing_num][:q]
                clearing_start_hour = clearing_details[clearing_num][:current_hour]
                
                # Plot q adjustments as bars using global hours
                for local_h in 1:24
                    global_h = clearing_start_hour + local_h - 1
                    value = q_dict[gen_name, local_h]
                    
                    if abs(value) > 0.01  # Show non-zero adjustments
                        bar_color = value > 0 ? :lightgreen : :lightcoral
                        plot!(p_gen, [global_h-0.4, global_h+0.4], [row_idx, row_idx], 
                              fillrange=[row_idx+0.4, row_idx+0.4], 
                              fillcolor=bar_color, fillalpha=0.7, linewidth=0)
                        # Add text annotation with value (show +/-)
                        sign_str = value > 0 ? "+" : ""
                        annotate!(p_gen, global_h, row_idx, text(@sprintf("%s%.0f", sign_str, value), 6, :black))
                    end
                end
            end
        end
        
        # Set consistent x-axis limits across all generator plots
        xlims!(p_gen, start_global_hour - 0.5, end_global_hour + 0.5)
        ylims!(p_gen, -0.5, num_clearings_to_show + 0.5)
        
        push!(subplots, p_gen)
    end
    
    # Combine all plots with equal height
    if length(subplots) == 2
        plot(p1, subplots[1], subplots[2], layout=(3,1), size=(1000, 1200))
    elseif length(subplots) == 1
        plot(p1, subplots[1], layout=(2,1), size=(1000, 800))
    else
        plot(p1, layout=(1,1), size=(1000, 400))
    end
end
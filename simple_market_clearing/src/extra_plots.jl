    # Create new p3: Wind generation evolution across feasible clearings
    # Each clearing line shows its 24-hour wind forecast from its perspective
    p3 = plot(xlabel="Global Hour (Simulation)", ylabel="Wind Generation (MW)",
              title="Wind Generation Forecasts - Rolling Horizon Evolution",
              legend=:topright, linewidth=2,
              legendfontsize=7, tickfontsize=8, guidefontsize=9, titlefontsize=11)
    
    # Get feasible clearing numbers in order
    feasible_clearings = sort(collect(keys(dispatch_dict)))
    num_feasible = length(feasible_clearings)
    colors = palette(:tab20, num_feasible)
    
    # Create a mapping of clearing_count to clearing_times
    # clearing_times is stored sequentially for each optimal clearing
    clearing_to_hour = Dict{Int, Int}()
    for (c_num, clearing_time) in enumerate(all_results[:clearing_times])
        clearing_to_hour[c_num] = clearing_time
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
            
            # Create label: only show up to clearing 5, then "..."
            if clearing_num <= 5
                label_text = "Clearing $clearing_num"
            elseif clearing_num == 6
                label_text = "..."
            else
                label_text = nothing  # Don't show in legend
            end
            
            # Plot this clearing's wind forecast
            plot!(p3, global_hours, wind_gen,
                  label=label_text, color=colors[color_idx], alpha=0.8)
        end
    end
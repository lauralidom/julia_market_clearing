# PLOT WIND FORECASTS FROM ROLLING HORIZON SIMULATION
# Run this after market_clearing_rolling.jl to visualize wind predictions

using Plots

# Check if all_results exists in workspace
if !@isdefined(all_results)
    error("all_results not found. Please run market_clearing_rolling.jl first.")
end

# Extract dispatch data
dispatch_dict = all_results[:dispatch]
clearing_times = all_results[:clearing_times]

# Create plot
p = plot(xlabel="Global Hour", ylabel="Wind Generation (MW)",
         title="Wind Forecasts - First 24 Hours",
         legend=:outertopright, linewidth=2,
         size=(800, 500))

# Get clearings that start from hour 1 onwards (first 24 clearings)
max_clearings = min(24, length(clearing_times))
colors = palette(:tab10, max_clearings)

# Plot wind forecast for each clearing
for clearing_num in 1:max_clearings
    if haskey(dispatch_dict, clearing_num)
        clearing_data = dispatch_dict[clearing_num]
        
        if haskey(clearing_data, "Wind")
            wind_gen = clearing_data["Wind"]
            
            # Get the starting hour for this clearing
            start_hour = clearing_times[clearing_num]
            
            # X-axis: global hours from start_hour to start_hour + look_ahead - 1
            global_hours = start_hour:(start_hour + length(wind_gen) - 1)
            
            # Show first 5 clearings in legend, then occasional ones
            if clearing_num <= 5 || clearing_num % 5 == 0
                label_text = "C$clearing_num (h$start_hour)"
            else
                label_text = nothing
            end
            
            plot!(p, global_hours, wind_gen,
                  label=label_text, 
                  color=colors[mod1(clearing_num, 10)],
                  alpha=0.7)
        end
    end
end

display(p)
println("Wind forecast plot created for clearings 1-$max_clearings")

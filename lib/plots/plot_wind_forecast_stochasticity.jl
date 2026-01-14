module PlotWindForecastStochasticity

using Plots
using JuMP
using Statistics

include("../output_data/process_data.jl")

function plot(resultset)
	plot_solar = true
	# below copied from Laura and modified - TA

    # Create new p3: Wind generation evolution across clearings
    # Each clearing line shows its 24-hour wind forecast from its perspective
    p3 = Plots.plot(xlabel="Global Hour (Simulation)", ylabel="Wind Generation (MW)",
              title="Wind Generation Forecasts - Rolling Horizon Evolution",
              linewidth=2,size=(1200,1200), legend=:none)
    
    

    hours = ProcessData.Hours(resultset)
	bid_sets = ProcessData.GeneratorQuantityBidSets(resultset, "Wind")
	if plot_solar
		solar_bids = ProcessData.GeneratorQuantityBidSets(resultset, "Solar")
	end


    colors = Plots.palette(:tab20, length(hours))
    
    # Plot each clearing's wind forecast
    for (start_hour, bid_quantities) in bid_sets
        
        # X-axis:
        global_hours = start_hour:(start_hour + length(bid_quantities) - 1)
        
        # Plot this clearing's wind forecast
        Plots.plot!(p3, global_hours, bid_quantities,
            label="Clearing $start_hour", color=colors[start_hour], alpha=0.8)
        
    end

    if plot_solar
	    # Plot each clearing's solar forecast
	    for (start_hour, bid_quantities) in solar_bids
	        
	        # X-axis:
	        global_hours = start_hour:(start_hour + length(bid_quantities) - 1)
	        
	        # Plot this clearing's wind forecast
	        Plots.plot!(p3, global_hours, bid_quantities,
	            label="Clearing $start_hour (solar)", color=colors[start_hour], alpha=0.8)
	    end 
    end
    display(p3)
end

end;
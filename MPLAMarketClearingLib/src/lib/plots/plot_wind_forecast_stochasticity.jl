module PlotWindForecastStochasticity

using Plots
using JuMP
using Statistics

include("../output_data/process_data.jl")

function plot(resultset, name, test_id)
	plot_solar = true
	# below copied from Laura and modified - TA

    # Wind generation evolution across clearings
    # Each clearing line shows the wind forecast from its perspective
    p3 = Plots.plot(xlabel="Global Time Period (Simulation)", ylabel="Wind Generation (MW)",
              title="Wind Generation Forecasts - Rolling Horizon Evolution",
              linewidth=2,size=(1200,1200), legend=:none)
    
    

    time_periods = ProcessData.TimePeriods(resultset)
	bid_sets = ProcessData.GeneratorQuantityBidSets(resultset, "Wind")
	if plot_solar
		solar_bids = ProcessData.GeneratorQuantityBidSets(resultset, "Solar")
	end

	noise_clearing_ratio = 4 # only plot every so often to clear some noise

    colors = Plots.palette(:tab20, length(time_periods))
    
    # Plot each clearing's wind forecast
    for (start_time_period, bid_quantities) in bid_sets
        start_time_period % noise_clearing_ratio !== 0 && continue
        # X-axis:
        global_time_periods = start_time_period:(start_time_period + length(bid_quantities) - 1)
        # Plot this clearing's wind forecast
        Plots.plot!(p3, global_time_periods, bid_quantities,
            label="Clearing $start_time_period", color=colors[start_time_period % length(time_periods) + 1], alpha=0.8)
        
    end

    if plot_solar
	    # Plot each clearing's solar forecast
	    for (start_time_period, bid_quantities) in solar_bids
	        start_time_period % noise_clearing_ratio !== 0 && continue
	        # X-axis:
	        global_time_periods = start_time_period:(start_time_period + length(bid_quantities) - 1)
	        
	        # Plot this clearing's wind forecast
	        Plots.plot!(p3, global_time_periods, bid_quantities,
	            label="Clearing $start_time_period (solar)", color=colors[start_time_period % length(time_periods) + 1], alpha=0.8)
	    end 
    end
    display(p3)
    savefig(p3, "../DATA/$(test_id)/wind_forecast_$(name).png")
    return p3
end

end;
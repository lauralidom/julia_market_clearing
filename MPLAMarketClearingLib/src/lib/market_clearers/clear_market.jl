module ClearMarket

using JuMP

include("../models/basic_model.jl")
include("../models/rolling_model.jl")
include("../models/rolling_model_with_ramp_rates.jl")

include("../plots/plot_hourly_market_equilibrium.jl") # TODO: rename
include("../plots/plot_market_prices_with_storage.jl")
include("../plots/plot_state_of_charge.jl")
include("../plots/plot_generation_stack.jl")

# rolling plots
include("../plots/plot_price_evolution.jl")
include("../plots/plot_generation_stack_rolling.jl")
include("../plots/plot_dispatch_changes_for_hour.jl") # TODO: rename
include("../plots/plot_state_of_charge_rolling.jl")
include("../plots/plot_peak_generation_and_storage_use.jl")
include("../plots/plot_wind_forecast_stochasticity.jl")
include("../plots/plot_baseline_outcomes.jl")
include("../plots/plot_transaction_volumes.jl")
include("../plots/plot_adjustment_dispatch_clearing_volume.jl")


include("../helpers/helper_model_results.jl")

include("../output_data/process_data.jl")


function ClearBasic(data)
	m = BasicModel.build(data)
	optimize!(m)
    println("Termination status: ", termination_status(m))
    println("Objective value: ", objective_value(m))
    
    # next up, plot some things
    # these display themselves, should they??
    
    for iter in m.ext[:sets][:JH]
        PlotHourlyMarketEquilibrium.plot(m,iter) # TODO: rename
    end
    
    PlotMarketPricesWithStorage.plot(m)
    PlotStateOfCharge.plot(m)
    PlotGenerationStack.plot(m)
end

function ClearRolling(data, with_ramps)

	time_period_range = range(1,data[:clearForDays]*data[:timePeriodsPerDay] - data[:clearingWindow]) # go from time_period 1 to the last window for which we have a full data set
    previous_time_period_data = Dict(
    	:SOC => data[:batteryStorage]["initialSOC"]*data[:batteryStorage]["energyCapacity"],
    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in data[:dispatchableGenerators])
    )

    resultset = ProcessData.CreateResultSet()
    for t in time_period_range
		m = with_ramps ? RollingModelWithRampRates.build_for_time_period(data,t,previous_time_period_data) : RollingModel.build_for_time_period(data,t,previous_time_period_data) 
	    optimize!(m)
	    # println("Termination status: ", termination_status(m))
	    # println("Objective value: ", objective_value(m))

	    ProcessData.AddToResultSet!(resultset, m, t)

	    previous_time_period_data[:SOC] = HelperModelResults.SOCValues(m)[t+data[:clearingInterval]]
	    previous_time_period_data[:SOC] = HelperModelResults.SOCValues(m)[t+data[:clearingInterval]]
	    
	    # println("SOC: ", previous_time_period_data)



	    # next up, plot some things
	    # could this be configurable based on yaml input?
	    
	    
	    # these display themselves, should they??
	    
	    for iter in m.ext[:sets][:CH]
	        # PlotHourlyMarketEquilibrium.plot(m,iter)
	    end
	    
	    
	end

	# println(resultset)
	priceSets = ProcessData.GetPriceSets(resultset)

	PlotPriceEvolution.plot(priceSets)
	PlotGenerationStackRolling.plot(resultset)
	PlotDispatchChangesForHour.plot(resultset,"Wind",25) # TODO: rename hour
	PlotStateOfChargeRolling.plot(resultset)
	PlotPeakGenerationAndStorageUse.plot(resultset)
	PlotWindForecastStochasticity.plot(resultset)

	PlotBaselineOutcomes.plot(resultset)

	PlotTransactionVolumes.plot(resultset, 65)
	PlotAdjustmentDispatchClearingVolume.plot(resultset)
	#= TODO: fix these plots for the new rolling approach
	    PlotMarketPricesWithStorage.plot(m)
	    PlotStateOfCharge.plot(m)
	    PlotGenerationStack.plot(m)
	=#
end
	
function Clear(data)
	if data[:strategy] == "rolling"
		ClearRolling(data, false)
	elseif data[:strategy] == "rolling_with_ramps"
		ClearRolling(data, true)
	else
		ClearBasic(data)
	end
end


end;
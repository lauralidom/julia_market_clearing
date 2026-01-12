module ClearMarket

using JuMP

include("../models/basic_model.jl")
include("../models/rolling_model.jl")
include("../models/rolling_model_with_ramp_rates.jl")

include("../plots/plot_hourly_market_equilibrium.jl")
include("../plots/plot_market_prices_with_storage.jl")
include("../plots/plot_state_of_charge.jl")
include("../plots/plot_generation_stack.jl")

# rolling plots
include("../plots/plot_price_evolution.jl")
include("../plots/plot_generation_stack_rolling.jl")
include("../plots/plot_dispatch_changes_for_hour.jl")
include("../plots/plot_state_of_charge_rolling.jl")
include("../plots/plot_peak_generation_and_storage_use.jl")


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
        PlotHourlyMarketEquilibrium.plot(m,iter)
    end
    
    PlotMarketPricesWithStorage.plot(m)
    PlotStateOfCharge.plot(m)
    PlotGenerationStack.plot(m)
end

function ClearRolling(data, with_ramps)

	hour_range = range(1,data[:clearForDays]*24 - data[:clearingWindow]) # go from hour 1 to the last window for which we have a full data set
    previous_hour_data = Dict(
    	:SOC => data[:batteryStorage]["initialSOC"]*data[:batteryStorage]["energyCapacity"],
    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in data[:dispatchableGenerators])
    )

    resultset = ProcessData.CreateResultSet()
    for hour in hour_range
		m = with_ramps ? RollingModelWithRampRates.build_for_hour(data,hour,previous_hour_data) : RollingModel.build_for_hour(data,hour,previous_hour_data) 
	    optimize!(m)
	    # println("Termination status: ", termination_status(m))
	    # println("Objective value: ", objective_value(m))

	    ProcessData.AddToResultSet!(resultset, m, hour)

	    previous_hour_data[:SOC] = HelperModelResults.SOCValues(m)[hour+data[:clearingInterval]]
	    previous_hour_data[:SOC] = HelperModelResults.SOCValues(m)[hour+data[:clearingInterval]]
	    
	    println("SOC: ", previous_hour_data)



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
	PlotDispatchChangesForHour.plot(resultset,"Peak",32)
	PlotStateOfChargeRolling.plot(resultset)
	PlotPeakGenerationAndStorageUse.plot(resultset)

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
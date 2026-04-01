module ClearMarket

using JuMP

include("../data_importer.jl")

include("../models/basic_model.jl")
include("../models/rolling_model.jl")
include("../models/rolling_model_with_ramp_rates.jl")
include("../models/flexible_model.jl")

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


include("../plots/comparison/plot_comparison_baseline_outcomes.jl")
include("../plots/comparison/plot_comparison_imbalance.jl")
include("../plots/comparison/plot_comparison_table_for_mtu.jl")


include("../helpers/helper_model_results.jl")
include("../helpers/helper_input_data.jl")

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

# TODO: tests around these functions, they are important.


function marketMatch(t, market, timePeriodsPerDay)
	# determine if a market should operate in this moment based on time of day
	if ((t - market[:clockTimeBegin]) % market[:clearingInterval] == 0) # if the offset between this period and the time we begin is zero, or a multiple of the interval, this period should hold a market
		return true
	end
	return false
end

# use configuration (data) and the time period in question (1 to end of window in which to consider clearing) to determine if a market should be cleared in this time period, returning a set of any markets that match

function generateMarketSetForTimePeriod(t, data)
	markets = []

	if data[:marketGenerationStrategy] == "explicit"
		for market in data[:marketSequence]
			if marketMatch(t, market, data[:timePeriodsPerDay])
				push!(markets, market)
			end
		end
	elseif data[:marketGenerationStrategy] == "repeat"
		if t % data[:clearingInterval] == 0
			addMarket = Dict{Symbol,Any}()
            addMarket[:name] = data[:strategy]
            addMarket[:clearingInterval] = data[:clearingInterval] # number of time periods between market clearing/optimization rounds
            addMarket[:clearingWindow] = data[:clearingWindow] # number of time periods to consider in each round
            addMarket[:lookAheadDistance] = data[:lookAheadDistance] # window under consideration starts lookAheadDistance time periods ahead
			push!(markets,addMarket)
		end
	else
		throw("unrecognized marketGenerationStrategy: check config: $(data[:marketGenerationStrategy])")
	end

	return markets
end


function ClearWithFlexibleModel(data)
	# TODO: revisit clearing window idea
	time_period_range = range(1,data[:clearForDays]*data[:timePeriodsPerDay] - data[:clearingWindow]) # go from time_period 1 to the last window for which we have a full data set
    

    # generate the sequence of markets - one entry for each t, empty if no markets to be run at that time, otherwise, a list of markets to clear at that time
    marketSequence = []
    for t in time_period_range
    	push!(marketSequence,generateMarketSetForTimePeriod(t,data))
    end

	resultset = ProcessData.CreateResultSet()

	initialization = Dict(
    	:SOC => data[:batteryStorage]["initialSOC"]*data[:batteryStorage]["energyCapacity"],
    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in data[:dispatchableGenerators])
    )


    # for each market in marketSequences note the nesting here so a single time period could hold more than one market (but really probably won't in most cases) - case where it would - could be when holding a market 2 days ahead, for example
    # a function here that can be reused across strategies. It takes: resultset, initialization, configuration, and market parameters, using the same interior functionality so we're all apples to apples.

	for t in time_period_range
		marketsAtTime = marketSequence[t]
		for market in marketsAtTime
			m = FlexibleMarketModel.build(t, resultset, initialization, data, market)
			optimize!(m)
			ProcessData.AddToResultSet!(resultset, m, t, market[:name]) # maybe we should also give the market name to make results from ID/DA, etc explicitly distinguishable
		end
	end

	priceSets = ProcessData.GetPriceSets(resultset)

	PlotPriceEvolution.plot(priceSets)
	PlotGenerationStackRolling.plot(resultset)
	PlotDispatchChangesForHour.plot(resultset,"Wind",125) # TODO: rename hour
	PlotStateOfChargeRolling.plot(resultset)
	PlotPeakGenerationAndStorageUse.plot(resultset)
	PlotWindForecastStochasticity.plot(resultset)

	PlotBaselineOutcomes.plot(resultset)

	PlotTransactionVolumes.plot(resultset, resultset[1].ClearingTimePeriod, resultset[1].MarketName)
	PlotTransactionVolumes.plot(resultset, resultset[2].ClearingTimePeriod, resultset[2].MarketName)
	PlotTransactionVolumes.plot(resultset, resultset[3].ClearingTimePeriod, resultset[3].MarketName)
	PlotTransactionVolumes.plot(resultset, resultset[4].ClearingTimePeriod, resultset[4].MarketName)
	PlotTransactionVolumes.plot(resultset, resultset[5].ClearingTimePeriod, resultset[5].MarketName)
	PlotTransactionVolumes.plot(resultset, resultset[6].ClearingTimePeriod, resultset[6].MarketName)
	PlotTransactionVolumes.plot(resultset, resultset[7].ClearingTimePeriod, resultset[7].MarketName)
	# PlotAdjustmentDispatchClearingVolume.plot(resultset)
end
	
function Clear(data)
	if data[:strategy] == "rolling"
		ClearRolling(data, false)
	elseif data[:strategy] == "rolling_with_ramps"
		ClearWithFlexibleModel(data)
	elseif data[:strategy] == "fixed_horizon_status_quo"
		ClearWithFlexibleModel(data)
	else
		print("strategy not recognized, using basic clearing: ", data[:strategy])
		ClearBasic(data)
	end
end

function ClearTogether(configs, test_id)
	# TODO: revisit clearing window idea - there is an assumption here that they match
	first_config = configs[1]
	last_mtp = first_config[:clearForDays]*first_config[:timePeriodsPerDay] - first_config[:clearingWindow]
	time_period_range = range(1,last_mtp) # go from time_period 1 to the last mtp for which we have a full data set
    
	configMap = Dict{String,Any}()
    marketSequences = Dict{String,Any}()
    resultsets = Dict{String,Any}()
    initializations = Dict{String,Any}()
    for config in configs
    	configMap[config[:strategy]] = config
    	marketSequences[config[:strategy]] = []
    	resultsets[config[:strategy]] = resultset = ProcessData.CreateResultSet()
		initializations[config[:strategy]] = Dict(
		    	:SOC => config[:batteryStorage]["initialSOC"]*config[:batteryStorage]["energyCapacity"],
		    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators])
		    )
		# generate the sequence of markets - one entry for each t, empty if no markets to be run at that time, otherwise, a list of markets to clear at that time
	    for t in time_period_range
	    	push!(marketSequences[config[:strategy]] ,generateMarketSetForTimePeriod(t,config))
	    end
		
    end

	variableGeneratorProfiles = Dict{String,Vector{Float64}}()

    for (gName, gData) in first_config[:variableGenerators]
    	variableGeneratorProfiles[gName] = Vector{Float64}()
    	input_profile = gData["profile"]
    	for t in time_period_range
    		push!(variableGeneratorProfiles[gName], input_profile[(t%length(input_profile))+ 1])
    	end
    end


    # for each market in marketSequences note the nesting here so a single time period could hold more than one market (but really probably won't in most cases) - case where it would - could be when holding a market 2 days ahead, for example
    # a function here that can be reused across strategies. It takes: resultset, initialization, configuration, and market parameters, using the same interior functionality so we're all apples to apples.

	for t in time_period_range
		# println("clearing ", t)

		# TODO: here the same system input parameters should be used

		# TODO: a new approach to noise
		if t != last_mtp # skip for last time period
	        if haskey(first_config,:noiseLevel) && first_config[:noiseLevel] > 0
	            noise_std = float(first_config[:noiseLevel]) 
	            for (gName, profile) in variableGeneratorProfiles
		            noisy_profile = HelperInputData.add_noise_pre!(profile, noise_std, t, min(t+first_config[:clearingWindow], last_mtp))
		        	for config in configs
		        		configMap[config[:strategy]][:variableGenerators][gName]["profile"] = noisy_profile
		        	end
		        end
	        end
	    end

		for (name, marketSequence) in marketSequences
			marketsAtTime = marketSequence[t]
			for market in marketsAtTime
				m = FlexibleMarketModel.build(t, resultsets[name], initializations[name], configMap[name], market)
				optimize!(m)
				ProcessData.AddToResultSet!(resultsets[name], m, t, market[:name])
			end
		end
		# println("finish clearing ", t)
	end

	plots = [PlotBaselineOutcomes, PlotStateOfChargeRolling, PlotPeakGenerationAndStorageUse, PlotWindForecastStochasticity, PlotGenerationStackRolling]

	for plot in plots
		for (name, resultset) in resultsets
			plot.plot(resultset)
		end
	end

	PlotComparisonImbalance.plot(resultsets, configMap[first_config[:strategy]][:variableGenerators], range(first_config[:timePeriodsPerDay]*2,first_config[:timePeriodsPerDay]*(first_config[:clearForDays] - 1)), test_id)
	

	PlotComparisonBaselineOutcomes.plot(resultsets, configMap, range(first_config[:timePeriodsPerDay]*2,first_config[:timePeriodsPerDay]*(first_config[:clearForDays] - 1)), test_id)

	#TODO: table output for economic indicators for a single MTU
	# PlotComparisonTableForMTU.plot(resultsets, configMap[first_config[:strategy]][:variableGenerators], 235)
end

function ClearComparison(config_files, test_id)
	configs = []
	for config_file in config_files
		config = DataImporter.load_input_data(config_file)
		push!(configs, config)
	end

	ClearMarket.ClearTogether(configs, test_id)
end

end;
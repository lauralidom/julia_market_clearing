module ProcessData

using Dates, JuMP, MathOptInterface


include("../helpers/helper_model_results.jl")

# this struct holds the incoming data in a standard format

mutable struct ClearingData
	Timestamp::DateTime
	BaseTimePeriod::Int
	TerminationStatus::MathOptInterface.TerminationStatusCode
	ObjectiveValue::Number
	TimePeriods::Vector{Int}
	Prices::Vector{Number}
	GenData::Dict{String, Vector{Float64}}
	BidPrices::Dict{String, Vector{Float64}} # gens and demands
	DemandData::Dict{String, Vector{Float64}}
	StorageDischargeQuantities::Vector{Float64} # TODO: should rethink data format here for storage
	StorageChargeQuantities::Vector{Float64}
	StorageStateOfCharge::Vector{Float64}
	Transactions::Vector{HelperModelResults.Transaction}
	ClearingData() = new()
end


# this function is used to create a set of results. it is the responsibility of the caller to hold on to it and use it with add to result set

function CreateResultSet()
	return Vector{ClearingData}()
end

# this function adds results to the result set

function AddToResultSet!(resultset, model, time_period)
	cd = ClearingData()
	cd.Timestamp = Dates.now()
	cd.BaseTimePeriod = time_period

	cd.TerminationStatus = termination_status(model)
	cd.ObjectiveValue = objective_value(model)
	cd.TimePeriods = HelperModelResults.TimePeriods(model)
	cd.Prices = HelperModelResults.Prices(model)
	cd.BidPrices = HelperModelResults.BidPrices(model)
	cd.GenData = HelperModelResults.GenData(model)
	cd.DemandData = HelperModelResults.DemandData(model)
	cd.StorageDischargeQuantities = HelperModelResults.StorageDischargeQuantities(model)
	cd.StorageChargeQuantities = HelperModelResults.StorageChargeQuantities(model)
	cd.StorageStateOfCharge = HelperModelResults.SOCValues(model)


	cd.Transactions = HelperModelResults.Transactions(cd,resultset)

	push!(resultset, cd)
end


# todo: some helpers to get the data you're interested in out of the result set

function GetPriceSets(resultset)
	pricesets = []
	for result in resultset
		priceset = (result.BaseTimePeriod,result.Prices)
		push!(pricesets,priceset)
	end
	return pricesets
end


# bid quantities, used for plotting noise in wind/solar inputs
function GeneratorQuantityBidSets(resultset, generator)
	bidsets = []
	for result in resultset
		bidset = (result.BaseTimePeriod,result.GenData[generator])
		push!(bidsets,bidset)
	end
	return bidsets
end

# I am disliking how the storage here is just implying the time periods heuristically - would be better to be explicit

function TimePeriods(resultset)
	time_periods = []
	for result in resultset
		push!(time_periods,result.BaseTimePeriod)
	end
	return time_periods
end


function DispatchedTimePeriods(resultset)
	time_periods = TimePeriods(resultset)
	final_dispatch = resultset[length(resultset)].TimePeriods
	
	append!(time_periods, final_dispatch[2:length(final_dispatch)])

	return time_periods
end

function GenData(resultset)
	gen_data = Dict{String, Vector{Float64}}()
	for key in keys(resultset[1].GenData)
		gen_data[key] = Vector{Float64}()
	end
	for result in resultset
		for key in keys(result.GenData)
			push!(gen_data[key], result.GenData[key][1]) # only getting the gen data for this base time period - fully cleared final dispatch
		end
	end
	return gen_data
end


function BidPricesForTimePeriod(resultset, generator, time_period)
	bid_prices = Dict{Int,Float64}()
	for result in resultset
		time_period - result.BaseTimePeriod > 0 && time_period - result.BaseTimePeriod <= length(result.BidPrices[generator]) ? bid_prices[result.BaseTimePeriod] =  result.BidPrices[generator][time_period - result.BaseTimePeriod] : continue
	end
	return bid_prices
end


function GenDispatchDataForTimePeriod(resultset, generator, time_period) 
	gen_data = Dict{Int,Tuple{Float64,Float64}}()
	for result in resultset
		tAhead = time_period - result.BaseTimePeriod
		tAhead > 0 && tAhead <= length(result.GenData[generator]) ? gen_data[result.BaseTimePeriod] = (result.GenData[generator][tAhead], result.Prices[tAhead]) : continue	
	end
	return gen_data
end


function DemandData(resultset)
	demand_data = Dict{String, Vector{Float64}}()
	for key in keys(resultset[1].DemandData)
		demand_data[key] = Vector{Float64}()
	end
	for result in resultset
		for key in keys(result.DemandData)
			push!(demand_data[key], result.DemandData[key][1]) # only getting the demand data for this base time period - fully cleared final dispatch
		end
	end
	return demand_data
end

function StorageDischargeQuantities(resultset)
	storage_data = Vector{Float64}()
	for result in resultset
		push!(storage_data, result.StorageDischargeQuantities[1]) # only getting the discharge quantity for this base time period - fully cleared final dispatch
	end
	return storage_data
end

function StorageChargeQuantities(resultset)
	storage_data = Vector{Float64}()
	for result in resultset
		push!(storage_data, result.StorageChargeQuantities[1]) # only getting the charge quantity for this base time period - fully cleared final dispatch
	end
	return storage_data
end


function StorageStateOfChargeOutcomes(resultset)
	SOC_data = Vector{Float64}()
	for result in resultset
		push!(SOC_data, result.StorageStateOfCharge[1]) # only getting the SOC for this base time period - fully cleared final result
	end
	return SOC_data
end

mutable struct SEWOutcome
	ConsumerSurplus::Float64
	ProducerSurplus::Float64
	# and I guess if we have network constraints, a congestion rent
	# could also be nice to do this by generator type as well as in aggregate (also demands)
	SEWOutcome() = new()
end

function SocioEconomicWelfare(resultset)
	SEW_data = Vector{SEWOutcome}()

	# for each result set
	for result in resultset
		println(result.BidPrices)
		# 1. consider the final outcome for each producer in revenue for the time period - cost for the energy delivered in the time period and sum to make a producer surplus
		
		# for all previous rounds, how much has been procured (since the prior round), and at what cost - multiply these and add them up
		revenue_for_period = 0.0
		for prev_result in resultset[1:result.BaseTimePeriod] # all previous results, including the one we're inspecting for the final adjustment
			# for each generator, get revenue
			time_period_offset = result.BaseTimePeriod - prev_result.BaseTimePeriod + 1
			time_period_offset > length(prev_result.Prices) && continue # there is not a clearing for this time period
			for (g, gen_quantity) in prev_result.GenData
				q_earlier = time_period_offset == 1 || prev_result.BaseTimePeriod == 1 || time_period_offset == length(prev_result.Prices) ? 0.0 : resultset[prev_result.BaseTimePeriod - 1].GenData[g][time_period_offset + 1] # +1 b/c in this previous clearing, this period is one further into the array
				q_change = gen_quantity[time_period_offset] - q_earlier
				p_at_hour = prev_result.Prices[time_period_offset]
				additional_revenue = q_change * p_at_hour
				if result.BaseTimePeriod == 32
					println("$additional_revenue for period: $(result.BaseTimePeriod) for generator: $g")
				end
				revenue_for_period += additional_revenue
			end
			if result.BaseTimePeriod == 32
				println("revenue for period $(result.BaseTimePeriod) is: $revenue_for_period")
			end
		end

		cost_for_period = 0.0

		for (g,gen_quantities) in GenData(resultset)
			if result.BaseTimePeriod == 32
				println("cost for gen $g in period $(result.BaseTimePeriod) is: $(gen_quantities[result.BaseTimePeriod]) times $(result.BidPrices[g][1])")
			end
			cost_for_gen = gen_quantities[result.BaseTimePeriod]*result.BidPrices[g][1]
			cost_for_period += cost_for_gen
		end
		if result.BaseTimePeriod == 32
			println("surplus for period $(result.BaseTimePeriod) is: $revenue_for_period - $cost_for_period = $(revenue_for_period - cost_for_period)")
		end
		producer_surplus = revenue_for_period - cost_for_period

		# 2. consider the final outcome for each demander in bid price * quantity for the time period - payments made for the time period - NOTE: given no prediction error, this will all be cleared in the first time period considered?
		demand_quantity_data = DemandData(resultset)
		consumer_surplus = 0.0
		for (d,demand_quantities) in demand_quantity_data
			utility_gain_per_unit = result.BidPrices[d][1] - result.Prices[length(result.Prices)] # making the assumption that Qd doesn't change - this will not always be valid - need better accounting
			surplus_utility = utility_gain_per_unit * demand_quantities[1]
			consumer_surplus += surplus_utility
		end
		outcome = SEWOutcome()
		outcome.ConsumerSurplus = consumer_surplus
		outcome.ProducerSurplus = producer_surplus
		push!(SEW_data, outcome) 
	end
	return SEW_data
end

function SocioEconomicWelfare_T(resultset)
	SEW_data = Vector{SEWOutcome}()

	# for each result set
	for result in resultset
		# 1. consider the final outcome for each producer in revenue for the time period - cost for the energy delivered in the time period and sum to make a producer surplus
		
		# for all previous rounds, how much has been procured (since the prior round), and at what cost - multiply these and add them up
		revenue_for_period = 0.0
		for prev_result in resultset[1:result.BaseTimePeriod] # all previous results, including the one we're inspecting for the final adjustment
			# for each generator, get revenue
			
			for t in prev_result.Transactions
				for g in keys(prev_result.GenData)
					revenue_for_period += (t.TimePeriod == result.BaseTimePeriod && t.Party == g ? t.Quantity * t.Price : 0.0)
				end
			end

			if result.BaseTimePeriod == 32
				println("revenue for period $(result.BaseTimePeriod) is: $revenue_for_period")
			end
		end

		cost_for_period = 0.0

		for (g,gen_quantities) in GenData(resultset)
			if result.BaseTimePeriod == 32
				println("cost for gen $g in period $(result.BaseTimePeriod) is: $(gen_quantities[result.BaseTimePeriod]) times $(result.BidPrices[g][1])")
			end
			cost_for_gen = gen_quantities[result.BaseTimePeriod]*result.BidPrices[g][1]
			cost_for_period += cost_for_gen
		end
		if result.BaseTimePeriod == 32
			println("surplus for period $(result.BaseTimePeriod) is: $revenue_for_period - $cost_for_period = $(revenue_for_period - cost_for_period)")
		end
		producer_surplus = revenue_for_period - cost_for_period

		# 2. consider the final outcome for each demander in bid price * quantity for the time period - payments made for the time period - NOTE: given no prediction error, this will all be cleared in the first time period considered?
		consumer_surplus = 0.0

		for prev_result in resultset[1:result.BaseTimePeriod] # all previous results, including the one we're inspecting for the final adjustment
			# for each generator, get revenue
			
			for t in prev_result.Transactions
				for d in keys(prev_result.DemandData)
					consumer_surplus += (t.TimePeriod == result.BaseTimePeriod && t.Party == d ? t.Quantity * t.Price : 0.0)
				end
			end

		end

		outcome = SEWOutcome()
		outcome.ConsumerSurplus = consumer_surplus
		outcome.ProducerSurplus = producer_surplus
		push!(SEW_data, outcome) 
	end
	return SEW_data
end

# TODO: work out appending here

function Transactions(resultset)
	all_transactions = []
	for result in resultset
		append!(all_transactions, result.Transactions)
	end
	return all_transactions
end


# todo: maybe a write to csv or similar to have "raw" data to work with

end;
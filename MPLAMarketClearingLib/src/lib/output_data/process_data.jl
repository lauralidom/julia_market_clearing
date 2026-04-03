module ProcessData

using Dates, JuMP, MathOptInterface, DataFrames


include("../helpers/helper_model_results.jl")

# this struct holds the incoming data in a standard format

mutable struct ClearingData
	Timestamp::DateTime
	MarketName::String
	ClearingTimePeriod::Int
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

function AddToResultSet!(resultset, model, time_period, market_name)
	cd = ClearingData()
	cd.Timestamp = Dates.now()
	cd.MarketName = market_name
	cd.ClearingTimePeriod = time_period
	cd.BaseTimePeriod = HelperModelResults.BaseTimePeriod(model)

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


	cd.Transactions = HelperModelResults.Transactions(cd, resultset, market_name)

	push!(resultset, cd)
end


# some helpers to get the data you're interested in out of the result set

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

function TimePeriods(resultset)
	if length(resultset) == 0
		return []
	end
	lastTimeConsidered = resultset[length(resultset)].BaseTimePeriod + length(resultset[length(resultset)].TimePeriods) - 1
	time_periods = range(1,lastTimeConsidered)
	return time_periods
end

function LastDispatchDecisions(resultset, time_periods, collection, key)
	data = zeros(length(time_periods))
	for time_period in time_periods
		for result in resultset

			# decide which vector of data we're looking at
			dispatchInResult = []
			if collection == "generator"
				dispatchInResult = result.GenData[key]
			elseif collection == "demand"
				dispatchInResult = result.DemandData[key]
			elseif collection == "storage_discharge"
				dispatchInResult = result.StorageDischargeQuantities
			elseif collection == "storage_charge"
				dispatchInResult = result.StorageChargeQuantities
			elseif collection == "storage_SOC"
				dispatchInResult = result.StorageStateOfCharge
			end

			# extract the data we need
			if time_period-result.BaseTimePeriod > 0 && time_period-result.BaseTimePeriod <= length(dispatchInResult)
				data[time_period] = dispatchInResult[time_period-result.BaseTimePeriod] # we only want the latest dispatch, so we allow overwriting - this will be the final dispatch
			end
		end
	end

	return data
end

#=
function GenData(resultset)
	timePeriods = TimePeriods(resultset)
	gen_data = Dict{String, Array{Float64}}()
	for key in keys(resultset[1].GenData)
		gen_data[key] = zeros(length(timePeriods))
	end
	for time_period in timePeriods
		for result in resultset
			for key in keys(result.GenData)
				if 1+time_period-result.BaseTimePeriod > 0 && 1+time_period-result.BaseTimePeriod <= length(result.GenData[key])
					gen_data[key][time_period] = result.GenData[key][1+time_period-result.BaseTimePeriod] # we only want the latest dispatch, so we allow overwriting - this will be the final dispatch
				end
			end
		end
	end
	return gen_data
end
=#

function GenData(resultset)
	time_periods = TimePeriods(resultset)
	gen_data = Dict{String, Array{Float64}}()
	for key in keys(resultset[1].GenData)
		gen_data[key] = LastDispatchDecisions(resultset, time_periods, "generator", key)
	end
	
	return gen_data
end
#=
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
=#

function DemandData(resultset)
	time_periods = TimePeriods(resultset)
	demand_data = Dict{String, Array{Float64}}()
	for key in keys(resultset[1].DemandData)
		demand_data[key] = LastDispatchDecisions(resultset, time_periods, "demand", key)
	end
	
	return demand_data
end

#=
function StorageDischargeQuantities(resultset)
	storage_data = Vector{Float64}()
	for result in resultset
		push!(storage_data, result.StorageDischargeQuantities[1]) # only getting the discharge quantity for this base time period - fully cleared final dispatch
	end
	return storage_data
end
=#

function StorageDischargeQuantities(resultset)
	time_periods = TimePeriods(resultset)
	return LastDispatchDecisions(resultset, time_periods, "storage_discharge", "")
end

#=
function StorageChargeQuantities(resultset)
	storage_data = Vector{Float64}()
	for result in resultset
		push!(storage_data, result.StorageChargeQuantities[1]) # only getting the charge quantity for this base time period - fully cleared final dispatch
	end
	return storage_data
end
=#

function StorageChargeQuantities(resultset)
	time_periods = TimePeriods(resultset)
	return LastDispatchDecisions(resultset, time_periods, "storage_charge", "")
end

#=
function StorageStateOfChargeOutcomes(resultset)
	SOC_data = Vector{Float64}()
	for result in resultset
		push!(SOC_data, result.StorageStateOfCharge[1]) # only getting the SOC for this base time period - fully cleared final result
	end
	return SOC_data
end
=#

function StorageStateOfChargeOutcomes(resultset)
	time_periods = TimePeriods(resultset)
	return LastDispatchDecisions(resultset, time_periods, "storage_SOC", "")
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



mutable struct SEWOutcome
	ConsumerSurplus::Float64
	ProducerSurplus::Float64
	StoragePayments::Float64
	PlayerOutcomes::Dict{String,Dict{String,Float64}}
	# and I guess if we have network constraints, a congestion rent
	# could also be nice to do this by generator type as well as in aggregate (also demands)
	SEWOutcome() = new()
end

function resultsLEQ(resultset, time_period)
	leqResults = []

	for result in resultset
		if result.BaseTimePeriod <= time_period
			push!(leqResults, result)
		end
	end
	return leqResults
end
#=
function SocioEconomicWelfare(resultset)
	SEW_data = Vector{SEWOutcome}()

	# for each result set
	for result in resultset
		println(result.BidPrices)
		# 1. consider the final outcome for each producer in revenue for the time period - cost for the energy delivered in the time period and sum to make a producer surplus
		
		# for all previous rounds, how much has been procured (since the prior round), and at what cost - multiply these and add them up
		revenue_for_period = 0.0
		for prev_result in resultsLEQ(resultset, result.BaseTimePeriod) # all previous results, including the one we're inspecting for the final adjustment
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

=#

function SocioEconomicWelfare_T(resultset)
	SEW_data = Vector{SEWOutcome}()

	demand_data = DemandData(resultset)
	gen_data = GenData(resultset)

	# for each result set
	for time_period in TimePeriods(resultset)
		relevantResults = resultsLEQ(resultset, time_period)
		
		revenue_for_period = 0.0
		consumer_payments = 0.0
		consumer_value = 0.0
		consumer_surplus = 0.0
		storage_payments = 0.0
		cost_for_period = 0.0
		player_outcomes = Dict{String,Dict{String, Float64}}()
			
		for prev_result in relevantResults # all previous results, including the one we're inspecting for the final adjustment
			

			!in(time_period, prev_result.TimePeriods) && continue # if the time period we're looking for isn't in this result, skip it
			
			for t in prev_result.Transactions
				# 1. consider the final outcome for each producer in revenue for the time period - cost for the energy delivered in the time period and sum to make a producer surplus
		
				# for each generator, get revenue
				for g in keys(prev_result.GenData)
					if !haskey(player_outcomes,g)
						player_outcomes[g] = Dict{String, Float64}()
						player_outcomes[g]["revenue"] = 0.0
						player_outcomes[g]["cost"] = 0.0
						player_outcomes[g]["quantity"] = 0.0
					end 
					player_outcomes[g]["revenue"] += (t.TimePeriod == time_period && t.Party == g ? t.Quantity * t.Price : 0.0)
					revenue_for_period += (t.TimePeriod == time_period && t.Party == g ? t.Quantity * t.Price : 0.0)
				end

				# 2. consider the final outcome for each demander in bid price * quantity for the time period - payments made for the time period - NOTE: given no prediction error, this will all be cleared in the first time period considered?
				# for each generator, get revenue
				for d in keys(prev_result.DemandData)
					if !haskey(player_outcomes,d)
						player_outcomes[d] = Dict{String, Float64}()
						player_outcomes[d]["payments"] = 0.0
						player_outcomes[d]["value"] = 0.0
						player_outcomes[d]["quantity"] = 0.0
					end 
					player_outcomes[d]["payments"]  += (t.TimePeriod == time_period && t.Party == d ? t.Quantity * t.Price : 0.0)
					consumer_payments += (t.TimePeriod == time_period && t.Party == d ? t.Quantity * t.Price : 0.0)
				end

				# 3. consider the final outcome for storage in price * quantity for the time period
			
				# for storage get transactions for charge and discharge
			
				storage_payments += (t.TimePeriod == time_period && t.Party == "storage" ? t.Quantity * t.Price : 0.0)
			end

			# generator costs only for the final dispatch - thus all the 0.0 setting at the beginning
			# note the difference between total (outside the for loop) and the player (inside) 
			# TODO: this should be done once above and results stored
			cost_for_period = 0.0
			for (g,gen_quantities) in gen_data
				player_outcomes[g]["cost"] = 0.0
				player_outcomes[g]["quantity"] = 0.0
				cost_for_gen = gen_quantities[time_period]*prev_result.BidPrices[g][1]
				player_outcomes[g]["cost"] += cost_for_gen
				player_outcomes[g]["quantity"] += gen_quantities[time_period]
				cost_for_period += cost_for_gen
			end
			consumer_value = 0.0
			# demand value only for the final dispatch
			for (d,demand_quantities) in demand_data
				player_outcomes[d]["value"] = 0.0
				player_outcomes[d]["quantity"] = 0.0
				value_for_demand = demand_quantities[time_period]*prev_result.BidPrices[d][1]
				player_outcomes[d]["value"] += value_for_demand
				player_outcomes[d]["quantity"] += demand_quantities[time_period]
				consumer_value += value_for_demand
			end
			
		end

		# for all previous rounds, how much has been procured (since the prior round), and at what cost - multiply these and add them up
			
		producer_surplus = revenue_for_period - cost_for_period
		consumer_surplus = consumer_value - consumer_payments

		# safety check for SEW

		if !isapprox(consumer_value - cost_for_period, consumer_surplus + producer_surplus + storage_payments)
			println("mismatch: $(consumer_value - cost_for_period) != $(consumer_surplus + producer_surplus + storage_payments)")
		end


		outcome = SEWOutcome()
		outcome.ConsumerSurplus = consumer_surplus
		outcome.ProducerSurplus = producer_surplus
		outcome.StoragePayments = storage_payments
		outcome.PlayerOutcomes = player_outcomes

		push!(SEW_data, outcome) 
	end
	return SEW_data
end


function SocioEconomicWelfareForTimeRange(resultset, timerange)
	sewResults = SocioEconomicWelfare_T(resultset)
	sew = 0
	for t in timerange
		sew += sewResults[t].ConsumerSurplus + sewResults[t].ProducerSurplus
	end
	return sew
end

function EconomicIndicatorsForTimeRange(resultset, timerange)
	sewResults = SocioEconomicWelfare_T(resultset)
	indicators = Dict{String, Float64}()
	indicators["sew"] = 0.0
	indicators["storage_payments"] = 0.0
	indicators["consumer_surplus"] = 0.0
	indicators["producer_surplus"] = 0.0
	player_indicators = Dict{String,Dict{String,Float64}}()
	for t in timerange
		indicators["sew"] += sewResults[t].ConsumerSurplus + sewResults[t].ProducerSurplus
		indicators["storage_payments"] += sewResults[t].StoragePayments
		indicators["consumer_surplus"] += sewResults[t].ConsumerSurplus
		indicators["producer_surplus"] += sewResults[t].ProducerSurplus

		for (player,p_indicators) in sewResults[t].PlayerOutcomes
			if !haskey(player_indicators, player)
				player_indicators[player] = Dict{String,Float64}()
				for (key, value) in pairs(p_indicators)
					player_indicators[player][key] = value
				end
			else
				for (key, value) in pairs(p_indicators)
					player_indicators[player][key] += value
				end
			end

		end

	end
	return (indicators, player_indicators)
end

# This function takes a result set and gets the latest dispatch for a generator for a particular time_period
# todo: base this on transactions if this is our best source of data
# there is an assumption here that the resultset is sorted by clearing time

function GenPreviousDispatchDataForTimePeriod(resultset, generator, time_period)
	gen_dispatch = 0.0
	for result in resultset
		tAhead = time_period - result.BaseTimePeriod
		tAhead > 0 && tAhead <= length(result.GenData[generator]) ? gen_dispatch = result.GenData[generator][tAhead] : continue	
	end
	return gen_dispatch

end

# This function takes a result set and gets the latest dispatch for a demand for a particular time_period
# todo: base this on transactions if this is our best source of data
# there is an assumption here that the resultset is sorted by clearing time

function DemPreviousDispatchDataForTimePeriod(resultset, demand, time_period)
	dem_dispatch = 0.0
	for result in resultset
		tAhead = time_period - result.BaseTimePeriod
		tAhead > 0 && tAhead <= length(result.DemandData[demand]) ? gen_data = result.DemandData[demand][tAhead] : continue	
	end
	return dem_dispatch

end

function Transactions(resultset)
	all_transactions = []
	for result in resultset
		append!(all_transactions, result.Transactions)
	end
	return all_transactions
end

#= TRANSACTION
	MarketName::String
	Party::String
	Quantity::Float64
	Price::Float64
	TimePeriod::Int
	ClearingTimePeriod::Int
	PartyType::PartyTypeEnum
=#

function TransactionDataFrame(resultset)
	transactions = Transactions(resultset)
	df = DataFrame(MarketName=String[], Party=String[], Quantity=Float64[], Price=Float64[], TimePeriod=Int[], ClearingTimePeriod=Int[], PartyType=String[])
	for t in transactions
		push!(df, [t.MarketName, t.Party, t.Quantity, t.Price, t.TimePeriod, t.ClearingTimePeriod, string(Symbol(t.PartyType))])
	end
	return df
end


# todo: maybe a write to csv or similar to have "raw" data to work with

end;
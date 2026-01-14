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
	BidPrices::Dict{String, Vector{Float64}} # only gens for now
	DemandData::Dict{String, Vector{Float64}}
	StorageDischargeQuantities::Vector{Float64} # TODO: should rethink data format here for storage
	StorageChargeQuantities::Vector{Float64}
	StorageStateOfCharge::Vector{Float64}
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
	# todo, add some actual data

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


# todo: maybe a write to csv or similar to have "raw" data to work with

end;
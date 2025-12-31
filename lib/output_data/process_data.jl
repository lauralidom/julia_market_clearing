module ProcessData

using Dates, JuMP, MathOptInterface


include("..\\helpers\\helper_model_results.jl")

# this struct holds the incoming data in a standard format

mutable struct ClearingData
	Timestamp::DateTime
	BaseHour::Int
	TerminationStatus::MathOptInterface.TerminationStatusCode
	ObjectiveValue::Number
	Hours::Vector{Int}
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

function AddToResultSet!(resultset, model, hour)
	cd = ClearingData()
	cd.Timestamp = Dates.now()
	cd.BaseHour = hour
	# todo, add some actual data

	cd.TerminationStatus = termination_status(model)
	cd.ObjectiveValue = objective_value(model)
	cd.Hours = HelperModelResults.Hours(model)
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
		priceset = (result.BaseHour,result.Prices)
		push!(pricesets,priceset)
	end
	return pricesets
end

#= TODO
	hours = ProcessData.Hours(resultset)
	gen_data = ProcessData.GenData(resultset)
    dem_data = ProcessData.DemandData(resultset)
	Qdis_val = ProcessData.StorageDischargeQuantities(resultset)
	Qch_val = ProcessData.StorageChargeQuantities(resultset)
=#

# I am disliking how the storage here is just implying the hours heuristically - would be better to be explicit

function Hours(resultset)
	hours = []
	for result in resultset
		push!(hours,result.BaseHour)
	end
	return hours
end

function GenData(resultset)
	gen_data = Dict{String, Vector{Float64}}()
	for key in keys(resultset[1].GenData)
		gen_data[key] = Vector{Float64}()
	end
	for result in resultset
		for key in keys(result.GenData)
			push!(gen_data[key], result.GenData[key][1]) # only getting the gen data for this base hour - fully cleared final dispatch
		end
	end
	return gen_data
end


function BidPricesForHour(resultset, generator, hour)
	bid_prices = Dict{Int,Float64}()
	for result in resultset
		hour - result.BaseHour > 0 && hour - result.BaseHour <= length(result.BidPrices[generator]) ? bid_prices[result.BaseHour] =  result.BidPrices[generator][hour - result.BaseHour] : continue
	end
	return bid_prices
end


function GenDispatchDataForHour(resultset, generator, hour) 
	gen_data = Dict{Int,Tuple{Float64,Float64}}()
	for result in resultset
		hoursAhead = hour - result.BaseHour
		hoursAhead > 0 && hoursAhead <= length(result.GenData[generator]) ? gen_data[result.BaseHour] = (result.GenData[generator][hoursAhead], result.Prices[hoursAhead]) : continue	
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
			push!(demand_data[key], result.DemandData[key][1]) # only getting the demand data for this base hour - fully cleared final dispatch
		end
	end
	return demand_data
end

function StorageDischargeQuantities(resultset)
	storage_data = Vector{Float64}()
	for result in resultset
		push!(storage_data, result.StorageDischargeQuantities[1]) # only getting the discharge quantity for this base hour - fully cleared final dispatch
	end
	return storage_data
end

function StorageChargeQuantities(resultset)
	storage_data = Vector{Float64}()
	for result in resultset
		push!(storage_data, result.StorageChargeQuantities[1]) # only getting the charge quantity for this base hour - fully cleared final dispatch
	end
	return storage_data
end


function StorageStateOfChargeOutcomes(resultset)
	SOC_data = Vector{Float64}()
	for result in resultset
		push!(SOC_data, result.StorageStateOfCharge[1]) # only getting the SOC for this base hour - fully cleared final result
	end
	return SOC_data
end

# todo: maybe a write to csv or similar to have "raw" data to work with

end;
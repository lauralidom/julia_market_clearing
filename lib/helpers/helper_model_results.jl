module HelperModelResults

using JuMP


function TimePeriods(m::Model)
	# return the time periods cleared in this model
	CH = m.ext[:sets][:CH]
	return collect(CH)  # collect https://docs.julialang.org/en/v1/base/collections/#Base.collect-Tuple%7BAny%7D - unclear to me why this is needed
end

function Prices(m::Model)
	# compute market-clearing prices for each time period as duals of the energy balance constraints
	CH = m.ext[:sets][:CH]
	λ  = dual.(m.ext[:constraints][:energy_balance])   # hourly prices [EUR/MWh]
	return [λ[h] for h in CH]
end

function BidPrices(m)
	time_periods = TimePeriods(m)
	IG = m.ext[:sets][:IG]
	ID = m.ext[:sets][:ID]
    bid_prices = Dict{String, Vector{Float64}}()
    for g in IG
        bid_prices[g] = [value(m.ext[:timeseries][:Pr_gen][g,t]) for t in time_periods]
    end
    for d in ID
        bid_prices[d] = [value(m.ext[:timeseries][:Pr_dem][d,t]) for t in time_periods]
    end
    return bid_prices
end

function StorageChargeQuantities(m)
	if m.ext[:parameters][:has_storage]
	    Qch_val = value.(m.ext[:variables][:Qch])
	else
		return error("no storage")
	end
end

function StorageDischargeQuantities(m)
	if m.ext[:parameters][:has_storage]
	   	return Qdis_val = value.(m.ext[:variables][:Qdis])
	else
		return error("no storage")
	end
end

function SOCValues(m)
	if m.ext[:parameters][:has_storage]
	   	return SOC_val = value.(m.ext[:variables][:SOC])
	else
		return error("no storage")
	end
end

function GenData(m)
	time_periods = TimePeriods(m)
	IG = m.ext[:sets][:IG]
    gen_data = Dict{String, Vector{Float64}}()
    for g in IG
        gen_data[g] = [value(m.ext[:variables][:Qg][g,t]) for t in time_periods]
    end
    return gen_data
end


function DemandData(m)
	time_periods = TimePeriods(m)
	ID = m.ext[:sets][:ID]
    dem_data = Dict{String, Vector{Float64}}()
    for d in ID
        dem_data[d] = [value(m.ext[:variables][:Qd][d,t]) for t in time_periods]
    end
    return dem_data
end


mutable struct Transaction
	Party::String
	Quantity::Float64
	Price::Float64
	TimePeriod::Int
	ClearingTimePeriod::Int
	Transaction() = new()
end

# compare clearing outcomes with previous clearings to generate a set of transactions

# TODO: I think this will break down if we skip time periods between clearing periods

function Transactions(clearingData, resultset)
	transaction_time_period = clearingData.BaseTimePeriod

	transactions = []
	has_last_result = length(resultset) > 0 # special handling for time period 1
	last_clearing_result = has_last_result ? resultset[length(resultset)] : nothing
	prices = clearingData.Prices
	# for each demand, in each time period cleared
	for (d, dem_qs) in clearingData.DemandData
		for (t, Qd) in enumerate(dem_qs)
			last_clearing_q = has_last_result && length(last_clearing_result.DemandData[d]) > t ? last_clearing_result.DemandData[d][t+1] : 0.0
			adjustment_q = Qd - last_clearing_q
			if adjustment_q !== 0
				transaction = Transaction()
				transaction.Party = d
				transaction.Quantity = adjustment_q
				transaction.Price = prices[1]
				transaction.TimePeriod = clearingData.BaseTimePeriod + t - 1 # -1 because 1 indexed and 1 is the current period
				transaction.ClearingTimePeriod = clearingData.BaseTimePeriod
				
				push!(transactions, transaction)
			end
		end

	end



	# for each generator, in each time period cleared
	for (g, gen_qs) in clearingData.GenData
		for (t, Qg) in enumerate(gen_qs)
			last_clearing_q = has_last_result && length(last_clearing_result.GenData[g]) > t ? last_clearing_result.GenData[g][t+1] : 0.0
			adjustment_q = Qg - last_clearing_q
			if adjustment_q !== 0
				transaction = Transaction()
				transaction.Party = g
				transaction.Quantity = adjustment_q
				transaction.Price = prices[1]
				transaction.TimePeriod = clearingData.BaseTimePeriod + t - 1 # -1 because 1 indexed and 1 is the current period
				transaction.ClearingTimePeriod = clearingData.BaseTimePeriod

				push!(transactions, transaction)
			end
		end

	end

	return transactions
end



end;
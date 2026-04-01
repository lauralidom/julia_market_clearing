module HelperModelResults

using JuMP

function BaseTimePeriod(m::Model)
	return TimePeriods(m)[1]
end

function TimePeriods(m::Model)
	# return the time periods cleared in this model
	return m.ext[:sets][:CH]
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
	    Qch_val = value.(m.ext[:variables][:Qch] * m.ext[:sets][:power_to_energy_scale])
	else
		return error("no storage")
	end
end

function StorageDischargeQuantities(m)
	if m.ext[:parameters][:has_storage]
	   	return Qdis_val = value.(m.ext[:variables][:Qdis] * m.ext[:sets][:power_to_energy_scale])
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
        gen_data[g] = [value(m.ext[:variables][:Qg][g,t] * m.ext[:sets][:power_to_energy_scale]) for t in time_periods]
    end
    return gen_data
end


function DemandData(m)
	time_periods = TimePeriods(m)
	ID = m.ext[:sets][:ID]
    dem_data = Dict{String, Vector{Float64}}()
    for d in ID
        dem_data[d] = [value(m.ext[:variables][:Qd][d,t] * m.ext[:sets][:power_to_energy_scale]) for t in time_periods]
    end
    return dem_data
end

@enum PartyTypeEnum PARTY_DEMAND PARTY_GENERATOR PARTY_STORAGE


mutable struct Transaction
	MarketName::String
	Party::String
	Quantity::Float64
	Price::Float64
	TimePeriod::Int
	ClearingTimePeriod::Int
	PartyType::PartyTypeEnum
	Transaction() = new()
end

function MakeTransaction(party, quantity, price, time_period, clearing_time_period, party_type, market_name) 
	t = Transaction()
	t.MarketName = market_name
	t.Party = party
	t.Quantity = quantity
	t.Price = price
	t.TimePeriod = time_period
	t.ClearingTimePeriod = clearing_time_period
	t.PartyType = party_type
	return t
end

# compare clearing outcomes with previous clearings to generate a set of transactions

function Transactions(clearingData, resultset, market_name)
	transaction_time_period = clearingData.BaseTimePeriod

	transactions = []
	has_last_result = length(resultset) > 0 # special handling for time period 1
	last_clearing_result = has_last_result ? resultset[length(resultset)] : nothing
	last_clearing_base_time = has_last_result ? last_clearing_result.BaseTimePeriod : 0
	prices = clearingData.Prices
	# for each demand, in each time period cleared
	for (d, dem_qs) in clearingData.DemandData
		for (t, Qd) in enumerate(dem_qs)
			last_clearing_time_offset = clearingData.BaseTimePeriod + (t - 1) - last_clearing_base_time + 1 # the time when the new data was cleared plus the offset from there for this t minus the last time we were cleared plus one because we are 1 indexed
			last_clearing_q = has_last_result && length(last_clearing_result.DemandData[d]) >= last_clearing_time_offset && last_clearing_time_offset > 0 ? last_clearing_result.DemandData[d][last_clearing_time_offset] : 0.0
			adjustment_q = Qd - last_clearing_q
			if adjustment_q != 0.0
				transaction = Transaction()
				transaction.Party = d
				transaction.Quantity = adjustment_q
				transaction.Price = prices[t]
				transaction.TimePeriod = clearingData.BaseTimePeriod + t - 1 # -1 because 1 indexed and 1 is the current period
				transaction.ClearingTimePeriod = clearingData.ClearingTimePeriod
				transaction.PartyType = PARTY_DEMAND
				transaction.MarketName = market_name
				push!(transactions, transaction)
			end
		end

	end



	# for each generator, in each time period cleared
	for (g, gen_qs) in clearingData.GenData
		for (t, Qg) in enumerate(gen_qs)
			last_clearing_time_offset = clearingData.BaseTimePeriod + (t - 1) - last_clearing_base_time + 1 # the time when the new data was cleared plus the offset from there for this t minus the last time we were cleared plus one because we are 1 indexed
			last_clearing_q = has_last_result && length(last_clearing_result.GenData[g]) >= last_clearing_time_offset && last_clearing_time_offset > 0  ? last_clearing_result.GenData[g][last_clearing_time_offset] : 0.0
			adjustment_q = Qg - last_clearing_q
			if adjustment_q != 0.0
				transaction = Transaction()
				transaction.Party = g
				transaction.Quantity = adjustment_q
				transaction.Price = prices[t]
				transaction.TimePeriod = clearingData.BaseTimePeriod + t - 1 # -1 because 1 indexed and 1 is the current period
				transaction.ClearingTimePeriod = clearingData.ClearingTimePeriod
				transaction.PartyType = PARTY_GENERATOR
				transaction.MarketName = market_name

				push!(transactions, transaction)
			end
		end

	end

	# for storage charging/discharging, in each time period cleared
	for (t, Qc) in enumerate(clearingData.StorageChargeQuantities)
		Qd = clearingData.StorageDischargeQuantities[t]
		last_clearing_time_offset = clearingData.BaseTimePeriod + (t - 1) - last_clearing_base_time + 1 # the time when the new data was cleared plus the offset from there for this t minus the last time we were cleared plus one because we are 1 indexed
		last_clearing_qc = has_last_result && length(last_clearing_result.StorageChargeQuantities) >= last_clearing_time_offset && last_clearing_time_offset > 0  ? last_clearing_result.StorageChargeQuantities[last_clearing_time_offset] : 0.0
		last_clearing_qd = has_last_result && length(last_clearing_result.StorageDischargeQuantities) >= last_clearing_time_offset && last_clearing_time_offset > 0  ? last_clearing_result.StorageDischargeQuantities[last_clearing_time_offset] : 0.0
		last_clearing_q = max(last_clearing_qc, last_clearing_qd)
		if last_clearing_qd < last_clearing_qc
			last_clearing_q *= -1
		end
		new_q = max(Qc, Qd)
		if Qd < Qc
			new_q *= -1
		end
		adjustment_q = new_q - last_clearing_q

		if adjustment_q != 0.0
			transaction = Transaction()
			transaction.Party = "storage"
			transaction.Quantity = adjustment_q
			transaction.Price = prices[t]
			transaction.TimePeriod = clearingData.BaseTimePeriod + t - 1 # -1 because 1 indexed and 1 is the current period
			transaction.ClearingTimePeriod = clearingData.ClearingTimePeriod
			transaction.PartyType = PARTY_STORAGE
			transaction.MarketName = market_name

			push!(transactions, transaction)
		end

	end

	return transactions
end



end;
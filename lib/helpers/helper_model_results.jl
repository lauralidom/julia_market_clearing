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



end;
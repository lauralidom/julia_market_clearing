module PlotDispatchChangesForHour

using Plots
using JuMP
using Statistics

include("../output_data/process_data.jl")

function plot(resultset, generator, time_period)

	time_periods = ProcessData.TimePeriods(resultset)
	gen_data = ProcessData.GenDispatchDataForTimePeriod(resultset, generator, time_period)
	bid_prices = ProcessData.BidPricesForTimePeriod(resultset, generator, time_period)
	total_revenue = 0
    # for (time_period, (quantity, price)) in gen_data
    for t in time_periods
    	if haskey(gen_data,t)
    		(quantity, price) = gen_data[t]
    		change_text = ""
    		(prev_quantity, prev_price) = (0.0,0.0)
    		if haskey(gen_data, t - 1)
    			(prev_quantity, prev_price) = gen_data[t - 1]
    		end
			if quantity != prev_quantity
				revenue_change = (quantity - prev_quantity) * price
				change_text = " changed from $prev_quantity at price: $prev_price, revenue change: $revenue_change"
				total_revenue += revenue_change
			end
    		
    		println(t, " : ", quantity, " at price: ", price, change_text )
    	end
    end

    println("total revenue for $generator in time period $time_period: $total_revenue")

    if haskey(gen_data,time_period-1)
    	(quantity, price) = gen_data[time_period-1]
    	bid_price = bid_prices[time_period-1]
    	println("cost for $generator in time period $time_period: $(quantity*bid_price)")
    end

    transactions = ProcessData.Transactions(resultset)

    for transaction in transactions
    	if transaction.Party == generator && transaction.TimePeriod == time_period
    		println("Transaction for time period $(transaction.TimePeriod): $(transaction.Party) Q: $(transaction.Quantity) P: $(transaction.Price) CTP: $(transaction.ClearingTimePeriod)")
    	end
    end


    # todo, should be a graph
end


end;
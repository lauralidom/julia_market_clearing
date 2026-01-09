module PlotDispatchChangesForHour

using Plots
using JuMP
using Statistics

include("..\\output_data\\process_data.jl")

function plot(resultset, generator, hour)

	hours = ProcessData.Hours(resultset)
	gen_data = ProcessData.GenDispatchDataForHour(resultset, generator, hour)
	bid_prices = ProcessData.BidPricesForHour(resultset, generator, hour)
	total_revenue = 0
    # for (hour, (quantity, price)) in gen_data
    for h in hours
    	if haskey(gen_data,h)
    		(quantity, price) = gen_data[h]
    		change_text = ""
    		(prev_quantity, prev_price) = (0.0,0.0)
    		if haskey(gen_data, h - 1)
    			(prev_quantity, prev_price) = gen_data[h - 1]
    		end
			if quantity != prev_quantity
				revenue_change = (quantity - prev_quantity) * price
				change_text = " changed from $prev_quantity at price: $prev_price, revenue change: $revenue_change"
				total_revenue += revenue_change
			end
    		
    		println(h, " : ", quantity, " at price: ", price, change_text )
    	end
    end

    println("total revenue for $generator in hour $hour: $total_revenue")

    if haskey(gen_data,hour-1)
    	(quantity, price) = gen_data[hour-1]
    	bid_price = bid_prices[hour-1]
    	println("cost for $generator in hour $hour: $(quantity*bid_price)")
    end

    # todo, should be a graph
end


end;
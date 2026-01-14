module PlotPriceEvolution

using Plots


function plot(pricesets)

	p1 = Plots.plot(xlabel="Time Period", ylabel="Price (EUR/MWh)", 
            title="Market Price Evolution",
            label="Price", color=:black, lw=2, size=(1200,1200), legendcolumns=3, legend=:none)


    for (base_time_period,prices) in pricesets
        Plots.scatter!(p1, [base_time_period],[prices[1]], label="")

        base_time_periods = range(base_time_period,base_time_period + length(prices) - 1)
        p1 = Plots.plot!(base_time_periods, prices, label="Time Period $base_time_period")
    end
    
    display(p1)
	return p1
end

end;
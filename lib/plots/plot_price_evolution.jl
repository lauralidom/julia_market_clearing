module PlotPriceEvolution

using Plots


function plot(pricesets)

	p1 = Plots.plot(xlabel="Hour", ylabel="Price (EUR/MWh)", 
            title="Market Price Evolution",
            label="Price", color=:black, lw=2, size=(1200,1200), legendcolumns=3, legend=:outerbottom)


    for (basehour,prices) in pricesets
        Plots.scatter!(p1, [basehour],[prices[1]], label="")

        hours = range(basehour,basehour + length(prices) - 1)
        p1 = Plots.plot!(hours, prices, label="Hour $basehour")
    end
    
    display(p1)
	return p1
end

end;
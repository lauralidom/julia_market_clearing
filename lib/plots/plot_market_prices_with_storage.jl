module PlotMarketPricesWithStorage

using Plots
using JuMP
using Statistics

include("../helpers/helper_model_results.jl")

function plot(m::Model)

	time_periods = HelperModelResults.TimePeriods(m)
	prices = HelperModelResults.Prices(m)
	Qch_val = HelperModelResults.StorageChargeQuantities(m)
	Qdis_val = HelperModelResults.StorageDischargeQuantities(m)

	p1 = Plots.plot(time_periods, prices, 
            xlabel="Time Period", ylabel="Price (EUR/MWh)", 
            title="Market Prices & Storage Operation",
            label="Price", color=:black, lw=2, legend=:topleft)

    # Create a second y-axis for storage power
    p1_twin = twinx(p1)

    # Overlay charging/discharging as bars
    charge_bars = [Qch_val[t] > 0.1 ? Qch_val[t] : NaN for t in time_periods]
    discharge_bars = [Qdis_val[t] > 0.1 ? Qdis_val[t] : NaN for t in time_periods]

    bar!(p1_twin, time_periods, charge_bars, 
        alpha=0.3, color=:blue, 
        label="Charging", ylabel="Storage Power (MW)")
    bar!(p1_twin, time_periods, discharge_bars, 
        alpha=0.3, color=:red, 
        label="Discharging")
    
    display(p1)
	return p1
end

end;
module PlotMarketPricesWithStorage

using Plots
using JuMP
using Statistics

include("../helpers/helper_model_results.jl")

function plot(m::Model)

	hours = HelperModelResults.Hours(m)
	prices = HelperModelResults.Prices(m)
	Qch_val = HelperModelResults.StorageChargeQuantities(m)
	Qdis_val = HelperModelResults.StorageDischargeQuantities(m)

	p1 = Plots.plot(hours, prices, 
            xlabel="Hour", ylabel="Price (EUR/MWh)", 
            title="Market Prices & Storage Operation",
            label="Price", color=:black, lw=2, legend=:topleft)

    # Create a second y-axis for storage power
    p1_twin = twinx(p1)

    # Overlay charging/discharging as bars
    charge_bars = [Qch_val[h] > 0.1 ? Qch_val[h] : NaN for h in hours]
    discharge_bars = [Qdis_val[h] > 0.1 ? Qdis_val[h] : NaN for h in hours]

    bar!(p1_twin, hours, charge_bars, 
        alpha=0.3, color=:blue, 
        label="Charging", ylabel="Storage Power (MW)")
    bar!(p1_twin, hours, discharge_bars, 
        alpha=0.3, color=:red, 
        label="Discharging")
    
    display(p1)
	return p1
end

end;
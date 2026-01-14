module PlotStateOfCharge

using Plots
using JuMP
using Statistics

include("../helpers/helper_model_results.jl")

function plot(m::Model)
	time_periods = HelperModelResults.TimePeriods(m)
	SOC_val = HelperModelResults.SOCValues(m)

	p2 = Plots.plot(time_periods, [SOC_val[t] for t in time_periods], 
              xlabel="Time Period", ylabel="Energy (MWh)", 
              title="Battery State of Charge",
              label="SOC", color=:green, lw=2, fill=(0, 0.2, :green))
    hline!(p2, [m.ext[:parameters][:storage_energy_capacity]], 
           label="Max Capacity", ls=:dash, color=:red)

    display(p2)
    return p2
end

end;
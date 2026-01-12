module PlotStateOfCharge

using Plots
using JuMP
using Statistics

include("../helpers/helper_model_results.jl")

function plot(m::Model)
	hours = HelperModelResults.Hours(m)
	SOC_val = HelperModelResults.SOCValues(m)

	p2 = Plots.plot(hours, [SOC_val[h] for h in hours], 
              xlabel="Hour", ylabel="Energy (MWh)", 
              title="Battery State of Charge",
              label="SOC", color=:green, lw=2, fill=(0, 0.2, :green))
    hline!(p2, [m.ext[:parameters][:storage_energy_capacity]], 
           label="Max Capacity", ls=:dash, color=:red)

    display(p2)
    return p2
end

end;
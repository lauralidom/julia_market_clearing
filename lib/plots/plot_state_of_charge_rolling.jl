module PlotStateOfChargeRolling

using Plots
using JuMP
using Statistics

include("..\\output_data\\process_data.jl")

function plot(resultset)

       hours = ProcessData.Hours(resultset)
       SOC_val = ProcessData.StorageStateOfChargeOutcomes(resultset)

       p2 = Plots.plot(hours, [SOC_val[h] for h in hours], 
              xlabel="Hour", ylabel="Energy (MWh)", 
              title="Battery State of Charge",
              label="SOC", color=:green, lw=2, fill=(0, 0.2, :green))
       # hline!(p2, [m.ext[:parameters][:storage_energy_capacity]], label="Max Capacity", ls=:dash, color=:red) # nice to have but relies on model for now

    display(p2)
    return p2
end

end;
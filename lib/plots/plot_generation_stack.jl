module PlotGenerationStack

using Plots
using JuMP
using Statistics

include("../helpers/helper_model_results.jl")

function plot(m::Model)

	time_periods = HelperModelResults.TimePeriods(m)
	gen_data = HelperModelResults.GenData(m)
    dem_data = HelperModelResults.DemandData(m)
	Qdis_val = HelperModelResults.StorageDischargeQuantities(m)
	Qch_val = HelperModelResults.StorageChargeQuantities(m)

	
    # Define consistent colors
    gen_colors = [:steelblue, :lightgreen, :coral, :orange, :red]

    # Manual stacking order: Base -> Wind -> Solar -> Peak -> Storage - maybe should do by price, swapping base next to peak? , should we verify that each type exists?
    stack_order = ["Base", "Wind", "Solar", "Peak"]

    # Build matrix for areaplot (each row is a generator, each column is a time period)
    stack_matrix = zeros(length(stack_order), length(time_periods))
    for (i, g) in enumerate(stack_order)
        if g in keys(gen_data)
            stack_matrix[i, :] = gen_data[g]
        end
    end

    # Add storage discharge as another row
    discharge_vec = [Qdis_val[t] for t in time_periods]
    if maximum(discharge_vec) > 0.1
        stack_matrix = vcat(stack_matrix, discharge_vec')
        labels = [stack_order; "Storage Discharge"]
    else
        labels = stack_order
    end

    # Calculate max y for limits
    total_demand = [sum(d[t] for (_,d) in dem_data) for t in time_periods]
    charging_vec = [Qch_val[t] for t in time_periods]
    max_y = maximum(total_demand .+ charging_vec) * 1.6

    # Create stacked area plot
    p3 = Plots.plot(xlabel="Time Period", ylabel="Power (MW)",
            title="Generation & Demand Stack",
            legend=:topright,
            ylims=(0, max_y))

    # Stack manually using areaplot with seriestype
    for i in 1:size(stack_matrix, 1)
        if i == 1
            Plots.plot!(p3, time_periods, stack_matrix[i, :],
                fillrange=0, label=labels[i], 
                color=gen_colors[i], alpha=0.8, linewidth=0)
        else
            cumsum_prev = vec(sum(stack_matrix[1:i-1, :], dims=1))
            cumsum_curr = vec(sum(stack_matrix[1:i, :], dims=1))
            Plots.plot!(p3, time_periods, cumsum_curr,
                fillrange=cumsum_prev, label=labels[i],
                color=gen_colors[i], alpha=0.8, linewidth=0)
        end
    end

    # Add demand line on top
    Plots.plot!(p3, time_periods, total_demand .+ charging_vec,
        label="Demand + Charging", color=:black, lw=3, ls=:dash)
    
    display(p3)
    return p3 
end

end;
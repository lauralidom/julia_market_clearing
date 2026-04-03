module PlotGenerationStackRolling

using Plots
using JuMP
using Statistics

include("../output_data/process_data.jl")

function plot(resultset, name, test_id)

	time_periods = ProcessData.TimePeriods(resultset)
	gen_data = ProcessData.GenData(resultset)
    dem_data = ProcessData.DemandData(resultset)
	Qdis_val = ProcessData.StorageDischargeQuantities(resultset)
	Qch_val = ProcessData.StorageChargeQuantities(resultset)

	
    # Define consistent colors
    gen_colors = [:steelblue, :lightgreen, :red, :lightyellow, :coral, :orange]

    # Manual stacking order: Base -> Wind -> Solar -> Peak -> Storage - maybe should do by price, swapping base next to peak? , should we verify that each type exists?
    stack_order = ["Base", "Shoulder", "Peak", "Wind", "Solar"]

    # Build matrix for areaplot (each row is a generator, each column is an time_periods)
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
            ylims=(0, max_y),size=(1200,1200))

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
    savefig(p3, "../DATA/$(test_id)/generation_stack_$(name).png")
    return p3 
end

end;
module PlotPeakGenerationAndStorageUse

using Plots
using JuMP
using Statistics

include("../output_data/process_data.jl")

function plot(resultset)

	time_periods = ProcessData.TimePeriods(resultset)
	gen_data = ProcessData.GenData(resultset)
    dem_data = ProcessData.DemandData(resultset)
	Qdis_val = ProcessData.StorageDischargeQuantities(resultset)
	Qch_val = ProcessData.StorageChargeQuantities(resultset)

	
    # Define consistent colors
    gen_colors = [:steelblue, :lightgreen, :coral, :orange, :red]

    # Only Peak for this version then add Storage
    stack_order = ["Peak"]

    # Build matrix for areaplot (each row is a generator, each column is an time_period)
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

    charge_matrix = zeros(0, length(time_periods))
    charge_labels = ["Storage Charge"]
    # Add storage charge row
    charge_vec = [-1*Qch_val[t] for t in time_periods]
    
    charge_matrix = vcat(charge_matrix, charge_vec')

    # Calculate max y for limits
    total_demand = [sum(d[t] for (_,d) in dem_data) for t in time_periods]
    max_y = maximum(total_demand .+ charge_vec) * 1.6

    # Create stacked area plot
    p3 = Plots.plot(xlabel="Time Period", ylabel="Power (MW)",
            title="Peak Generation and Storage Stack",
            ylims=(-.5*max_y, max_y),size=(1200,1200), legend=:outerbottom)

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

    # Stack charge on the negative side
    for i in 1:size(charge_matrix, 1)
        if i == 1
            Plots.plot!(p3, time_periods, charge_matrix[i, :],
                fillrange=0, label=charge_labels[i], 
                color=gen_colors[length(gen_colors) - 1], alpha=0.8, linewidth=0)
        else
            cumsum_prev = vec(sum(charge_matrix[1:i-1, :], dims=1))
            cumsum_curr = vec(sum(charge_matrix[1:i, :], dims=1))
            Plots.plot!(p3, time_periods, cumsum_curr,
                fillrange=cumsum_prev, label=charge_labels[i],
                color=gen_colors[len(gen_colors) - i -1], alpha=0.8, linewidth=0)
        end
    end

    # Add demand line on top
    Plots.plot!(p3, time_periods, total_demand .+ charge_vec,
        label="Demand + Charging", color=:black, lw=3, ls=:dash)
    
    display(p3)
    return p3 
end

end;
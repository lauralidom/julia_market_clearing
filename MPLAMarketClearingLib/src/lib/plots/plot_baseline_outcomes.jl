module PlotBaselineOutcomes

using Plots
using JuMP
using Statistics

include("../output_data/process_data.jl")

function plot(resultset)

    time_periods = ProcessData.TimePeriods(resultset)

	sew = ProcessData.SocioEconomicWelfare_T(resultset)
	
    # Define consistent colors
    colors = [:steelblue, :lightgreen]

    # Manual stacking order:
    stack_order = ["Producer Surplus", "Consumer Surplus"]

    # Build matrix for areaplot (rows are producer and consumer surplus, each column is a time period)
    stack_matrix = zeros(length(stack_order), length(time_periods))
    for (i, sew_outcome) in enumerate(sew)
        stack_matrix[1, i] = sew_outcome.ProducerSurplus
        stack_matrix[2, i] = sew_outcome.ConsumerSurplus
    end

    # Create stacked area plot
    p3 = Plots.plot(xlabel="Time Period", ylabel="Surplus",
            title="Producer and Consumer Surplus Stack",
            legend=:topright)

    # Stack manually using areaplot with seriestype
    for i in 1:size(stack_matrix, 1)
        if i == 1
            Plots.plot!(p3, time_periods, stack_matrix[i, :],
                fillrange=0, label=stack_order[i], 
                color=colors[i], alpha=0.8, linewidth=0)
        else
            cumsum_prev = vec(sum(stack_matrix[1:i-1, :], dims=1))
            cumsum_curr = vec(sum(stack_matrix[1:i, :], dims=1))
            Plots.plot!(p3, time_periods, cumsum_curr,
                fillrange=cumsum_prev, label=stack_order[i],
                color=colors[i], alpha=0.8, linewidth=0)
        end
    end

    display(p3)
    return p3 
end


end;
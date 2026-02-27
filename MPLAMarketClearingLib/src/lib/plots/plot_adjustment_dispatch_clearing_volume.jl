module PlotAdjustmentDispatchClearingVolume

using Plots
using JuMP
using Statistics

include("../output_data/process_data.jl")

function plot(resultset)


    # todo, should be a graph

    time_periods = ProcessData.DispatchedTimePeriods(resultset)

	transactions = ProcessData.Transactions(resultset)

	# TODO: what window is interesting here? is this information available from the config?

    window_length = length(resultset[length(resultset)].TimePeriods)

	
    # Define consistent colors
    colors = [:steelblue, :green]

    # Manual stacking order:
    stack_order = ["AdjustmentTradingVolume"]

    # Build matrix for areaplot (row is total traded volume, each column is a time period)
    stack_matrix = zeros(length(stack_order), length(time_periods))
    for transaction in transactions
        transaction.TimePeriod - transaction.ClearingTimePeriod >= window_length - 1 && continue
    	stack_matrix[1, transaction.TimePeriod] += .5*abs(transaction.Quantity)
    end

    # Create stacked area plot
    p3 = Plots.plot(xlabel="Time Period", ylabel="Volume Traded (MWh)",
            title="Quantities Traded (All)",
            legend=:topright)

    # Stack manually using areaplot with seriestype
    for i in 1:size(stack_matrix, 1)
        Plots.plot!(p3, time_periods, stack_matrix[i, :],
            fillrange=0, label=stack_order[i], 
            color=colors[i], alpha=0.4, linewidth=0)
    end

    display(p3)


    # Manual stacking order:
    stack_order = ["AdjustmentTradingVolumeWind"]

    # Build matrix for areaplot (row is volume traded by wind, each column is a time period)
    stack_matrix = zeros(length(stack_order), length(time_periods))
    for transaction in transactions
        if transaction.Party == "Wind"
            transaction.TimePeriod - transaction.ClearingTimePeriod >= window_length - 1 && continue
            stack_matrix[1, transaction.TimePeriod] += abs(transaction.Quantity)
        end
    end

    # Create stacked area plot
    p4 = Plots.plot(xlabel="Time Period", ylabel="Volume Traded by Wind (MWh)",
            title="Quantities Traded (Wind)",
            legend=:topright)

    # Stack manually using areaplot with seriestype
    for i in 1:size(stack_matrix, 1)
        Plots.plot!(p4, time_periods, stack_matrix[i, :],
            fillrange=0, label=stack_order[i], 
            color=colors[i], alpha=0.4, linewidth=0)
    end

    display(p4)

    return p3 
end


end;
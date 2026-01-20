module PlotTransactionVolumes

using Plots
using JuMP
using Statistics

include("../output_data/process_data.jl")
include("../helpers/helper_model_results.jl")

function plot(resultset, clearing_time_period)


    # todo, should be a graph

    time_periods = ProcessData.DispatchedTimePeriods(resultset)

	transactions = ProcessData.Transactions(resultset)

	# what window is interesting here? is this information available from the config?
	
    window_length = length(resultset[length(resultset)].TimePeriods)

    # Define consistent colors
    colors = [:steelblue, :green]

    # Manual stacking order:
    stack_order = ["Previous Dispatch", "Dispatched This Period"]

    # Build matrix for areaplot (rows are previous dispatch and current period dispatch, each column is a time period)
    stack_matrix = zeros(length(stack_order), length(time_periods))
    for transaction in transactions
    	transaction.ClearingTimePeriod > clearing_time_period && continue

    	if transaction.ClearingTimePeriod == clearing_time_period
    		stack_matrix[2, transaction.TimePeriod] += -.5*abs(transaction.Quantity) # quantity dispatched in this clearing period for each period considered, half of abs so they don't cancel each other out, subtracted so that it is shown as a portion of the total dispatched generation
    	end
		# this is all generation transactions that have happened for this period 
    	if transaction.PartyType != HelperModelResults.PARTY_DEMAND
    		stack_matrix[1, transaction.TimePeriod] += transaction.Quantity # quantity dispached in other clearing periods - half of absolute value so they don't cancel each other out
		end
        
    end

    # Create stacked area plot
    p3 = Plots.plot(xlabel="Time Period", ylabel="Volume Dispatched (MWh)",
            title="Quantities Dispatched",
            legend=:topright)

    # Stack manually using areaplot with seriestype
    for i in 1:size(stack_matrix, 1)
        if i == 1
            Plots.plot!(p3, time_periods, stack_matrix[i, :],
                fillrange=0, label=stack_order[i], 
                color=colors[i], alpha=0.4, linewidth=0)
        else
            cumsum_prev = vec(sum(stack_matrix[1:i-1, :], dims=1))
            cumsum_curr = vec(sum(stack_matrix[1:i, :], dims=1))
            Plots.plot!(p3, time_periods, cumsum_curr,
                fillrange=cumsum_prev, label=stack_order[i],
                color=colors[i], alpha=1.0, linewidth=0)
        end
    end

    Plots.xticks!(p3, [clearing_time_period],["Clearing Time"])

    display(p3)
    return p3 
end


end;
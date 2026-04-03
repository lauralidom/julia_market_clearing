module PlotComparisonImbalance

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX

include("../../output_data/process_data.jl")


# Note: perhaps it would be best to make a helper function for getting the final dispatch, and realized energy production from ST market sequence?
function plot(resultsets, variableGenRealized, timerange, test_id)
    # for now compare just the variable generator last dispatched quantity vs the variable generator last forecast value (after the last forecast, the energy production is assumed to be realized)
    realized_q = Dict{String,Vector{Float64}}()
    dispatched_q = Dict{String,Dict{String,Vector{Float64}}}()
    imbalance_q = Dict{String,Dict{String,Vector{Float64}}}()
    realized_q_total = Vector{Float64}()
    dispatched_q_total = Dict{String,Vector{Float64}}()
    imbalance_q_total = Dict{String,Vector{Float64}}()

    for (gName, gData) in variableGenRealized
        realized_q[gName] = gData # note hardcoded power to energy here - TODO: pass this parameter in
        
    end

    for (name, resultset) in resultsets
        realized_length = length(realized_q["Wind"])
        gen_dispatch_data = ProcessData.GenData(resultset)
        dispatched_q[name] = Dict{String,Vector{Float64}}()
        imbalance_q[name] = Dict{String,Vector{Float64}}()
        dispatched_q_total[name] = zeros(realized_length)
        imbalance_q_total[name] = zeros(realized_length)
        
        for (gName, gData) in variableGenRealized # ensure we have matching dispatchable generators

            dispatched_q[name][gName] = gen_dispatch_data[gName]
            dispatched_q_total[name] .+= gen_dispatch_data[gName][1:realized_length]
            imbalance_q[name][gName] = realized_q[gName] - gen_dispatch_data[gName][1:realized_length]
            imbalance_q_total[name] .+= imbalance_q[name][gName]

            dispatched_q[name][gName] = dispatched_q[name][gName][timerange]    # slice to match incoming time range
            imbalance_q[name][gName] = imbalance_q[name][gName][timerange]    # slice to match incoming time range
        end
        dispatched_q_total[name] = dispatched_q_total[name][timerange]    # slice to match incoming time range
        imbalance_q_total[name] = imbalance_q_total[name][timerange]    # slice to match incoming time range
    end


    realized_q_total = zeros(length(realized_q["Wind"]))
    for (gName, gData) in variableGenRealized
        realized_q_total .+= realized_q[gName]
        realized_q[gName] = realized_q[gName][timerange]    # slice to match incoming time range
    end
    realized_q_total = realized_q_total[timerange]



    p3 = Plots.plot(xlabel="Global Time Period (Simulation)", ylabel="VRES Imbalance",
      title="Imbalance Indicators (MWh)",
      linewidth=2,size=(1200,1200), legend=:topright)

    # Plot each clearing's imbalance indicators
    #=
    for (gName, realized_quantities) in realized_q
        # Plot imbalance indicators
        Plots.plot!(p3, 1:length(realized_quantities), realized_quantities,
            label="Realized production $gName", alpha=0.8)
        for (name, dispatched_quantities) in dispatched_q
            Plots.plot!(p3, 1:length(dispatched_quantities[gName]), dispatched_quantities[gName],
                label="Dispatched production $gName in $name", alpha=0.8)
        end
    end
    =#
    for (name, dispatched_quantities) in dispatched_q_total
        Plots.plot!(p3, 1:length(dispatched_q_total[name]), dispatched_q_total[name],
            label="Dispatched production total in $name", alpha=0.8)
    end
    Plots.plot!(p3, 1:length(realized_q_total), realized_q_total,
        label="Realized production total", alpha=0.8)

    p4 = Plots.plot(xlabel="Global Time Period (Simulation)", ylabel="VRES Imbalance",
      title="Imbalance Totals (MWh)",
      linewidth=2,size=(1200,1200), legend=:topright)

    # Plot totalimbalance indicators
    for (name, imbalance_q_t) in imbalance_q_total
        Plots.plot!(p4, 1:length(imbalance_q_t), imbalance_q_t,
            label="Imbalance total in $name", alpha=0.8)
    end

    display(p3)
    display(p4)
    savefig(p3, "../DATA/$(test_id)/realized_v_dispatched.png")
    savefig(p4, "../DATA/$(test_id)/imbalance.png")

    imbalance_df = DataFrame(Name=String[],PositiveImbalance=Float64[],NegativeImbalance=Float64[], AbsoluteImbalance=Float64[])
    for (name, imbalance_q_t) in imbalance_q_total
        push!(imbalance_df, [name, sum(clamp.(imbalance_q_t, 0.0, 60000.0)), sum(clamp.(imbalance_q_t, -60000.0, 0.0)), sum(abs.(imbalance_q_t))])
    end
    println(imbalance_df)


    XLSX.writetable("../DATA/$(test_id)/imbalance.xlsx", "sheet1" => imbalance_df)
end


end;
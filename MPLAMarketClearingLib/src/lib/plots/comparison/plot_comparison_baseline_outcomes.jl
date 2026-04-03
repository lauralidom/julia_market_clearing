module PlotComparisonBaselineOutcomes

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX

include("../../output_data/process_data.jl")

function plot(resultsets, configMap, timerange, test_id)
    indicator_set = Dict{String,Any}()
    player_indicator_set = Dict{String,Any}()
    for (name, resultset) in resultsets
        # println("get economic indicators for ", name)
        (indicators, player_indicators) = ProcessData.EconomicIndicatorsForTimeRange(resultset, timerange)
        indicator_set[name] = indicators
        player_indicator_set[name] = player_indicators
    end

    # println(indicator_set)
    # println(player_indicator_set)
    names = Vector{String}()
    for (name, indicators) in indicator_set
        # println(name)
        for (i_name, i_val) in indicators
           # println(i_name, " :: ", i_val)
        end
        push!(names,name)
    end

    # println("SEW comparison: $(names[1]) / $(names[2]) $(indicator_set[names[1]]["sew"]/indicator_set[names[2]]["sew"])")
    # println("SEW with storage comparison: $(names[1]) / $(names[2]) $((indicator_set[names[1]]["sew"] + indicator_set[names[1]]["storage_payments"])/(indicator_set[names[2]]["sew"] + indicator_set[names[1]]["storage_payments"]))")

    emissionsMap = Dict{String,Float64}()

    for (name, config) in configMap
        emissionsMap[name] = 0.0
        # println("emission factors: ", configMap[name][:dispatchableGenerators])
        # println("player indicators: ", player_indicator_set[name])
        for (emitter, eConfig) in configMap[name][:dispatchableGenerators]
            emissionsMap[name] += eConfig["emissionFactor"] * player_indicator_set[name][emitter]["quantity"]
        end

        # println("quantity emitted in $name is $(emissionsMap[name])")
    end

    overall_indicators_df = DataFrame(Name=String[], SEW=Float64[], ProducerSurplus=Float64[], ConsumerSurplus=Float64[], StoragePayments=Float64[], Emissions=Float64[])
    
    player_indicator_df = DataFrame(Name=String[], Player=String[], Quantity=Float64[], LoadValue=Float64[], Payments=Float64[], Revenue=Float64[], FuelCost=Float64[])

    for name in names
        push!(overall_indicators_df, [name, indicator_set[name]["sew"], indicator_set[name]["producer_surplus"], indicator_set[name]["consumer_surplus"], indicator_set[name]["storage_payments"], emissionsMap[name]])
    
        for (player, player_indicators) in player_indicator_set[name]
            push!(player_indicator_df, [name, player, player_indicators["quantity"], (haskey(player_indicators,"value") ? player_indicators["value"] : 0.0), (haskey(player_indicators,"payments") ? player_indicators["payments"] : 0.0), (haskey(player_indicators,"revenue") ? player_indicators["revenue"] : 0.0), (haskey(player_indicators,"cost") ? player_indicators["cost"] : 0.0)])
        end
    end

    sort!(overall_indicators_df,[:Name])
    sort!(player_indicator_df,[:Player,:Name])
    println(overall_indicators_df)
    println(player_indicator_df)

    XLSX.writetable("../DATA/$(test_id)/overall.xlsx", "sheet1" => overall_indicators_df)

    XLSX.writetable("../DATA/$(test_id)/player.xlsx", "sheet1" => player_indicator_df)

    for (name, resultset) in resultsets
           
        transaction_df = ProcessData.TransactionDataFrame(resultset)
        XLSX.writetable("../DATA/$(test_id)/transactions_$(name).xlsx", "sheet1" => transaction_df)
    end

end


end;
module PlotComparisonTableForMTU

using Plots
using JuMP
using Statistics
using DataFrames

include("../../output_data/process_data.jl")

function plot(resultsets,variableGenLastForecasts, mtu)
	# println("print results for $mtu")

	for (gName, gData) in variableGenLastForecasts
        # println("actual production for $gName in $mtu:  $(gData["profile"][mtu] * (gData["capacity"] * .25))") # note hardcoded power to energy here - TODO: pass this parameter in
    end

    mtu_comparison_df = DataFrame(Name=String[], Player=String[], Dispatched=Float64[], Realized=Float64[])

    for (name, resultset) in resultsets
    	println("Results for $name in MTU: $mtu")
        gen_dispatch_data = ProcessData.GenData(resultset)
       	demand_dispatch_data = ProcessData.DemandData(resultset)
        for (gName, gData) in gen_dispatch_data
        	# println("dispatched production for $gName: $(gen_dispatch_data[gName][mtu])")

            push!(mtu_comparison_df, [name, gName, gen_dispatch_data[gName][mtu], (haskey(variableGenLastForecasts, gName) ? variableGenLastForecasts[gName]["profile"][mtu] * (variableGenLastForecasts[gName]["capacity"] * .25) : 0.0 )])
        end
        for (dName, dData) in demand_dispatch_data
        	# println("dispatched demand for $dName: $(demand_dispatch_data[dName][mtu])") 
            push!(mtu_comparison_df, [name, dName, demand_dispatch_data[dName][mtu], 0.0])
        
        end

    end

    sort!(mtu_comparison_df,[:Player,:Name])
    println(mtu_comparison_df)
	#=
    indicator_set = Dict{String,Any}()
    for (name, resultset) in resultsets
        println("get economic indicators for ", name)
        indicators = ProcessData.EconomicIndicatorsForTimeRange(resultset, timerange)
        indicator_set[name] = indicators
    end
    
    println(indicator_set)
    names = Vector{String}()
    for (name, indicators) in indicator_set
        println(name)
        for (i_name, i_val) in indicators
            println(i_name, " :: ", i_val)
        end
        push!(names,name)
    end

    println("SEW comparison: $(names[1]) / $(names[2]) $(indicator_set[names[1]]["sew"]/indicator_set[names[2]]["sew"])")
	=#
end


end;
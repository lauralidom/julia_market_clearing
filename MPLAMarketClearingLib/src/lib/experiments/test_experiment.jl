module TestExperiment

using Dates
using Printf

include("../market_clearers/clear_market.jl")

include("../plots/comparison/plot_comparison_baseline_outcomes.jl")


function RunTest()
	CompareVRESAndFlexSizes()
	# SimpleRepeatTest()
end


function SimpleRepeatTest()

	for test_number in 1:2
		test_name = @sprintf "test_%i_%d" test_number datetime2unix(now())
		results_dir = "../DATA/$(test_name)"
		mkdir(results_dir)
		println(test_name)
		ClearMarket.ClearComparison(["MPLAMarketClearingLib/src/configs/fixed_horizon_status_quo.yaml","MPLAMarketClearingLib/src/configs/rolling_config_15_minutes.yaml"],test_name)
	end
end

function CompareVRESAndFlexSizes()
	vresScales = [.5, 1, 1.5, 2]
	flexScales = [.5, 1, 1.5, 2]

	folder_name = @sprintf "scale_test/%d" datetime2unix(now())
	mkdir("../DATA/$(folder_name)")

	all_results = Dict{String,Any}()

	for vresScale in vresScales
		for flexScale in flexScales
			test_name = @sprintf "vres_%.1f_flex_%.1f" vresScale flexScale
			println(test_name)
			mkdir("../DATA/$(folder_name)/$(test_name)")
			(resultsets, variableGenRealized, configMap) = ClearMarket.ClearComparisonWithVRESFlexScale(["MPLAMarketClearingLib/src/configs/fixed_horizon_status_quo.yaml","MPLAMarketClearingLib/src/configs/rolling_config_15_minutes.yaml"], vresScale, flexScale, "$(folder_name)/$(test_name)")
			
			test_results = Dict{String,Any}("vresScale" => vresScale, "flexScale" => flexScale, "resultsets" => resultsets, "variableGenRealized" => variableGenRealized, "configMap" => configMap)
			all_results[test_name] = test_results
		end
	end

	overall_results_dir = "../DATA/$(folder_name)/overall"
	mkdir(overall_results_dir)
	# merge results
	
	merged_results = Dict{String, Any}( "names" => Vector{String}(), "resultsets" => Dict{String,Any}(), "variableGenRealized" => Dict{String,Any}(), "configMap" => Dict{String,Any}() )

	for (test_name, result) in all_results
		for (strategy_name, resultset) in result["resultsets"]
			combined_name = "$(test_name)_$(strategy_name)"
			push!(merged_results["names"], combined_name)
			merged_results["resultsets"][combined_name] =  resultset
			merged_results["variableGenRealized"][combined_name] = result["variableGenRealized"]
			merged_results["configMap"][combined_name] = result["configMap"][strategy_name]
		end
	end
	first_config = merged_results["configMap"][merged_results["names"][1]]
	# println(first_config)
	PlotComparisonBaselineOutcomes.plot(merged_results["resultsets"], merged_results["configMap"], range(first_config[:timePeriodsPerDay]*2,first_config[:timePeriodsPerDay]*(first_config[:clearForDays] - 1)), overall_results_dir)

end

end;
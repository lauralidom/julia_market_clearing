module TestExperiment

using Dates
using Printf

include("../market_clearers/clear_market.jl")


function RunTest()

	for test_number in 1:10
		test_name = @sprintf "test_%i_%f" test_number datetime2unix(now())
		println(test_name)
		ClearMarket.ClearComparison(["MPLAMarketClearingLib/src/configs/fixed_horizon_status_quo.yaml","MPLAMarketClearingLib/src/configs/rolling_config_15_minutes.yaml"],test_name)
	end
end

end;
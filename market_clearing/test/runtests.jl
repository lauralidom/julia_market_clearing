using Test

@testset "market_clearing" begin
    include("wind_forecast_error_scenario.jl")
    include("daily_summary.jl")
end

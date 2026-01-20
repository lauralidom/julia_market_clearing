using Test
using MPLAMarketClearingLib


@testset "First test" begin
	
	@test 1 + 1 == 2
end

@testset "Transaction Tests" begin
	include("transaction_tests.jl")
end
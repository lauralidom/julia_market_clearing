include("../src/lib/helpers/helper_model_results.jl")
include("../src/lib/output_data/process_data.jl")




function countDemandTransactions(transactions)
	count = 0
	for transaction in transactions
		if transaction.PartyType == HelperModelResults.PARTY_DEMAND 
			count += 1
		end
	end
	return count
end

function countGeneratorTransactions(transactions)
	count = 0
	for transaction in transactions
		if transaction.PartyType == HelperModelResults.PARTY_GENERATOR
			count += 1
		end
	end
	return count
end

function countMatchingTransactions(transactions, matchingTransaction)
	count = 0

	for transaction in transactions
		transaction.Party != matchingTransaction.Party && continue
		transaction.Quantity != matchingTransaction.Quantity && continue
		transaction.Price != matchingTransaction.Price && continue
		transaction.TimePeriod != matchingTransaction.TimePeriod && continue
		transaction.ClearingTimePeriod != matchingTransaction.ClearingTimePeriod && continue
		transaction.PartyType != matchingTransaction.PartyType && continue
		count += 1
	end
	return count
end



@testset "Tranaction Tests 1" begin

	# GIVEN a single initial clearing period
	clearingData = ProcessData.ClearingData()
	clearingData.BaseTimePeriod = 1
	clearingData.TimePeriods = [1,2]
	clearingData.Prices = [50,60]
	clearingData.GenData = Dict{}("Wind"=> [40,50], "Base" => [30,30] )
	clearingData.BidPrices = Dict{}("Wind"=> [0,0], "Base" => [30,30], "Base_D" => [300,300], "Flex" => [50,50] )
	clearingData.DemandData = Dict{}("Base_D" => [70,70], "Flex" => [50,60] )
	clearingData.StorageDischargeQuantities = [0,0]
	clearingData.StorageChargeQuantities = [0,0]
	clearingData.StorageStateOfCharge = [50,50]
	
	# WHEN transactions are derived
	transactions = HelperModelResults.Transactions(clearingData, [])
	println(transactions)
	# THEN the transactions match expected values

	firstClearingExpectedTransactions = Vector{HelperModelResults.Transaction}([
		HelperModelResults.MakeTransaction("Wind", 40, 50, 1, 1, HelperModelResults.PARTY_GENERATOR),
		HelperModelResults.MakeTransaction("Wind", 50, 60, 2, 1, HelperModelResults.PARTY_GENERATOR),
		HelperModelResults.MakeTransaction("Base", 30, 50, 1, 1, HelperModelResults.PARTY_GENERATOR),
		HelperModelResults.MakeTransaction("Base", 30, 60, 2, 1, HelperModelResults.PARTY_GENERATOR),
		HelperModelResults.MakeTransaction("Base_D", 70, 50, 1, 1, HelperModelResults.PARTY_DEMAND),
		HelperModelResults.MakeTransaction("Base_D", 70, 60, 2, 1, HelperModelResults.PARTY_DEMAND),
		HelperModelResults.MakeTransaction("Flex", 50, 50, 1, 1, HelperModelResults.PARTY_DEMAND),
		HelperModelResults.MakeTransaction("Flex", 60, 60, 2, 1, HelperModelResults.PARTY_DEMAND)
	])

	@testset "Test First Clearing" begin
		@test length(transactions) == 8
		@test countDemandTransactions(transactions) == 4
		@test countGeneratorTransactions(transactions) == 4
		for expectedTransaction in firstClearingExpectedTransactions
			@test countMatchingTransactions(transactions, expectedTransaction) == 1
		end
	end

	# clearingData.Transactions = transactions
	

	# GIVEN a second result set that differs from the first

	resultset = [clearingData]

	clearingData2 = ProcessData.ClearingData()
	clearingData2.BaseTimePeriod = 2
	clearingData2.TimePeriods = [2,3]
	clearingData2.Prices = [65,70]
	clearingData2.GenData = Dict{}("Wind"=> [40,50], "Base" => [30,30] )
	clearingData2.BidPrices = Dict{}("Wind"=> [0,0], "Base" => [0,30], "Base_D" => [300,300], "Flex" => [50,50] )
	clearingData2.DemandData = Dict{}("Base_D" => [70,70], "Flex" => [65,50] )
	clearingData2.StorageDischargeQuantities = [0,0]
	clearingData2.StorageChargeQuantities = [0,0]
	clearingData2.StorageStateOfCharge = [50,50]

	# WHEN transactions are derived
	transactions2 = HelperModelResults.Transactions(clearingData2,resultset)

	# THEN the transactions match expected values

	secondClearingExpectedTransactions = Vector{HelperModelResults.Transaction}([
		HelperModelResults.MakeTransaction("Wind", -10, 65, 2, 2, HelperModelResults.PARTY_GENERATOR),
		HelperModelResults.MakeTransaction("Wind", 50, 70, 3, 2, HelperModelResults.PARTY_GENERATOR),
		HelperModelResults.MakeTransaction("Base", 30, 70, 3, 2, HelperModelResults.PARTY_GENERATOR),
		HelperModelResults.MakeTransaction("Base_D", 70, 70, 3, 2, HelperModelResults.PARTY_DEMAND),
		HelperModelResults.MakeTransaction("Flex", 5, 65, 2, 2, HelperModelResults.PARTY_DEMAND),
		HelperModelResults.MakeTransaction("Flex", 50, 70, 3, 2, HelperModelResults.PARTY_DEMAND)
	])

	@testset "Test Second Clearing" begin
		@test length(transactions2) == 6
		@test countDemandTransactions(transactions2) == 3
		@test countGeneratorTransactions(transactions2) == 3
		for expectedTransaction in secondClearingExpectedTransactions
			@test countMatchingTransactions(transactions2, expectedTransaction) == 1
		end
	end
end

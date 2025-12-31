module DataImporter

using YAML

# decode and reorganize/rename the input data
# Is this necessary or could the input data just already be in good shape?
# should there be try/catch style error handling around the YAML load?

function load_input_data(path::String)
    # Read the YAML file into a nested Julia Dict/Array structure
    cfg = YAML.load_file(path)

    # Internal data dictionary that we pass to the other functions
    data = Dict{Symbol,Any}()

    # time: number of hours in the representative day
    T = Int(cfg["nTimesteps"])
    data[:T] = T

    # string defining which model/strategy we want to use to clear the market
    data[:strategy] = String(cfg["strategy"])

    if data[:strategy] != "basic"
        data[:clearForDays] = Int(cfg["clearForDays"])
        data[:clearingInterval] = Int(cfg["clearingInterval"])
        data[:clearingWindow] = Int(cfg["clearingWindow"])
    end

    # generators: separate blocks for dispatchable and variable generators
    data[:dispatchableGenerators] = cfg["dispatchableGenerators"]
    data[:variableGenerators]     = get(cfg, "variableGenerators", Dict())

    # demand segments: Base and Flex demand, each with a bid and hourly quantities
    data[:demandSegments] = cfg["demand"]["segments"]

    # storage parameters
    data[:batteryStorage] = get(cfg, "batteryStorage", nothing)


    return data
end


end;
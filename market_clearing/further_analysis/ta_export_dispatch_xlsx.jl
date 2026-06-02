using Serialization
using Plots
using JuMP
using HiGHS
using DataFrames
using XLSX

const RUN_DIR = joinpath("Results", "thesis_runs", "all_20260602_114237")
const OUTPUT_DIR = joinpath(RUN_DIR, "_summary", "baseline_market_design", "ta_data_export")
const DAY_OF_MONTH = 5
const NUM_CLEARINGS_TO_SHOW = 30
const CASES = [
    ("Fixed36h", "fixed_36h"),
    ("Rolling36h", "rolling_36h"),
    ("Rolling48h", "rolling_48h"),
    ("Rolling72h", "rolling_72h"),
    ("High-storageRolling36h", "high_storage_rolling_36h"),
    ("High-storageRolling48h", "high_storage_rolling_48h"),
    ("High-storageRolling72h", "high_storage_rolling_72h"),
    ("High-storageFixed36h", "high_storage_fixed_36h"),
    ("Low-storageLowRampRates", "low_storage_low_ramp_rates"),
    ("No-storageLowRampRates", "no_storage_low_ramp_rates"),
]


function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
    return path
end

function load_saved_case(case_folder::AbstractString)
    path = joinpath(RUN_DIR, case_folder, "all_results.jls")
    isfile(path) || error("Saved result file not found: $path")
    return deserialize(path)
end


function main()
    ensure_dir(OUTPUT_DIR)
    loaded_cases = [(case_label, load_saved_case(case_folder)) for (case_label, case_folder) in CASES]
    
    #=
    first_details = loaded_cases[1][2][:clearing_details]
    clearing_indices = consecutive_clearings_from_day_start(first_details, DAY_OF_MONTH, NUM_CLEARINGS_TO_SHOW)
    length(clearing_indices) == NUM_CLEARINGS_TO_SHOW || @warn "Fewer clearings than requested" requested=NUM_CLEARINGS_TO_SHOW found=length(clearing_indices)

   
    y_max = maximum(case_day_ymax(all_results, clearing_indices) for (_, all_results) in loaded_cases)

    saved_paths = String[]
    for (case_label, all_results) in loaded_cases
        p = generation_mix_grid(all_results, case_label, clearing_indices; y_max=y_max)
        safe_case = replace(lowercase(case_label), " " => "_")
        path = joinpath(OUTPUT_DIR, "generation_mix_2025_05_05_$(safe_case)_30_clearings.png")
        savefig(p, path)
        push!(saved_paths, path)
    end

    paired = paired_generation_mix_grid(loaded_cases, clearing_indices; y_max=y_max)
    paired_path = joinpath(OUTPUT_DIR, "mix_0505_fixed_vs_rolling_36h_30_clearings.png")
    savefig(paired, paired_path)
    push!(saved_paths, paired_path)
    =#
    for (case_label, all_results) in loaded_cases
        # case_label !== "Fixed 36h" && continue
        # println("Results for: $case_label")
        clearing_indices = sort(collect(keys(all_results[:clearing_details])))
        agent_keys = keys(all_results[:dispatch][1])
        for idx in clearing_indices
            #=
            println("Results of clearing at $idx")
            println(all_results[:dispatch][idx])
            println(all_results[:prices][idx])
            =#
            # price = all_results[:prices][idx][1]
            # dispatch = ["$agent_key:$(all_results[:dispatch][idx][agent_key][1])" for agent_key in agent_keys]
            # println(idx,price,dispatch)
            offset = 11
            mtu_range = (idx+offset):(idx+offset+length(all_results[:prices][idx])-1)
            #println(all_results[:clearing_details][idx][:current_hour], all_results[:clearing_details][idx][:look_ahead], mtu_range)

            df = DataFrame(mtu=mtu_range,price=all_results[:prices][idx])

            for agent_key in agent_keys
                df[!, agent_key] = all_results[:dispatch][idx][agent_key]
            end

            add_keys = ["demand_base", "demand_flex", "charging", "discharging", "storage_soc_path"]
            for key in add_keys
                println(key, all_results[:clearing_details][idx][Symbol(key)])
                df[!, Symbol(key)] = all_results[:clearing_details][idx][Symbol(key)]
            end

            # TODO: rename and reorder the columns here

            df = df[!, ["mtu", "price", "storage_soc_path", "charging", "discharging", "demand_base", "demand_flex", "Base", "Mid", "Peak", "Wind", "Solar"]]
            rename!(df, ["storage_soc_path", "charging", "discharging", "demand_base", "demand_flex", "Mid"] .=> ["SOC", "StorageCharge", "StorageDischarge", "Base_D", "Flex", "Shoulder"])
            # println("for clearing: $idx", df)
            decision_variables_storage_path = joinpath(OUTPUT_DIR, "decisionvariables_$(case_label)_$(idx + offset).xlsx")
            
            opt_params_df = DataFrame(test=[1])
            add_param_keys = ["executed_hours", "current_hour", "storage_soc_end_window", "storage_soc_start", "storage_soc_end_executed"]
            for key in add_param_keys
                # println(key, all_results[:clearing_details][idx][Symbol(key)])
                opt_params_df[!, Symbol(key)] = [all_results[:clearing_details][idx][Symbol(key)]]
            end

            XLSX.writetable(decision_variables_storage_path, "data" => df, "opt_params" => opt_params_df)
        
        end
        # println("all keys: $(keys(all_results))")
        # println("details keys: $(keys(all_results[:clearing_details][1]))")


    end
    # println("Saved XLSX of dispatch")
    # foreach(path -> println("  ", path), saved_paths)
end

main()
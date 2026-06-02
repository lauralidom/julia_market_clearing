using Dates

include("src/thesis_runner.jl")

# Central switchboard for thesis runs.
# Toggle the booleans below to control what gets saved.
# Important: keep time handling consistent with the original model scripts.
# By default, the only time-related dimension we vary across rolling cases is
# `look_ahead`. Reclear frequency, gate closure, simulation start, and the
# fixed-horizon shrinking/reset logic stay as defined in the YAML unless you
# explicitly decide to override them.
SAVE_RESULTS = true
SAVE_EXCEL_SUMMARY = true
RUN_DAILY_DRIVER_ANALYSIS = true
SAVE_COMPARISON_PLOTS = true
DISPLAY_PLOTS = true
VERBOSE = true

# Select what to run.
# Options:
#   "baseline"      -> Fixed 36h, Rolling 36h
#   "foresight"     -> Rolling 36h, Rolling 48h, Rolling 72h
#   "high_storage"  -> High-storage Fixed 36h plus Rolling 36h/48h/72h
#   "all"           -> all thesis cases
#   "custom"        -> use CUSTOM_CASE_NAMES below
RUN_SET = "all"

# If RUN_SET = "custom", list the exact case names you want here.
CUSTOM_CASE_NAMES = [
    "No storage Low ramp rates",
]

# Shared wind forecast-error scenarios.
# Change only `ACTIVE_WIND_SCENARIO_PATH` to switch all cases to a different
# precomputed wind forecast-error file.
WIND_SCENARIO_BASELINE_PATH = "Results/thesis_runs/_shared_inputs/wind_forecast_error_shared_final_20260502.csv"
WIND_SCENARIO_SEED_B_PATH = "Results/thesis_runs/_shared_inputs/wind_forecast_error_shared_seed_20260503.csv"
WIND_SCENARIO_SEED_C_PATH = "Results/thesis_runs/_shared_inputs/wind_forecast_error_shared_seed_20260505.csv"
ACTIVE_WIND_SCENARIO_PATH = WIND_SCENARIO_BASELINE_PATH

HIGH_STORAGE_ENERGY_CAPACITY_MWH = 96000.0
HIGH_STORAGE_POWER_CAPACITY_MW = 4000.0

NO_STORAGE_ENERGY_CAPACITY_MWH = 0.0
NO_STORAGE_POWER_CAPACITY_MW = 0.0

LOW_STORAGE_ENERGY_CAPACITY_MWH = 500.0
LOW_STORAGE_POWER_CAPACITY_MW = 250.0

LOW_RAMP_RATE = .05

# Choose the cases to run editing this list
CASE_DEFS = [
    Dict(
        :name => "Fixed 36h",
        :mode => "fixed",
        :look_ahead => 36,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
    ),
    Dict(
        :name => "Rolling 36h",
        :mode => "rolling",
        :look_ahead => 36,
        :comparable_delivery_hours_override => 661,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
    ),
    Dict(
        :name => "Rolling 48h",
        :mode => "rolling",
        :look_ahead => 48,
        :comparable_delivery_hours_override => 661,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
    ),
    Dict(
        :name => "Rolling 72h",
        :mode => "rolling",
        :look_ahead => 72,
        :comparable_delivery_hours_override => 661,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
    ),
    Dict(
        :name => "High-storage Fixed 36h",
        :mode => "fixed",
        :look_ahead => 36,
        :battery_energy_capacity => HIGH_STORAGE_ENERGY_CAPACITY_MWH,
        :battery_power_capacity => HIGH_STORAGE_POWER_CAPACITY_MW,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
    ),
    Dict(
        :name => "High-storage Rolling 36h",
        :mode => "rolling",
        :look_ahead => 36,
        :comparable_delivery_hours_override => 661,
        :battery_energy_capacity => HIGH_STORAGE_ENERGY_CAPACITY_MWH,
        :battery_power_capacity => HIGH_STORAGE_POWER_CAPACITY_MW,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
    ),
    Dict(
        :name => "High-storage Rolling 48h",
        :mode => "rolling",
        :look_ahead => 48,
        :comparable_delivery_hours_override => 661,
        :battery_energy_capacity => HIGH_STORAGE_ENERGY_CAPACITY_MWH,
        :battery_power_capacity => HIGH_STORAGE_POWER_CAPACITY_MW,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
    ),
    Dict(
        :name => "High-storage Rolling 72h",
        :mode => "rolling",
        :look_ahead => 72,
        :comparable_delivery_hours_override => 661,
        :battery_energy_capacity => HIGH_STORAGE_ENERGY_CAPACITY_MWH,
        :battery_power_capacity => HIGH_STORAGE_POWER_CAPACITY_MW,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
    ),
    Dict(
        :name => "No storage Low ramp rates",
        :mode => "rolling",
        :look_ahead => 36,
        :comparable_delivery_hours_override => 661,
        :battery_energy_capacity => NO_STORAGE_ENERGY_CAPACITY_MWH,
        :battery_power_capacity => NO_STORAGE_POWER_CAPACITY_MW,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
        :ramp_rate_override => LOW_RAMP_RATE,
    ),
    Dict(
        :name => "Low storage Low ramp rates",
        :mode => "rolling",
        :look_ahead => 36,
        :comparable_delivery_hours_override => 661,
        :battery_energy_capacity => NO_STORAGE_ENERGY_CAPACITY_MWH,
        :battery_power_capacity => NO_STORAGE_POWER_CAPACITY_MW,
        :wind_noise_scenario_path => ACTIVE_WIND_SCENARIO_PATH,
        :ramp_rate_override => LOW_RAMP_RATE,
    ),
]

function selected_case_defs(run_set::AbstractString, case_defs)
    if run_set == "baseline"
        wanted = Set(["Fixed 36h", "Rolling 36h"])
    elseif run_set == "foresight"
        wanted = Set(["Rolling 36h", "Rolling 48h", "Rolling 72h"])
    elseif run_set == "high_storage"
        wanted = Set([
            "High-storage Fixed 36h",
            "High-storage Rolling 36h",
            "High-storage Rolling 48h",
            "High-storage Rolling 72h",
        ])
    elseif run_set == "all"
        return case_defs
    elseif run_set == "custom"
        wanted = Set(CUSTOM_CASE_NAMES)
    else
        error("Unknown RUN_SET: $run_set")
    end

    return [case_def for case_def in case_defs if case_def[:name] in wanted]
end

function selected_comparison_groups(run_set::AbstractString)
    if run_set == "baseline"
        return ["baseline"]
    elseif run_set == "foresight"
        return ["foresight"]
    elseif run_set == "high_storage"
        return ["high_storage"]
    elseif run_set == "all"
        return ["baseline", "foresight", "high_storage", "all_scenarios"]
    elseif run_set == "custom"
        return String[]
    else
        error("Unknown RUN_SET: $run_set")
    end
end

function main()
    cases_to_run = selected_case_defs(RUN_SET, CASE_DEFS)
    isempty(cases_to_run) && error("No cases selected for RUN_SET=$(RUN_SET).")
    comparison_groups = selected_comparison_groups(RUN_SET)
    timestamp = Dates.format(now(), dateformat"yyyymmdd_HHMMSS")
    output_root = joinpath("Results", "thesis_runs", "$(RUN_SET)_$(timestamp)")

    results = run_thesis_cases(
        cases_to_run;
        cfg_path="input_data_rolling.yaml",
        output_root=output_root,
        save_results=SAVE_RESULTS,
        save_excel_summary=SAVE_EXCEL_SUMMARY,
        run_daily_driver_analysis=RUN_DAILY_DRIVER_ANALYSIS,
        save_comparison_plots=SAVE_COMPARISON_PLOTS && !isempty(comparison_groups),
        comparison_groups=comparison_groups,
        display_plots=DISPLAY_PLOTS,
        verbose=VERBOSE,
    )

    println()
    println("Thesis run complete.")
    println("Summary KPI table: $(results[:kpi_path])")
    println("Computation summary table: $(results[:computation_path])")
    println("Computation report: $(results[:computation_report_path])")
    println("Daily summary workbook: $(results[:daily_summary_path])")
    if RUN_DAILY_DRIVER_ANALYSIS && !isempty(results[:daily_driver_analysis])
        println("Daily driver analysis folder: $(results[:daily_driver_analysis][:output_root])")
    end
    println("Summary folder: $(results[:summary_dir])")
end

main()

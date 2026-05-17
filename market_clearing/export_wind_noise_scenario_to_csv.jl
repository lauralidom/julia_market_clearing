using CSV
using DataFrames

function export_wind_noise_scenario_to_csv(
    scenario_path::AbstractString = joinpath("Results", "thesis_runs", "_shared_inputs", "wind_forecast_error_shared_final_20260502.csv");
    metadata_csv_path::AbstractString = joinpath("Results", "thesis_runs", "_shared_inputs", "wind_forecast_error_shared_final_20260502_metadata.csv"),
)
    isfile(scenario_path) || error("Scenario file not found: $scenario_path")

    df = CSV.read(scenario_path, DataFrame)
    required_cols = [:window_start_hour, :abs_hour, :lead_time, :forecast_error]
    for col in required_cols
        hasproperty(df, col) || error("Scenario CSV missing required column: $(String(col))")
    end

    nrows = nrow(df)
    min_window_start = minimum(df.window_start_hour)
    max_window_start = maximum(df.window_start_hour)
    min_abs_hour = minimum(df.abs_hour)
    max_abs_hour = maximum(df.abs_hour)
    min_lead = minimum(df.lead_time)
    max_lead = maximum(df.lead_time)

    metadata = DataFrame(
        key = ["mode", "num_rows", "min_window_start_hour", "max_window_start_hour", "min_abs_hour", "max_abs_hour", "min_lead_time", "max_lead_time", "scenario_csv"],
        value = [
            "predefined",
            string(nrows),
            string(min_window_start),
            string(max_window_start),
            string(min_abs_hour),
            string(max_abs_hour),
            string(min_lead),
            string(max_lead),
            scenario_path,
        ],
    )

    CSV.write(metadata_csv_path, metadata)

    println("Export complete")
    println("Scenario CSV: " * scenario_path)
    println("Metadata CSV: " * metadata_csv_path)
    println("Rows: " * string(nrows))

    return (rows=nrows, metadata_csv=metadata_csv_path)
end

if abspath(PROGRAM_FILE) == @__FILE__
    export_wind_noise_scenario_to_csv()
end

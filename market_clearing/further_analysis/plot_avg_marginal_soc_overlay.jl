using Serialization
using JuMP
using Plots

const RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260320_205737_withstoragestory")
const CASE_FOLDERS = Dict(
    "Fixed 36h" => "fixed_36h",
    "Rolling 36h" => "rolling_36h",
)
const OUTPUT_PATH = joinpath(
    RUN_DIR,
    "_summary",
    "baseline_market_design",
    "baseline_03_avg_marginal_soc_value_overlay_line.png",
)

function load_case(run_dir::AbstractString, case_folder::AbstractString)
    case_dir = joinpath(run_dir, case_folder)
    return deserialize(joinpath(case_dir, "all_results.jls"))
end

function collect_avg_marginal_soc_value_by_hour(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    totals = zeros(Float64, 24)
    counts = zeros(Int, 24)

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        hour_of_day = mod(details[:current_hour] - 1, 24) + 1
        marginal_value = -details[:storage_initial_soc_dual]
        totals[hour_of_day] += marginal_value
        counts[hour_of_day] += 1
    end

    return [counts[h] > 0 ? totals[h] / counts[h] : 0.0 for h in 1:24]
end

function main()
    isdir(RUN_DIR) || error("Run directory not found: $RUN_DIR")
    mkpath(dirname(OUTPUT_PATH))

    fixed_values = collect_avg_marginal_soc_value_by_hour(load_case(RUN_DIR, CASE_FOLDERS["Fixed 36h"]))
    rolling_values = collect_avg_marginal_soc_value_by_hour(load_case(RUN_DIR, CASE_FOLDERS["Rolling 36h"]))
    hours = 1:24

    p = plot(
        hours,
        fixed_values;
        label="Fixed 36h",
        xlabel="Hour of Day",
        ylabel="EUR/MWh",
        title="Average Marginal Value of Initial SOC by Hour of Day",
        color=:steelblue,
        linewidth=3,
        marker=:circle,
        markersize=4,
        xlims=(1, 24),
        size=(1100, 500),
        legend=:topright,
    )
    plot!(
        p,
        hours,
        rolling_values;
        label="Rolling 36h",
        color=:darkorange,
        linewidth=3,
        marker=:diamond,
        markersize=4,
    )

    savefig(p, OUTPUT_PATH)
    println("Saved overlay line plot to: $OUTPUT_PATH")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

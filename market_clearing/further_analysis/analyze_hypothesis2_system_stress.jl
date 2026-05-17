using CSV
using DataFrames
using Dates
using Plots
using Printf
using Statistics
using StatsPlots

const DEFAULT_OUTPUT_STAMP = Dates.format(now(), "yyyymmdd_HHMMSS")
const PRICE_THRESHOLDS = [50.0, 75.0, 100.0, 125.0]
const CASE_SPECS = [
    (
        case_name = "Rolling 36h",
        battery_group = "Baseline battery",
        look_ahead_h = 36,
        run_dir = joinpath("Results", "thesis_runs", "foresight_20260323_234223_used"),
        hourly_csv_candidates = [
            joinpath("_hypothesis_analysis", "executed_hourly_metrics.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260323.csv"),
        ],
    ),
    (
        case_name = "Rolling 48h",
        battery_group = "Baseline battery",
        look_ahead_h = 48,
        run_dir = joinpath("Results", "thesis_runs", "foresight_20260323_234223_used"),
        hourly_csv_candidates = [
            joinpath("_hypothesis_analysis", "executed_hourly_metrics.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260323.csv"),
        ],
    ),
    (
        case_name = "Rolling 72h",
        battery_group = "Baseline battery",
        look_ahead_h = 72,
        run_dir = joinpath("Results", "thesis_runs", "foresight_20260323_234223_used"),
        hourly_csv_candidates = [
            joinpath("_hypothesis_analysis", "executed_hourly_metrics.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260323.csv"),
        ],
    ),
    (
        case_name = "High-storage Rolling 36h",
        battery_group = "Large battery",
        look_ahead_h = 36,
        run_dir = joinpath("Results", "thesis_runs", "high_storage_20260321_140630_used"),
        hourly_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_executed_hour_metrics.csv"),
        ],
    ),
    (
        case_name = "High-storage Rolling 48h",
        battery_group = "Large battery",
        look_ahead_h = 48,
        run_dir = joinpath("Results", "thesis_runs", "high_storage_20260321_140630_used"),
        hourly_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_executed_hour_metrics.csv"),
        ],
    ),
    (
        case_name = "High-storage Rolling 72h",
        battery_group = "Large battery",
        look_ahead_h = 72,
        run_dir = joinpath("Results", "thesis_runs", "high_storage_20260321_140630_used"),
        hourly_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_executed_hour_metrics.csv"),
        ],
    ),
]

const CASE_COLORS = Dict(
    "Rolling 36h" => RGB(0.153, 0.396, 0.545),
    "Rolling 48h" => RGB(0.878, 0.490, 0.000),
    "Rolling 72h" => RGB(0.145, 0.627, 0.333),
    "High-storage Rolling 36h" => RGB(0.694, 0.215, 0.153),
    "High-storage Rolling 48h" => RGB(0.475, 0.318, 0.635),
    "High-storage Rolling 72h" => RGB(0.447, 0.427, 0.102),
)

default(
    guidefontsize = 14,
    tickfontsize = 10,
    titlefontsize = 16,
    legendfontsize = 9,
)

function find_existing_file(run_dir::AbstractString, rel_candidates::Vector{String})
    for rel_path in rel_candidates
        path = joinpath(run_dir, rel_path)
        if isfile(path)
            return path
        end
    end
    error("None of the expected files exist under $run_dir: $(join(rel_candidates, ", "))")
end

function normalize_column_names!(df::DataFrame)
    rename!(df, Dict(name => Symbol(lowercase(strip(String(name)))) for name in names(df)))
    return df
end

function round_up_to_step(x::Real, step::Real)
    return step * ceil(x / step)
end

function empirical_quantile(values::AbstractVector{<:Real}, p::Real)
    x = sort(collect(values))
    isempty(x) && return NaN
    idx = clamp(Int(ceil(p * length(x))), 1, length(x))
    return Float64(x[idx])
end

function load_case_hourly(spec)
    hourly_path = find_existing_file(spec.run_dir, spec.hourly_csv_candidates)
    hourly_df = CSV.read(hourly_path, DataFrame) |> normalize_column_names!
    case_df = filter(row -> String(row.case_name) == spec.case_name, hourly_df)
    isempty(case_df) && error("No hourly rows found for $(spec.case_name) in $hourly_path")

    sort!(case_df, :global_hour)
    case_df = unique(case_df, :global_hour)

    if !(:mid_peak in names(case_df))
        case_df[!, :mid_peak] = Float64.(case_df.mid) .+ Float64.(case_df.peak)
    end
    if !(:thermal_dispatch in names(case_df))
        case_df[!, :thermal_dispatch] = Float64.(case_df.base) .+ Float64.(case_df.mid) .+ Float64.(case_df.peak)
    end

    # Proxy because residual load is not directly stored.
    case_df[!, :gross_residual_load_proxy] =
        Float64.(case_df.total_demand) .- Float64.(case_df.wind) .- Float64.(case_df.solar)
    case_df[!, :net_residual_load_proxy] =
        Float64.(case_df.total_demand) .+ Float64.(case_df.charge) .- Float64.(case_df.discharge) .-
        Float64.(case_df.wind) .- Float64.(case_df.solar)

    case_df[!, :battery_group] .= spec.battery_group
    case_df[!, :look_ahead_h] .= spec.look_ahead_h

    return case_df, hourly_path
end

function choose_thresholds(all_hourly::DataFrame)
    positive_curt = all_hourly.wind_curtailment[all_hourly.wind_curtailment .> 1e-9]
    mid_peak_q90 = empirical_quantile(all_hourly.mid_peak, 0.90)
    mid_peak_q95 = empirical_quantile(all_hourly.mid_peak, 0.95)
    curt_q75 = empirical_quantile(positive_curt, 0.75)
    curt_q90 = empirical_quantile(positive_curt, 0.90)

    return (
        mid_peak = [
            round_up_to_step(mid_peak_q90, 250.0),
            round_up_to_step(mid_peak_q95, 250.0),
            round_up_to_step(max(mid_peak_q95 * 1.75, 2500.0), 500.0),
        ],
        curtailment = [
            0.0,
            round_up_to_step(curt_q75, 500.0),
            round_up_to_step(curt_q90, 500.0),
        ],
        metadata = DataFrame(
            metric = [
                "mid_peak_dispatch",
                "mid_peak_dispatch",
                "mid_peak_dispatch",
                "wind_curtailment",
                "wind_curtailment",
                "wind_curtailment",
            ],
            threshold_label = [
                "q90 rounded",
                "q95 rounded",
                "high rounded",
                ">0",
                "positive q75 rounded",
                "positive q90 rounded",
            ],
            threshold_value = [
                round_up_to_step(mid_peak_q90, 250.0),
                round_up_to_step(mid_peak_q95, 250.0),
                round_up_to_step(max(mid_peak_q95 * 1.75, 2500.0), 500.0),
                0.0,
                round_up_to_step(curt_q75, 500.0),
                round_up_to_step(curt_q90, 500.0),
            ],
            threshold_basis = [
                "Pooled 90th percentile across all six cases",
                "Pooled 95th percentile across all six cases",
                "High-stress rounded level above pooled q95",
                "Any positive curtailment",
                "Pooled 75th percentile among positive curtailment hours",
                "Pooled 90th percentile among positive curtailment hours",
            ],
        ),
    )
end

function build_duration_curve_df(case_df::DataFrame, value_col::Symbol)
    sorted_vals = sort(Float64.(case_df[!, value_col]), rev = true)
    return DataFrame(
        case_name = fill(String(first(case_df.case_name)), length(sorted_vals)),
        battery_group = fill(String(first(case_df.battery_group)), length(sorted_vals)),
        look_ahead_h = fill(Int(first(case_df.look_ahead_h)), length(sorted_vals)),
        rank = collect(1:length(sorted_vals)),
        share_of_hours = collect(1:length(sorted_vals)) ./ length(sorted_vals),
        value = sorted_vals,
        metric = fill(String(value_col), length(sorted_vals)),
    )
end

function summarize_case(case_df::DataFrame)
    n = nrow(case_df)
    return (
        case_name = String(first(case_df.case_name)),
        battery_group = String(first(case_df.battery_group)),
        look_ahead_h = Int(first(case_df.look_ahead_h)),
        hours = n,
        mean_price = mean(case_df.price),
        p90_price = empirical_quantile(case_df.price, 0.90),
        max_price = maximum(case_df.price),
        mean_curtailment = mean(case_df.wind_curtailment),
        positive_curtailment_share = count(>(1e-9), case_df.wind_curtailment) / n,
        mean_mid_dispatch = mean(case_df.mid),
        mean_peak_dispatch = mean(case_df.peak),
        mean_mid_peak_dispatch = mean(case_df.mid_peak),
        p90_mid_peak_dispatch = empirical_quantile(case_df.mid_peak, 0.90),
        max_mid_peak_dispatch = maximum(case_df.mid_peak),
        mean_thermal_dispatch = mean(case_df.thermal_dispatch),
        p90_thermal_dispatch = empirical_quantile(case_df.thermal_dispatch, 0.90),
        mean_gross_residual_load_proxy = mean(case_df.gross_residual_load_proxy),
        p90_gross_residual_load_proxy = empirical_quantile(case_df.gross_residual_load_proxy, 0.90),
        mean_net_residual_load_proxy = mean(case_df.net_residual_load_proxy),
        p90_net_residual_load_proxy = empirical_quantile(case_df.net_residual_load_proxy, 0.90),
    )
end

function stress_count_rows(case_df::DataFrame, thresholds)
    rows = NamedTuple[]
    n = nrow(case_df)

    for threshold in PRICE_THRESHOLDS
        count_hours = count(>(threshold), case_df.price)
        push!(rows, (
            case_name = String(first(case_df.case_name)),
            battery_group = String(first(case_df.battery_group)),
            look_ahead_h = Int(first(case_df.look_ahead_h)),
            metric = "price",
            threshold = threshold,
            threshold_label = "price_gt_$(Int(round(threshold)))",
            count_hours = count_hours,
            share_hours = count_hours / n,
        ))
    end

    for threshold in thresholds.mid_peak
        count_hours = count(>(threshold), case_df.mid_peak)
        push!(rows, (
            case_name = String(first(case_df.case_name)),
            battery_group = String(first(case_df.battery_group)),
            look_ahead_h = Int(first(case_df.look_ahead_h)),
            metric = "mid_peak_dispatch",
            threshold = threshold,
            threshold_label = "mid_peak_gt_$(Int(round(threshold)))",
            count_hours = count_hours,
            share_hours = count_hours / n,
        ))
    end

    for threshold in thresholds.curtailment
        count_hours = threshold <= 0 ? count(>(1e-9), case_df.wind_curtailment) : count(>(threshold), case_df.wind_curtailment)
        label_suffix = threshold <= 0 ? "positive" : string(Int(round(threshold)))
        push!(rows, (
            case_name = String(first(case_df.case_name)),
            battery_group = String(first(case_df.battery_group)),
            look_ahead_h = Int(first(case_df.look_ahead_h)),
            metric = "wind_curtailment",
            threshold = threshold,
            threshold_label = "curtailment_gt_$(label_suffix)",
            count_hours = count_hours,
            share_hours = count_hours / n,
        ))
    end

    return rows
end

function stress_plot_df(stress_counts_df::DataFrame)
    chosen = Set(["price_gt_100", "mid_peak_gt_1750", "curtailment_gt_3000"])
    filtered = filter(row -> row.threshold_label in chosen, stress_counts_df)
    if nrow(filtered) == 0
        chosen = Set(unique(stress_counts_df.threshold_label)[1:min(3, nrow(stress_counts_df))])
        filtered = filter(row -> row.threshold_label in chosen, stress_counts_df)
    end
    return filtered
end

function save_plot_safe(plot_obj, output_path::AbstractString)
    mkpath(dirname(output_path))
    savefig(plot_obj, output_path)
    return output_path
end

function plot_duration_curves(duration_df::DataFrame, metric_name::AbstractString, title_prefix::AbstractString, output_path::AbstractString)
    panels = Any[]
    for group_name in ("Baseline battery", "Large battery")
        subset = filter(row -> row.battery_group == group_name && row.metric == metric_name, duration_df)
        p = plot(
            xlabel = "Share of hours",
            ylabel = metric_name == "price" ? "EUR/MWh" : "MW",
            title = "$title_prefix: $group_name",
            xlim = (0, 1),
        )
        for case_name in sort(unique(subset.case_name), by = name -> parse(Int, match(r"(36|48|72)", name).match))
            case_df = filter(row -> row.case_name == case_name, subset)
            plot!(
                p,
                case_df.share_of_hours,
                case_df.value,
                label = case_name,
                color = get(CASE_COLORS, case_name, :steelblue),
                linewidth = 2.3,
            )
        end
        push!(panels, p)
    end

    combined = plot(panels..., layout = (1, 2), size = (1200, 420))
    save_plot_safe(combined, output_path)
end

function plot_density_panels(all_hourly::DataFrame, metric::Symbol, output_path::AbstractString; title_prefix::AbstractString, xlabel_text::AbstractString, positive_only::Bool = false)
    panels = Any[]
    for group_name in ("Baseline battery", "Large battery")
        subset = filter(row -> row.battery_group == group_name, all_hourly)
        p = plot(xlabel = xlabel_text, ylabel = "Density", title = "$title_prefix: $group_name")
        for case_name in sort(unique(subset.case_name), by = name -> parse(Int, match(r"(36|48|72)", name).match))
            case_df = filter(row -> row.case_name == case_name, subset)
            vals = Float64.(case_df[!, metric])
            vals = positive_only ? vals[vals .> 1e-9] : vals
            if isempty(vals)
                continue
            end
            density!(
                p,
                vals,
                label = case_name,
                color = get(CASE_COLORS, case_name, :steelblue),
                linewidth = 2.0,
            )
        end
        push!(panels, p)
    end
    combined = plot(panels..., layout = (1, 2), size = (1200, 420))
    save_plot_safe(combined, output_path)
end

function plot_stress_counts(stress_df::DataFrame, output_path::AbstractString)
    filtered = stress_plot_df(stress_df)
    case_order = [
        "Rolling 36h", "Rolling 48h", "Rolling 72h",
        "High-storage Rolling 36h", "High-storage Rolling 48h", "High-storage Rolling 72h",
    ]
    metric_order = unique(filtered.threshold_label)
    mat = zeros(Float64, length(case_order), length(metric_order))

    for (i, case_name) in enumerate(case_order), (j, metric_label) in enumerate(metric_order)
        subset = filter(row -> row.case_name == case_name && row.threshold_label == metric_label, filtered)
        mat[i, j] = isempty(subset) ? NaN : subset.count_hours[1]
    end

    p = groupedbar(
        case_order,
        mat,
        bar_position = :dodge,
        xlabel = "Case",
        ylabel = "Stress hours",
        title = "Stress-Hour Counts by Case",
        label = metric_order,
        xrotation = 20,
        size = (1200, 500),
    )
    save_plot_safe(p, output_path)
end

function build_interpretation(summary_df::DataFrame, stress_counts_df::DataFrame, thresholds_df::DataFrame)
    lines = String[]
    push!(lines, "# Hypothesis 2 Stress-Regime Assessment")
    push!(lines, "")
    push!(lines, "Claim tested: the large battery lowers system stress enough that extending foresight from 36h to 48h to 72h has less room to improve outcomes.")
    push!(lines, "")
    push!(lines, "## Method")
    push!(lines, "- Used only existing executed-hour outputs from the baseline and high-storage result folders.")
    push!(lines, "- Compared price duration curves, `Mid+Peak` duration curves, curtailment distributions, thermal dispatch distributions, and proxy residual-load distributions.")
    push!(lines, "- Residual load is not stored directly, so I used two proxies from existing hourly outputs:")
    push!(lines, "  `gross_residual_load_proxy = total_demand - wind - solar` and `net_residual_load_proxy = total_demand + charge - discharge - wind - solar = base + mid + peak`.")
    push!(lines, "- Stress-hour thresholds for `Mid+Peak` dispatch and curtailment are empirical and pooled across all six cases; price thresholds are fixed at 50, 75, 100, 125 EUR/MWh.")
    push!(lines, "")
    push!(lines, "## Thresholds used")
    for row in eachrow(thresholds_df)
        push!(lines, @sprintf("- %s | %s | %.1f | %s", row.metric, row.threshold_label, row.threshold_value, row.threshold_basis))
    end

    baseline36 = filter(row -> row.case_name == "Rolling 36h", summary_df)[1, :]
    large36 = filter(row -> row.case_name == "High-storage Rolling 36h", summary_df)[1, :]
    baseline72 = filter(row -> row.case_name == "Rolling 72h", summary_df)[1, :]
    large72 = filter(row -> row.case_name == "High-storage Rolling 72h", summary_df)[1, :]

    mid_peak_rows = filter(row -> row.metric == "mid_peak_dispatch", thresholds_df)
    curtailment_rows = filter(row -> row.metric == "wind_curtailment" && row.threshold_value > 0, thresholds_df)
    sort!(mid_peak_rows, :threshold_value)
    sort!(curtailment_rows, :threshold_value)
    mid_peak_focus = "mid_peak_gt_$(Int(round(mid_peak_rows.threshold_value[min(2, nrow(mid_peak_rows))])))"
    curtailment_focus_val = curtailment_rows.threshold_value[1]
    curtailment_focus = "curtailment_gt_$(Int(round(curtailment_focus_val)))"

    function count_for(case_name, label)
        subset = filter(row -> row.case_name == case_name && row.threshold_label == label, stress_counts_df)
        return subset.count_hours[1]
    end

    push!(lines, "")
    push!(lines, "## Key descriptive results")
    push!(lines, @sprintf("- Baseline 36h vs Large 36h: average price falls from %.2f to %.2f EUR/MWh, mean curtailment from %.1f to %.1f MWh/h, and mean `Mid+Peak` dispatch from %.1f to %.1f MW.", baseline36.mean_price, large36.mean_price, baseline36.mean_curtailment, large36.mean_curtailment, baseline36.mean_mid_peak_dispatch, large36.mean_mid_peak_dispatch))
    push!(lines, @sprintf("- Within the baseline battery runs, mean price moves from %.2f (36h) to %.2f (72h) EUR/MWh and mean `Mid+Peak` dispatch from %.1f to %.1f MW.", baseline36.mean_price, baseline72.mean_price, baseline36.mean_mid_peak_dispatch, baseline72.mean_mid_peak_dispatch))
    push!(lines, @sprintf("- Within the large-battery runs, mean price moves from %.2f (36h) to %.2f (72h) EUR/MWh and mean `Mid+Peak` dispatch from %.1f to %.1f MW.", large36.mean_price, large72.mean_price, large36.mean_mid_peak_dispatch, large72.mean_mid_peak_dispatch))
    push!(lines, @sprintf("- High-price hours above 100 EUR/MWh: baseline 36h = %d, baseline 72h = %d, large 36h = %d, large 72h = %d.", count_for("Rolling 36h", "price_gt_100"), count_for("Rolling 72h", "price_gt_100"), count_for("High-storage Rolling 36h", "price_gt_100"), count_for("High-storage Rolling 72h", "price_gt_100")))
    push!(lines, @sprintf("- High `Mid+Peak` hours above %.0f MW: baseline 36h = %d, baseline 72h = %d, large 36h = %d, large 72h = %d.", mid_peak_rows.threshold_value[min(2, nrow(mid_peak_rows))], count_for("Rolling 36h", mid_peak_focus), count_for("Rolling 72h", mid_peak_focus), count_for("High-storage Rolling 36h", mid_peak_focus), count_for("High-storage Rolling 72h", mid_peak_focus)))
    push!(lines, @sprintf("- High-curtailment hours above %.0f MWh: baseline 36h = %d, baseline 72h = %d, large 36h = %d, large 72h = %d.", curtailment_focus_val, count_for("Rolling 36h", curtailment_focus), count_for("Rolling 72h", curtailment_focus), count_for("High-storage Rolling 36h", curtailment_focus), count_for("High-storage Rolling 72h", curtailment_focus)))

    push!(lines, "")
    push!(lines, "## Interpretation")
    push!(lines, "- Descriptively, the large battery pushes the system into a much less stressed regime than the baseline battery: lower prices, far lower curtailment, and lower reliance on `Mid+Peak` thermal generation across nearly the full duration curves.")
    push!(lines, "- The horizon effect inside each battery size is much smaller than the battery-size effect across battery sizes, especially for curtailment and thermal-stress metrics.")
    push!(lines, "- That pattern supports Hypothesis 2 in a descriptive sense: once storage is large, extra foresight appears to have less room to improve stress outcomes.")
    push!(lines, "- This is not a causal proof. Battery size and foresight are both changing solved dispatch outcomes, and these post-processed comparisons do not isolate mechanisms.")
    push!(lines, "- Main caveats: residual load is proxied rather than directly stored, thresholds for `Mid+Peak` and curtailment are empirical rather than structural, and stress metrics do not capture all welfare-relevant effects.")

    return join(lines, "\n")
end

function main()
    output_dir = joinpath("Results", "thesis_runs", "hypothesis2_system_stress_analysis_$DEFAULT_OUTPUT_STAMP")
    mkpath(output_dir)

    all_hourly = DataFrame()
    source_rows = NamedTuple[]

    for spec in CASE_SPECS
        case_df, source_path = load_case_hourly(spec)
        append!(all_hourly, case_df, cols = :union)
        push!(source_rows, (
            case_name = spec.case_name,
            battery_group = spec.battery_group,
            look_ahead_h = spec.look_ahead_h,
            source_path = source_path,
        ))
    end

    thresholds = choose_thresholds(all_hourly)

    summary_rows = NamedTuple[]
    stress_rows = NamedTuple[]
    duration_rows = NamedTuple[]

    for spec in CASE_SPECS
        case_df = filter(row -> row.case_name == spec.case_name, all_hourly)
        push!(summary_rows, summarize_case(case_df))
        append!(stress_rows, stress_count_rows(case_df, thresholds))
        append!(duration_rows, Tables.rowtable(build_duration_curve_df(case_df, :price)))
        append!(duration_rows, Tables.rowtable(build_duration_curve_df(case_df, :mid_peak)))
    end

    summary_df = DataFrame(summary_rows)
    sort!(summary_df, [:battery_group, :look_ahead_h])
    stress_counts_df = DataFrame(stress_rows)
    sort!(stress_counts_df, [:metric, :threshold, :battery_group, :look_ahead_h])
    duration_df = DataFrame(duration_rows)

    CSV.write(joinpath(output_dir, "hypothesis2_summary_metrics.csv"), summary_df)
    CSV.write(joinpath(output_dir, "hypothesis2_stress_thresholds.csv"), thresholds.metadata)
    CSV.write(joinpath(output_dir, "hypothesis2_stress_hour_counts.csv"), stress_counts_df)
    CSV.write(joinpath(output_dir, "hypothesis2_duration_curves.csv"), duration_df)
    CSV.write(joinpath(output_dir, "hypothesis2_hourly_metrics.csv"), all_hourly)
    CSV.write(joinpath(output_dir, "hypothesis2_input_sources.csv"), DataFrame(source_rows))

    plot_duration_curves(duration_df, "price", "Price Duration Curves", joinpath(output_dir, "hypothesis2_price_duration_curves.png"))
    plot_duration_curves(duration_df, "mid_peak", "Mid+Peak Duration Curves", joinpath(output_dir, "hypothesis2_mid_peak_duration_curves.png"))
    plot_density_panels(all_hourly, :wind_curtailment, joinpath(output_dir, "hypothesis2_curtailment_density.png"); title_prefix = "Curtailment Density", xlabel_text = "Curtailment (MWh/h)", positive_only = true)
    plot_density_panels(all_hourly, :thermal_dispatch, joinpath(output_dir, "hypothesis2_thermal_dispatch_density.png"); title_prefix = "Thermal Dispatch Density", xlabel_text = "Thermal dispatch (MW)")
    plot_density_panels(all_hourly, :gross_residual_load_proxy, joinpath(output_dir, "hypothesis2_gross_residual_load_proxy_density.png"); title_prefix = "Gross Residual Load Proxy Density", xlabel_text = "Gross residual-load proxy (MW)")
    plot_stress_counts(stress_counts_df, joinpath(output_dir, "hypothesis2_stress_hour_counts.png"))

    interpretation = build_interpretation(summary_df, stress_counts_df, thresholds.metadata)
    write(joinpath(output_dir, "hypothesis2_system_stress_summary.md"), interpretation)

    println("Saved Hypothesis 2 system-stress analysis to: $(abspath(output_dir))")
    println("Summary table: $(joinpath(output_dir, "hypothesis2_summary_metrics.csv"))")
    println("Markdown summary: $(joinpath(output_dir, "hypothesis2_system_stress_summary.md"))")
end

main()

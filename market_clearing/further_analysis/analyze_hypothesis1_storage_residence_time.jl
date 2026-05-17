using CSV
using DataFrames
using Dates
using Plots
using Printf
using Statistics

const THRESHOLDS_H = [6, 12, 24, 36, 48, 72]
const EPS = 1e-9
const DEFAULT_OUTPUT_STAMP = Dates.format(now(), "yyyymmdd_HHMMSS")
const FORESIGHT_RUN_NAME = "foresight_20260509_145432"
const HIGH_STORAGE_RUN_NAME = "high_storage_20260509_192818"
const CASE_SPECS = [
    (
        case_name = "Rolling 36h",
        battery_group = "Baseline battery",
        look_ahead_h = 36,
        run_dir = joinpath("Results", "thesis_runs", FORESIGHT_RUN_NAME),
        hourly_csv_candidates = [
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260509.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260323.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics.csv"),
        ],
        diagnostics_csv_candidates = [
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics_20260509.csv"),
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics.csv"),
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics_20260323.csv"),
        ],
    ),
    (
        case_name = "Rolling 48h",
        battery_group = "Baseline battery",
        look_ahead_h = 48,
        run_dir = joinpath("Results", "thesis_runs", FORESIGHT_RUN_NAME),
        hourly_csv_candidates = [
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260509.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260323.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics.csv"),
        ],
        diagnostics_csv_candidates = [
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics_20260509.csv"),
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics.csv"),
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics_20260323.csv"),
        ],
    ),
    (
        case_name = "Rolling 72h",
        battery_group = "Baseline battery",
        look_ahead_h = 72,
        run_dir = joinpath("Results", "thesis_runs", FORESIGHT_RUN_NAME),
        hourly_csv_candidates = [
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260509.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics_20260323.csv"),
            joinpath("_hypothesis_analysis", "executed_hourly_metrics.csv"),
        ],
        diagnostics_csv_candidates = [
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics_20260509.csv"),
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics.csv"),
            joinpath("_hypothesis_analysis", "clearing_hypothesis_metrics_20260323.csv"),
        ],
    ),
    (
        case_name = "High-storage Rolling 36h",
        battery_group = "Large battery",
        look_ahead_h = 36,
        run_dir = joinpath("Results", "thesis_runs", HIGH_STORAGE_RUN_NAME),
        hourly_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_executed_hour_metrics.csv"),
        ],
        diagnostics_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_clearing_diagnostics.csv"),
        ],
    ),
    (
        case_name = "High-storage Rolling 48h",
        battery_group = "Large battery",
        look_ahead_h = 48,
        run_dir = joinpath("Results", "thesis_runs", HIGH_STORAGE_RUN_NAME),
        hourly_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_executed_hour_metrics.csv"),
        ],
        diagnostics_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_clearing_diagnostics.csv"),
        ],
    ),
    (
        case_name = "High-storage Rolling 72h",
        battery_group = "Large battery",
        look_ahead_h = 72,
        run_dir = joinpath("Results", "thesis_runs", HIGH_STORAGE_RUN_NAME),
        hourly_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_executed_hour_metrics.csv"),
        ],
        diagnostics_csv_candidates = [
            joinpath("_large_storage_hypothesis_analysis", "large_storage_clearing_diagnostics.csv"),
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
    guidefontsize = 10,
    tickfontsize = 9,
    titlefontsize = 11,
    legendfontsize = 9,
    size = (1100, 650),
)

mutable struct EnergyPacket
    charge_hour::Union{Int, Missing}
    energy_in_soc::Float64
    source::Symbol
end

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

function load_case_inputs(spec)
    hourly_path = find_existing_file(spec.run_dir, spec.hourly_csv_candidates)
    diagnostics_path = find_existing_file(spec.run_dir, spec.diagnostics_csv_candidates)

    hourly_df = CSV.read(hourly_path, DataFrame) |> normalize_column_names!
    diagnostics_df = CSV.read(diagnostics_path, DataFrame) |> normalize_column_names!

    case_hourly = filter(row -> String(row.case_name) == spec.case_name, hourly_df)
    isempty(case_hourly) && error("No executed-hour rows found for $(spec.case_name) in $hourly_path")

    sort!(case_hourly, :global_hour)
    case_hourly = unique(case_hourly, :global_hour)

    case_diag = filter(row -> String(row.case_name) == spec.case_name, diagnostics_df)
    isempty(case_diag) && error("No clearing diagnostics found for $(spec.case_name) in $diagnostics_path")
    sort!(case_diag, :clearing)

    start_soc_col = hasproperty(first(eachrow(case_diag)), :start_soc) ? :start_soc : :soc_start
    initial_soc = Float64(case_diag[1, start_soc_col])

    return (
        hourly_df = case_hourly,
        diagnostics_df = case_diag,
        initial_soc = initial_soc,
        hourly_path = hourly_path,
        diagnostics_path = diagnostics_path,
    )
end

function weighted_mean(values::AbstractVector{<:Real}, weights::AbstractVector{<:Real})
    total_weight = sum(weights)
    return total_weight > EPS ? sum(values .* weights) / total_weight : NaN
end

function weighted_quantile(values::AbstractVector{<:Real}, weights::AbstractVector{<:Real}, p::Real)
    isempty(values) && return NaN
    total_weight = sum(weights)
    total_weight > EPS || return NaN

    order = sortperm(values)
    sorted_values = collect(values[order])
    sorted_weights = collect(weights[order])
    threshold = clamp(Float64(p), 0.0, 1.0) * total_weight
    cumulative = 0.0

    for (value, weight) in zip(sorted_values, sorted_weights)
        cumulative += weight
        if cumulative + EPS >= threshold
            return Float64(value)
        end
    end

    return Float64(sorted_values[end])
end

function build_fifo_trace(hourly_df::DataFrame, initial_soc::Float64; efficiency::Float64 = 0.9)
    packets = EnergyPacket[]
    if initial_soc > EPS
        push!(packets, EnergyPacket(missing, initial_soc, :initial_soc))
    end

    residence_hours = Float64[]
    discharge_weights = Float64[]
    hourly_trace_rows = NamedTuple[]
    total_charge_input = 0.0
    total_discharge_output = 0.0
    traced_discharge_output = 0.0
    untraced_discharge_output = 0.0
    simultaneous_hours = 0

    for row in eachrow(hourly_df)
        hour = Int(row.global_hour)
        charge_input = Float64(row.charge)
        discharge_output = Float64(row.discharge)
        total_charge_input += charge_input
        total_discharge_output += discharge_output
        if charge_input > EPS && discharge_output > EPS
            simultaneous_hours += 1
        end

        remaining_discharge_output = discharge_output
        traced_output_this_hour = 0.0
        untraced_output_this_hour = 0.0

        while remaining_discharge_output > EPS
            isempty(packets) && error("FIFO queue emptied before meeting discharge at hour $hour. Check data consistency.")

            packet = packets[1]
            packet.energy_in_soc <= EPS && (popfirst!(packets); continue)

            required_soc = remaining_discharge_output / efficiency
            consumed_soc = min(packet.energy_in_soc, required_soc)
            produced_output = consumed_soc * efficiency
            packet.energy_in_soc -= consumed_soc
            remaining_discharge_output -= produced_output

            if ismissing(packet.charge_hour)
                untraced_output_this_hour += produced_output
            else
                residence = hour - packet.charge_hour
                push!(residence_hours, Float64(residence))
                push!(discharge_weights, Float64(produced_output))
                traced_output_this_hour += produced_output
            end

            if packet.energy_in_soc <= EPS
                popfirst!(packets)
            end
        end

        # Charge is appended after discharge to avoid creating artificial 0h residence from same-hour
        # charge/discharge overlap in hourly-aggregated data.
        if charge_input > EPS
            push!(packets, EnergyPacket(hour, efficiency * charge_input, :charged))
        end

        push!(hourly_trace_rows, (
            global_hour = hour,
            charge_input_mwh = charge_input,
            discharge_output_mwh = discharge_output,
            traced_discharge_output_mwh = traced_output_this_hour,
            untraced_discharge_output_mwh = untraced_output_this_hour,
            queue_soc_after_hour_mwh = sum((packet.energy_in_soc for packet in packets); init = 0.0),
        ))
        traced_discharge_output += traced_output_this_hour
        untraced_discharge_output += untraced_output_this_hour
    end

    return (
        residence_hours = residence_hours,
        discharge_weights = discharge_weights,
        hourly_trace_df = DataFrame(hourly_trace_rows),
        total_charge_input = total_charge_input,
        total_discharge_output = total_discharge_output,
        traced_discharge_output = traced_discharge_output,
        untraced_discharge_output = untraced_discharge_output,
        simultaneous_hours = simultaneous_hours,
        remaining_soc_total = sum((packet.energy_in_soc for packet in packets); init = 0.0),
        remaining_soc_from_initial = sum((packet.energy_in_soc for packet in packets if packet.source == :initial_soc); init = 0.0),
        remaining_soc_from_charged_packets = sum((packet.energy_in_soc for packet in packets if packet.source == :charged); init = 0.0),
    )
end

function summarize_trace(spec, loaded, trace)
    residence = trace.residence_hours
    weights = trace.discharge_weights
    traced_total = trace.traced_discharge_output
    total_output = trace.total_discharge_output

    summary = Dict{Symbol, Any}(
        :case_name => spec.case_name,
        :battery_group => spec.battery_group,
        :look_ahead_h => spec.look_ahead_h,
        :hourly_rows => nrow(loaded.hourly_df),
        :hourly_path => loaded.hourly_path,
        :diagnostics_path => loaded.diagnostics_path,
        :initial_soc_mwh => loaded.initial_soc,
        :total_charge_input_mwh => trace.total_charge_input,
        :total_discharge_output_mwh => total_output,
        :traced_discharge_output_mwh => traced_total,
        :untraced_discharge_output_mwh => trace.untraced_discharge_output,
        :traced_share_of_total_discharge => total_output > EPS ? traced_total / total_output : NaN,
        :simultaneous_charge_discharge_hours => trace.simultaneous_hours,
        :mean_residence_h => weighted_mean(residence, weights),
        :median_residence_h => weighted_quantile(residence, weights, 0.5),
        :p90_residence_h => weighted_quantile(residence, weights, 0.9),
    )

    for threshold in THRESHOLDS_H
        share = traced_total > EPS ? sum(weights[residence .<= threshold]) / traced_total : NaN
        summary[Symbol("share_within_$(threshold)h")] = share
    end

    return summary
end

function residence_detail_df(spec, residence_hours, weights)
    rows = NamedTuple[]
    for (residence_h, discharge_mwh) in zip(residence_hours, weights)
        push!(rows, (
            case_name = spec.case_name,
            battery_group = spec.battery_group,
            look_ahead_h = spec.look_ahead_h,
            residence_h = residence_h,
            discharge_mwh = discharge_mwh,
        ))
    end
    return DataFrame(rows)
end

function cdf_curve_df(spec, residence_hours, weights)
    isempty(residence_hours) && return DataFrame(
        case_name = String[],
        battery_group = String[],
        look_ahead_h = Int[],
        residence_h = Float64[],
        cumulative_share = Float64[],
    )

    order = sortperm(residence_hours)
    x = residence_hours[order]
    w = weights[order]
    total_w = sum(w)
    cumulative = cumsum(w) ./ total_w

    return DataFrame(
        case_name = fill(spec.case_name, length(x)),
        battery_group = fill(spec.battery_group, length(x)),
        look_ahead_h = fill(spec.look_ahead_h, length(x)),
        residence_h = x,
        cumulative_share = cumulative,
    )
end

function histogram_df(spec, residence_hours, weights; max_hour::Int = 72)
    bins = collect(0:max_hour)
    counts = zeros(Float64, length(bins))

    for (residence_h, weight) in zip(residence_hours, weights)
        idx = clamp(floor(Int, residence_h) + 1, 1, length(counts))
        counts[idx] += weight
    end

    total = sum(counts)
    return DataFrame(
        case_name = fill(spec.case_name, length(bins)),
        battery_group = fill(spec.battery_group, length(bins)),
        look_ahead_h = fill(spec.look_ahead_h, length(bins)),
        residence_hour_bin = bins,
        discharge_mwh = counts,
        discharge_share = total > EPS ? counts ./ total : fill(NaN, length(bins)),
    )
end

function save_plot_safe(plot_obj, output_path::AbstractString)
    mkpath(dirname(output_path))
    savefig(plot_obj, output_path)
    return output_path
end

function plot_group_histograms(details_df::DataFrame, group_name::AbstractString, output_path::AbstractString)
    subset = filter(row -> row.battery_group == group_name, details_df)
    case_names = unique(subset.case_name)
    plots = Any[]

    for case_name in sort(case_names, by = name -> parse(Int, match(r"(36|48|72)", name).match))
        case_df = filter(row -> row.case_name == case_name, subset)
        bins = 0:3:72
        hist_weights = Float64.(case_df.discharge_mwh)
        hist_edges = collect(bins)
        hist_counts = zeros(Float64, length(hist_edges) - 1)
        for (residence, weight) in zip(case_df.residence_h, hist_weights)
            idx = clamp(searchsortedlast(hist_edges, Float64(residence)), 1, length(hist_edges) - 1)
            hist_counts[idx] += weight
        end
        total_weight = sum(hist_counts)
        hist_probs = total_weight > EPS ? hist_counts ./ total_weight : hist_counts
        y_upper = maximum(hist_probs; init = 0.0) * 1.12 + 0.005

        p = histogram(
            case_df.residence_h,
            weights = hist_weights,
            normalize = :probability,
            bins = bins,
            color = get(CASE_COLORS, case_name, :steelblue),
            alpha = 0.75,
            xlabel = "Residence time (h)",
            ylabel = "Discharge share",
            title = case_name,
            legend = false,
            xlim = (-1, 73),
            ylim = (0, y_upper),
            framestyle = :box,
            gridalpha = 0.18,
            guidefontsize = 10,
            tickfontsize = 9,
            titlefontsize = 11,
            left_margin = 8Plots.mm,
            right_margin = 4Plots.mm,
            top_margin = 3Plots.mm,
            bottom_margin = 4Plots.mm,
        )
        push!(plots, p)
    end

    combined = plot(
        plots...,
        layout = (length(plots), 1),
        size = (1000, 235 * length(plots)),
        left_margin = 6Plots.mm,
        right_margin = 4Plots.mm,
        top_margin = 2Plots.mm,
        bottom_margin = 4Plots.mm,
    )
    save_plot_safe(combined, output_path)
end

function plot_cdf_comparison(cdf_df::DataFrame, output_path::AbstractString; battery_group::Union{Nothing, String} = nothing)
    subset = isnothing(battery_group) ? cdf_df : filter(row -> row.battery_group == battery_group, cdf_df)
    p = plot(
        xlabel = "Residence time (h)",
        ylabel = "Cumulative discharge share",
        xlim = (0, 72),
        ylim = (0, 1.0),
        title = isnothing(battery_group) ? "Storage Residence-Time CDF" : "Storage Residence-Time CDF: $battery_group",
    )

    case_names = unique(subset.case_name)
    for case_name in sort(case_names, by = name -> (occursin("High-storage", name) ? 1 : 0, parse(Int, match(r"(36|48|72)", name).match)))
        case_df = filter(row -> row.case_name == case_name, subset)
        plot!(
            p,
            case_df.residence_h,
            case_df.cumulative_share,
            label = case_name,
            color = get(CASE_COLORS, case_name, :steelblue),
            linewidth = 2.5,
        )
    end

    for threshold in THRESHOLDS_H
        vline!(p, [threshold], color = RGBA(0, 0, 0, 0.12), linestyle = :dash, label = "")
    end

    save_plot_safe(p, output_path)
end

function assess_hypothesis(summary_df::DataFrame)
    results = String[]
    market_clearing_ref = "$(abspath("market_clearing_rolling.jl"))#L311"
    thesis_runner_ref = "$(abspath("src/thesis_runner.jl"))#L42"
    baseline_analysis_ref = "$(abspath("analyze_foresight_result_hypotheses.jl"))#L67"
    high_storage_analysis_ref = "$(abspath("analyze_large_storage_hypotheses.jl"))#L149"
    push!(results, "# Hypothesis 1 Residence-Time Assessment")
    push!(results, "")
    push!(results, "Claim tested: a 36h rolling horizon already captures most economically relevant storage cycles, so moving to 48h or 72h should add little because most discharged energy was charged within 24-36h earlier.")
    push!(results, "")
    push!(results, "## Method")
    push!(results, "- Used existing executed-hour CSV outputs plus existing clearing-level SOC diagnostics from the two requested run folders.")
    push!(results, "- Reconstructed hourly residence times with an efficiency-aware FIFO approximation on the executed charge/discharge series.")
    push!(results, "- FIFO inventory is tracked in SOC-energy units: charging adds `eta * charge`, discharging withdraws `discharge / eta`, and attributed market-side discharge is `eta * withdrawn_SOC`.")
    push!(results, "- Same-hour charge is appended after discharge to avoid creating artificial 0h residence from hourly aggregation.")
    push!(results, "- Initial SOC is treated as untraceable inventory. If it ever contributes to discharge, that energy is excluded from the timed residence statistics and reported separately.")
    push!(results, "")
    push!(results, "## Mapping in the codebase")
    push!(results, "- [market_clearing_rolling.jl]($market_clearing_ref): `all_results[:clearing_details][clearing_count]` stores `:charging`, `:discharging`, `:executed_hours`, `:storage_soc_start`, `:storage_soc_path`, `:storage_soc_end_executed`, and `:storage_soc_end_window`.")
    push!(results, "- [src/thesis_runner.jl]($thesis_runner_ref): existing summary logic iterates over `details[:executed_hours]` and uses executed-hour slices of those stored vectors.")
    push!(results, "- [analyze_foresight_result_hypotheses.jl]($baseline_analysis_ref): baseline executed-hour outputs are already exported into `_hypothesis_analysis/executed_hourly_metrics*.csv` and clearing SOC diagnostics into `clearing_hypothesis_metrics_20260323.csv`.")
    push!(results, "- [analyze_large_storage_hypotheses.jl]($high_storage_analysis_ref): high-storage executed-hour outputs are already exported into `_large_storage_hypothesis_analysis/large_storage_executed_hour_metrics.csv` and clearing SOC diagnostics into `large_storage_clearing_diagnostics.csv`.")
    push!(results, "- No exact charge-discharge lineage is stored anywhere I found in the model outputs or downstream analysis files.")
    push!(results, "")
    push!(results, "## Key results")

    for group_name in ("Baseline battery", "Large battery")
        push!(results, "")
        push!(results, "### $group_name")
        subset = filter(row -> row.battery_group == group_name, summary_df)
        sort!(subset, :look_ahead_h)
        for row in eachrow(subset)
            push!(results,
                @sprintf(
                    "- %s: share within 24h = %.1f%%, within 36h = %.1f%%, within 48h = %.1f%%, mean = %.1fh, median = %.1fh, p90 = %.1fh, traced discharge share = %.1f%%.",
                    row.case_name,
                    100 * row.share_within_24h,
                    100 * row.share_within_36h,
                    100 * row.share_within_48h,
                    row.mean_residence_h,
                    row.median_residence_h,
                    row.p90_residence_h,
                    100 * row.traced_share_of_total_discharge,
                )
            )
        end
    end

    baseline_36 = filter(row -> row.case_name == "Rolling 36h", summary_df)[1, :]
    baseline_72 = filter(row -> row.case_name == "Rolling 72h", summary_df)[1, :]
    large_36 = filter(row -> row.case_name == "High-storage Rolling 36h", summary_df)[1, :]
    large_72 = filter(row -> row.case_name == "High-storage Rolling 72h", summary_df)[1, :]

    push!(results, "")
    push!(results, "## Interpretation")
    if baseline_36.share_within_36h >= 0.8 && large_36.share_within_36h >= 0.8
        push!(results, "- The residence-time distributions are concentrated enough inside 36h that Hypothesis 1 is broadly supported on this metric.")
    else
        push!(results, "- The residence-time distributions are not concentrated enough inside 36h to call Hypothesis 1 strongly supported on this metric alone.")
    end
    push!(results,
        @sprintf(
            "- Moving from 36h to 72h changes the within-36h discharge share by %.1f percentage points for the baseline battery and %.1f percentage points for the large battery.",
            100 * (baseline_72.share_within_36h - baseline_36.share_within_36h),
            100 * (large_72.share_within_36h - large_36.share_within_36h),
        )
    )
    push!(results,
        @sprintf(
            "- The within-48h discharge share rises from %.1f%% to %.1f%% for the baseline battery and from %.1f%% to %.1f%% for the large battery when comparing 36h to 72h.",
            100 * baseline_36.share_within_48h,
            100 * baseline_72.share_within_48h,
            100 * large_36.share_within_48h,
            100 * large_72.share_within_48h,
        )
    )
    push!(results, "- What this can show: whether executed storage output is dominated by short-to-medium residence cycles in these solved runs.")
    push!(results, "- What this cannot show: that longer foresight has no value, or that any welfare differences are caused only by longer storage residence times.")
    push!(results, "- Main confounders: FIFO is an approximation, hourly aggregation hides within-hour sequencing, and residence-time concentration does not identify which rare long cycles may still be economically important at the margin.")

    return join(results, "\n")
end

function main()
    output_dir = joinpath(
        "Results",
        "thesis_runs",
        "hypothesis1_residence_time_analysis_$(FORESIGHT_RUN_NAME)_$(HIGH_STORAGE_RUN_NAME)",
    )
    mkpath(output_dir)

    summary_rows = NamedTuple[]
    all_details = DataFrame()
    all_cdf = DataFrame()
    all_hist = DataFrame()
    all_hourly = DataFrame()

    for spec in CASE_SPECS
        loaded = load_case_inputs(spec)
        trace = build_fifo_trace(loaded.hourly_df, loaded.initial_soc; efficiency = 0.9)
        summary = summarize_trace(spec, loaded, trace)
        push!(summary_rows, (; (key => value for (key, value) in pairs(summary))...))

        detail_df = residence_detail_df(spec, trace.residence_hours, trace.discharge_weights)
        cdf_df = cdf_curve_df(spec, trace.residence_hours, trace.discharge_weights)
        hist_df = histogram_df(spec, trace.residence_hours, trace.discharge_weights)
        hourly_trace_df = copy(trace.hourly_trace_df)
        hourly_trace_df[!, :case_name] .= spec.case_name
        hourly_trace_df[!, :battery_group] .= spec.battery_group
        hourly_trace_df[!, :look_ahead_h] .= spec.look_ahead_h

        append!(all_details, detail_df, cols = :union)
        append!(all_cdf, cdf_df, cols = :union)
        append!(all_hist, hist_df, cols = :union)
        append!(all_hourly, hourly_trace_df, cols = :union)
    end

    summary_df = DataFrame(summary_rows)
    sort!(summary_df, [:battery_group, :look_ahead_h])

    CSV.write(joinpath(output_dir, "residence_time_summary.csv"), summary_df)
    CSV.write(joinpath(output_dir, "residence_time_detail_points.csv"), all_details)
    CSV.write(joinpath(output_dir, "residence_time_cdf_curve.csv"), all_cdf)
    CSV.write(joinpath(output_dir, "residence_time_histogram_bins.csv"), all_hist)
    CSV.write(joinpath(output_dir, "residence_time_hourly_trace.csv"), all_hourly)

    plot_group_histograms(all_details, "Baseline battery", joinpath(output_dir, "histogram_baseline_battery.png"))
    plot_group_histograms(all_details, "Large battery", joinpath(output_dir, "histogram_large_battery.png"))
    plot_cdf_comparison(all_cdf, joinpath(output_dir, "cdf_all_cases.png"))
    plot_cdf_comparison(all_cdf, joinpath(output_dir, "cdf_baseline_battery.png"); battery_group = "Baseline battery")
    plot_cdf_comparison(all_cdf, joinpath(output_dir, "cdf_large_battery.png"); battery_group = "Large battery")

    summary_text = assess_hypothesis(summary_df)
    write(joinpath(output_dir, "hypothesis1_residence_time_summary.md"), summary_text)

    println("Saved Hypothesis 1 residence-time analysis to: $(abspath(output_dir))")
    println("Summary table: $(joinpath(output_dir, "residence_time_summary.csv"))")
    println("Markdown summary: $(joinpath(output_dir, "hypothesis1_residence_time_summary.md"))")
end

main()

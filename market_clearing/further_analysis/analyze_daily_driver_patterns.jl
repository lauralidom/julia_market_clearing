using CSV
using DataFrames
using Dates
using Plots
using Printf
using Statistics

const SCRIPT_DIR = @__DIR__
const PROJECT_ROOT = normpath(joinpath(SCRIPT_DIR, ".."))
const DEFAULT_RUN_ROOT = joinpath(PROJECT_ROOT, "Results", "thesis_runs")
const DEFAULT_OUTPUT_DIRNAME = "_daily_driver_patterns"

# Easy in-file selectors. Paste a run folder name here, for example:
#   RUN_SELECTOR = "baseline_20260503_200434"
# You can also set a full path to a run folder or its `_summary` folder.
# Leave blank to use the latest compatible run.
const RUN_SELECTOR = ""

# Optional: restrict the analysis to one comparison pair.
# Example:
#   CASE_A_SELECTOR = "Rolling 36h"
#   CASE_B_SELECTOR = "Rolling 48h"
const CASE_A_SELECTOR = ""
const CASE_B_SELECTOR = ""

# If true, clicking "Run" in an IDE that uses `include(...)` will still start the
# analysis, as long as RUN_SELECTOR is filled in.
const AUTO_RUN_WHEN_INCLUDED = true

default(
    guidefontsize = 13,
    tickfontsize = 10,
    titlefontsize = 15,
    legendfontsize = 9,
    gridalpha = 0.15,
    gridlinewidth = 0.6,
    foreground_color_grid = :grey70,
    dpi = 300,
)

function slugify(text::AbstractString)
    safe = replace(lowercase(String(text)), r"[^a-z0-9]+" => "_")
    safe = replace(safe, r"^_+|_+$" => "")
    return isempty(safe) ? "item" : safe
end

function latest_run_with_daily_drivers(root::AbstractString)
    entries = [name for name in readdir(root) if isdir(joinpath(root, name))]
    isempty(entries) && error("No run directories found under $root")
    sort!(entries, by = name -> stat(joinpath(root, name)).mtime)

    for entry in reverse(entries)
        summary_dir = joinpath(root, entry, "_summary")
        if isfile(joinpath(summary_dir, "daily_drivers.csv"))
            return joinpath(root, entry)
        end
    end

    error("No run with daily_drivers.csv found under $root. Re-run the thesis cases with the latest exporter first.")
end

function configured_args(args)
    if !isempty(args)
        return collect(args)
    end

    configured = String[]
    if !isempty(strip(RUN_SELECTOR))
        push!(configured, strip(RUN_SELECTOR))
    end
    if !isempty(strip(CASE_A_SELECTOR)) && !isempty(strip(CASE_B_SELECTOR))
        push!(configured, strip(CASE_A_SELECTOR))
        push!(configured, strip(CASE_B_SELECTOR))
    end
    return configured
end

function resolve_run_like_path(selector::AbstractString)
    raw = strip(String(selector))
    isempty(raw) && error("Empty run selector provided.")

    candidates = String[
        normpath(raw),
        normpath(joinpath(PROJECT_ROOT, raw)),
        normpath(joinpath(DEFAULT_RUN_ROOT, raw)),
        normpath(joinpath(DEFAULT_RUN_ROOT, raw, "_summary")),
    ]

    for path in candidates
        if isdir(joinpath(path, "_summary"))
            return joinpath(path, "_summary")
        elseif isdir(path) && basename(path) == "_summary"
            return path
        elseif isfile(path)
            return dirname(path)
        end
    end

    error("Could not resolve summary directory from selector: $raw")
end

function resolve_summary_dir(args)
    effective_args = configured_args(args)
    if isempty(effective_args)
        return joinpath(latest_run_with_daily_drivers(DEFAULT_RUN_ROOT), "_summary")
    end

    return resolve_run_like_path(effective_args[1])
end

function load_daily_drivers(summary_dir::AbstractString)
    csv_path = joinpath(summary_dir, "daily_drivers.csv")
    isfile(csv_path) || error("daily_drivers.csv not found in $summary_dir. Re-run the thesis cases with the latest exporter first.")
    return CSV.read(csv_path, DataFrame), csv_path
end

function available_comparisons(df::DataFrame)
    pairs = unique(select(df, :case_a, :case_b))
    sort!(pairs, [:case_a, :case_b])
    return [(String(row.case_a), String(row.case_b)) for row in eachrow(pairs)]
end

function safe_cor(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    (length(x) > 1 && std(x) > 0 && std(y) > 0) ? cor(x, y) : NaN
end

function rowwise_mean(left::AbstractVector, right::AbstractVector)
    result = Vector{Union{Missing, Float64}}(undef, length(left))
    for i in eachindex(left)
        l = left[i]
        r = right[i]
        if ismissing(l) && ismissing(r)
            result[i] = missing
        elseif ismissing(l)
            result[i] = Float64(r)
        elseif ismissing(r)
            result[i] = Float64(l)
        else
            result[i] = (Float64(l) + Float64(r)) / 2
        end
    end
    return result
end

function augment_driver_features(df::DataFrame)
    out = deepcopy(df)
    out[!, :delta_storage_charge_mwh] =
        (Float64.(out.delta_storage_throughput_mwh) .- Float64.(out.delta_net_storage_discharge_mwh)) ./ 2
    out[!, :mean_total_demand_mwh] = rowwise_mean(out.left_total_demand_mwh, out.right_total_demand_mwh)
    out[!, :mean_flex_demand_mwh] = rowwise_mean(out.left_flex_demand_mwh, out.right_flex_demand_mwh)
    out[!, :mean_wind_mwh] = rowwise_mean(out.left_wind_mwh, out.right_wind_mwh)
    out[!, :mean_solar_mwh] = rowwise_mean(out.left_solar_mwh, out.right_solar_mwh)
    out[!, :mean_renewables_mwh] = rowwise_mean(out.left_renewables_mwh, out.right_renewables_mwh)
    out[!, :mean_mid_peak_dispatch_mwh] = rowwise_mean(out.left_mid_peak_dispatch_mwh, out.right_mid_peak_dispatch_mwh)
    out[!, :mean_thermal_dispatch_mwh] = rowwise_mean(out.left_thermal_dispatch_mwh, out.right_thermal_dispatch_mwh)
    out[!, :mean_gross_residual_load_proxy_mwh] = rowwise_mean(out.left_gross_residual_load_proxy_mwh, out.right_gross_residual_load_proxy_mwh)
    out[!, :mean_net_residual_load_proxy_mwh] = rowwise_mean(out.left_net_residual_load_proxy_mwh, out.right_net_residual_load_proxy_mwh)
    out[!, :mean_renewable_share_of_demand] = rowwise_mean(out.left_renewable_share_of_demand, out.right_renewable_share_of_demand)
    out[!, :mean_avg_visible_abs_forecast_error] = rowwise_mean(out.left_avg_visible_abs_forecast_error, out.right_avg_visible_abs_forecast_error)
    out[!, :mean_avg_tail_abs_forecast_error] = rowwise_mean(out.left_avg_tail_abs_forecast_error, out.right_avg_tail_abs_forecast_error)
    return out
end

function feature_specs()
    return [
        (:delta_avg_price_eur_per_mwh, "Delta average price"),
        (:delta_price_std_eur_per_mwh, "Delta price std dev"),
        (:delta_price_range_eur_per_mwh, "Delta price range"),
        (:delta_max_price_eur_per_mwh, "Delta max price"),
        (:delta_imbalance_mwh, "Delta imbalance"),
        (:delta_mid_peak_dispatch_mwh, "Delta Mid+Peak dispatch"),
        (:delta_thermal_dispatch_mwh, "Delta thermal dispatch"),
        (:delta_net_storage_discharge_mwh, "Delta net storage discharge"),
        (:delta_renewable_share_of_demand, "Delta renewable share"),
        (:delta_avg_visible_abs_forecast_error, "Delta visible forecast error"),
        (:delta_avg_tail_abs_forecast_error, "Delta tail forecast error"),
        (:mean_total_demand_mwh, "Mean total demand"),
        (:mean_wind_mwh, "Mean wind output"),
        (:mean_solar_mwh, "Mean solar output"),
        (:mean_renewables_mwh, "Mean renewables output"),
        (:mean_mid_peak_dispatch_mwh, "Mean Mid+Peak dispatch"),
        (:mean_gross_residual_load_proxy_mwh, "Mean gross residual load"),
        (:mean_net_residual_load_proxy_mwh, "Mean net residual load"),
        (:mean_renewable_share_of_demand, "Mean renewable share"),
        (:mean_avg_visible_abs_forecast_error, "Mean visible forecast error"),
        (:mean_avg_tail_abs_forecast_error, "Mean tail forecast error"),
    ]
end

function tercile_summary(feature_values::AbstractVector, delta_values::AbstractVector)
    valid = [(Float64(x), Float64(y)) for (x, y) in zip(feature_values, delta_values) if !ismissing(x) && !ismissing(y)]
    length(valid) >= 3 || return (missing, missing, missing, 0, 0, 0)

    x = first.(valid)
    y = last.(valid)
    q1 = quantile(x, 1 / 3)
    q2 = quantile(x, 2 / 3)

    low = [y[i] for i in eachindex(x) if x[i] <= q1]
    mid = [y[i] for i in eachindex(x) if q1 < x[i] <= q2]
    high = [y[i] for i in eachindex(x) if x[i] > q2]

    return (
        isempty(low) ? missing : mean(low),
        isempty(mid) ? missing : mean(mid),
        isempty(high) ? missing : mean(high),
        length(low),
        length(mid),
        length(high),
    )
end

function build_correlation_summary(df::DataFrame)
    rows = NamedTuple[]
    delta = df.delta_social_welfare_eur

    for (feature, label) in feature_specs()
        values = df[!, feature]
        valid = [(Float64(x), Float64(y)) for (x, y) in zip(values, delta) if !ismissing(x) && !ismissing(y)]
        n = length(valid)
        n >= 2 || continue

        x = first.(valid)
        y = last.(valid)
        low_mean, mid_mean, high_mean, low_n, mid_n, high_n = tercile_summary(values, delta)

        push!(rows, (
            feature = String(feature),
            label = label,
            n_days = n,
            corr_with_delta_swf = safe_cor(x, y),
            abs_corr_with_delta_swf = abs(safe_cor(x, y)),
            mean_delta_swf_low_tercile = low_mean,
            mean_delta_swf_mid_tercile = mid_mean,
            mean_delta_swf_high_tercile = high_mean,
            n_low_tercile = low_n,
            n_mid_tercile = mid_n,
            n_high_tercile = high_n,
        ))
    end

    summary = DataFrame(rows)
    if nrow(summary) > 0
        sort!(summary, :abs_corr_with_delta_swf, rev = true)
    end
    return summary
end

function top_feature_symbols(summary::DataFrame; n::Int=6)
    nrow(summary) == 0 && return Symbol[]
    picked = String.(summary.feature[1:min(n, nrow(summary))])
    return Symbol.(picked)
end

function feature_label(feature::Symbol)
    for (sym, label) in feature_specs()
        sym == feature && return label
    end
    return String(feature)
end

function comparison_slug(case_a::AbstractString, case_b::AbstractString)
    return string(slugify(case_b), "_minus_", slugify(case_a))
end

function line_fit(x::Vector{Float64}, y::Vector{Float64})
    n = length(x)
    n >= 2 || return nothing
    xbar = mean(x)
    ybar = mean(y)
    denom = sum((x .- xbar) .^ 2)
    denom > 0 || return nothing
    slope = sum((x .- xbar) .* (y .- ybar)) / denom
    intercept = ybar - slope * xbar
    return intercept, slope
end

function plot_sorted_delta_swf(df::DataFrame, output_path::AbstractString; pair_label::AbstractString)
    sorted = sort(df, :delta_social_welfare_eur, rev = true)
    y = Float64.(sorted.delta_social_welfare_eur)
    colors = [val >= 0 ? RGB(0.15, 0.55, 0.30) : RGB(0.75, 0.22, 0.22) for val in y]
    p = bar(
        1:length(y),
        y,
        color = colors,
        legend = false,
        xlabel = "Days ranked by delta SWF",
        ylabel = "Delta SWF (EUR)",
        title = "$pair_label: Daily Delta SWF",
        size = (1100, 420),
    )
    hline!(p, [0.0], color = :black, linestyle = :dash, linewidth = 1.5)
    savefig(p, output_path)
    return p
end

function plot_scatter_panels(df::DataFrame, corr_summary::DataFrame, output_path::AbstractString; pair_label::AbstractString, n_features::Int=6, panel_specs_override=nothing)
    panel_specs = isnothing(panel_specs_override) ? [
        (feature = :delta_net_storage_discharge_mwh, title = "Net storage discharge", xlabel = "Delta net storage discharge [MWh]"),
        (feature = :delta_mid_peak_dispatch_mwh, title = "Mid + peak dispatch", xlabel = "Delta Mid + Peak dispatch [MWh]"),
        (feature = :delta_imbalance_mwh, title = "Imbalance", xlabel = "Delta imbalance [MWh]"),
        (feature = :delta_avg_tail_abs_forecast_error, title = "Forecast error", xlabel = "Delta tail forecast error [-]"),
    ] : panel_specs_override

    function padded_limits(values; frac = 0.06)
        vmin = minimum(values)
        vmax = maximum(values)
        span = vmax - vmin
        pad = span > 0 ? frac * span : max(1.0, frac * max(abs(vmin), abs(vmax), 1.0))
        return (vmin - pad, vmax + pad)
    end

    panels = Any[]
    for (idx, spec) in enumerate(panel_specs)
        feature = spec.feature
        hasproperty(df, feature) || continue
        values = df[!, feature]
        valid = [(Float64(x), Float64(y)) for (x, y) in zip(values, df.delta_social_welfare_eur) if !ismissing(x) && !ismissing(y)]
        isempty(valid) && continue
        x = first.(valid)
        y = last.(valid)
        corr_xy = safe_cor(x, y)
        xlims_panel = padded_limits(x)
        ylims_panel = padded_limits(y)
        x_text = xlims_panel[1] + 0.04 * (xlims_panel[2] - xlims_panel[1])
        y_text = ylims_panel[2] - 0.08 * (ylims_panel[2] - ylims_panel[1])
        ylabel_text = "Δ social welfare [EUR]"

        p = scatter(
            x,
            y,
            alpha = 0.7,
            markerstrokewidth = 0,
            markersize = 3,
            color = RGB(0.18, 0.43, 0.68),
            xlabel = spec.xlabel,
            ylabel = ylabel_text,
            title = spec.title,
            legend = false,
            xlims = xlims_panel,
            ylims = ylims_panel,
            tickfontsize = 8,
            guidefontsize = 10,
            titlefontsize = 12,
            gridalpha = 0.12,
            framestyle = :box,
            left_margin = 10Plots.mm,
            right_margin = 6Plots.mm,
            top_margin = 3Plots.mm,
            bottom_margin = 8Plots.mm,
        )
        fit = line_fit(x, y)
        if fit !== nothing
            intercept, slope = fit
            xs = collect(range(minimum(x), maximum(x), length = 100))
            ys = intercept .+ slope .* xs
            plot!(p, xs, ys, color = :black, linewidth = 1.4)
        end
        hline!(p, [0.0], color = :grey, linestyle = :dash, linewidth = 1, alpha = 0.6)
        annotate!(p, x_text, y_text, text("r = $(round(corr_xy; digits = 3))", 10, :black, :left))
        push!(panels, p)
    end

    isempty(panels) && return nothing
    while length(panels) < 4
        push!(panels, plot(axis = nothing, grid = false, framestyle = :none))
    end
    combined = plot(
        panels...,
        layout = (2, 2),
        size = (1320, 860),
        plot_title = "$pair_label: Driver Scatter Panels",
        plot_titlefontsize = 12,
        left_margin = 6Plots.mm,
        right_margin = 6Plots.mm,
        top_margin = 10Plots.mm,
        bottom_margin = 8Plots.mm,
    )
    savefig(combined, output_path)
    return combined
end

function plot_simplified_driver_panels(df::DataFrame, output_path::AbstractString; pair_label::AbstractString)
    panel_specs = [
        (
            feature = :delta_net_storage_discharge_mwh,
            title = "A. Net storage discharge",
            xlabel = "Delta net storage discharge [MWh]",
            subtitle = "Does longer look-ahead improve welfare by changing storage use?",
        ),
        (
            feature = :delta_mid_peak_dispatch_mwh,
            title = "B. Mid + Peak dispatch",
            xlabel = "Delta Mid + Peak dispatch [MWh]",
            subtitle = "Does it reduce expensive thermal generation?",
        ),
        (
            feature = :delta_demand_value_eur,
            title = "C. Demand value",
            xlabel = "Delta demand value [EUR]",
            subtitle = "",
        ),
    ]

    function padded_limits(values; frac = 0.08)
        vmin = minimum(values)
        vmax = maximum(values)
        span = vmax - vmin
        pad = span > 0 ? frac * span : max(1.0, frac * max(abs(vmin), abs(vmax), 1.0))
        return (vmin - pad, vmax + pad)
    end

    panels = Any[]
    for spec in panel_specs
        feature = spec.feature
        hasproperty(df, feature) || continue
        valid = [
            (Float64(x), Float64(y)) for (x, y) in zip(df[!, feature], df.delta_social_welfare_eur)
            if !ismissing(x) && !ismissing(y)
        ]
        isempty(valid) && continue

        x = first.(valid)
        y = last.(valid)
        corr_xy = safe_cor(x, y)
        xlims_panel = padded_limits(x)
        ylims_panel = padded_limits(y)
        x_text = xlims_panel[1] + 0.04 * (xlims_panel[2] - xlims_panel[1])
        y_text = ylims_panel[2] - 0.08 * (ylims_panel[2] - ylims_panel[1])
        panel_title = isempty(spec.subtitle) ? spec.title : string(spec.title, "\n", spec.subtitle)

        p = scatter(
            x,
            y,
            alpha = 0.7,
            markerstrokewidth = 0,
            markersize = 3,
            color = RGB(0.18, 0.43, 0.68),
            xlabel = spec.xlabel,
            ylabel = "Delta social welfare [EUR]",
            title = panel_title,
            legend = false,
            xlims = xlims_panel,
            ylims = ylims_panel,
            tickfontsize = 9,
            guidefontsize = 10,
            titlefontsize = 11,
            gridalpha = 0.18,
            framestyle = :box,
            left_margin = 10Plots.mm,
            right_margin = 5Plots.mm,
            top_margin = 4Plots.mm,
            bottom_margin = 7Plots.mm,
            size = (420, 420),
        )
        fit = line_fit(x, y)
        if fit !== nothing
            intercept, slope = fit
            xs = collect(range(minimum(x), maximum(x), length = 100))
            ys = intercept .+ slope .* xs
            plot!(p, xs, ys, color = :black, linewidth = 1.4)
        end
        hline!(p, [0.0], color = :grey, linestyle = :dash, linewidth = 1, alpha = 0.6, label = "")
        annotate!(p, x_text, y_text, text("r = $(round(corr_xy; digits = 3))", 10, :black, :left))
        push!(panels, p)
    end

    isempty(panels) && return nothing
    combined = plot(
        panels...,
        layout = (1, length(panels)),
        size = (1500, 460),
        plot_title = "$pair_label: Simplified driver panels",
        plot_titlefontsize = 13,
        left_margin = 4Plots.mm,
        right_margin = 4Plots.mm,
        top_margin = 8Plots.mm,
        bottom_margin = 6Plots.mm,
    )
    savefig(combined, output_path)
    return combined
end

function plot_storage_dispatch_imbalance_panels(df::DataFrame, output_path::AbstractString; pair_label::AbstractString)
    ensure_dir(dirname(String(output_path)))
    panel_specs = [
        (
            feature = :delta_net_storage_discharge_mwh,
            title = "A. Net storage discharge",
            xlabel = "Delta net storage discharge [MWh]",
        ),
        (
            feature = :delta_demand_value_eur,
            title = "B. Demand value",
            xlabel = "Delta demand value [EUR]",
        ),
        (
            feature = :delta_storage_charge_mwh,
            title = "C. Storage charge",
            xlabel = "Delta storage charge [MWh]",
        ),
    ]

    function padded_limits(values; frac = 0.08)
        vmin = minimum(values)
        vmax = maximum(values)
        span = vmax - vmin
        pad = span > 0 ? frac * span : max(1.0, frac * max(abs(vmin), abs(vmax), 1.0))
        return (vmin - pad, vmax + pad)
    end

    panels = Any[]
    for spec in panel_specs
        feature = spec.feature
        hasproperty(df, feature) || continue
        valid = [
            (Float64(x), Float64(y)) for (x, y) in zip(df[!, feature], df.delta_social_welfare_eur)
            if !ismissing(x) && !ismissing(y)
        ]
        isempty(valid) && continue

        x = first.(valid)
        y = last.(valid)
        corr_xy = safe_cor(x, y)
        xlims_panel = padded_limits(x)
        ylims_panel = padded_limits(y)
        x_text = xlims_panel[1] + 0.04 * (xlims_panel[2] - xlims_panel[1])
        y_text = ylims_panel[2] - 0.08 * (ylims_panel[2] - ylims_panel[1])

        p = scatter(
            x,
            y,
            alpha = 0.7,
            markerstrokewidth = 0,
            markersize = 3,
            color = RGB(0.18, 0.43, 0.68),
            xlabel = spec.xlabel,
            ylabel = "Delta social welfare [EUR]",
            title = spec.title,
            legend = false,
            xlims = xlims_panel,
            ylims = ylims_panel,
            tickfontsize = 9,
            guidefontsize = 10,
            titlefontsize = 11,
            gridalpha = 0.18,
            framestyle = :box,
            left_margin = 10Plots.mm,
            right_margin = 5Plots.mm,
            top_margin = 4Plots.mm,
            bottom_margin = 7Plots.mm,
            size = (420, 420),
        )
        fit = line_fit(x, y)
        if fit !== nothing
            intercept, slope = fit
            xs = collect(range(minimum(x), maximum(x), length = 100))
            ys = intercept .+ slope .* xs
            plot!(p, xs, ys, color = :black, linewidth = 1.4)
        end
        hline!(p, [0.0], color = :grey, linestyle = :dash, linewidth = 1, alpha = 0.6, label = "")
        annotate!(p, x_text, y_text, text("r = $(round(corr_xy; digits = 3))", 10, :black, :left))
        push!(panels, p)
    end

    isempty(panels) && return nothing
    combined = plot(
        panels...,
        layout = (1, length(panels)),
        size = (1500, 460),
        plot_title = "$pair_label: Storage, demand value, and storage charge",
        plot_titlefontsize = 13,
        left_margin = 4Plots.mm,
        right_margin = 4Plots.mm,
        top_margin = 8Plots.mm,
        bottom_margin = 6Plots.mm,
    )
    savefig(combined, output_path)
    return combined
end

function plot_tercile_bars(corr_summary::DataFrame, output_path::AbstractString; pair_label::AbstractString, n_features::Int=4)
    summary = first(corr_summary, min(n_features, nrow(corr_summary)))
    nrow(summary) == 0 && return nothing

    panels = Any[]
    for row in eachrow(summary)
        vals = [
            row.mean_delta_swf_low_tercile,
            row.mean_delta_swf_mid_tercile,
            row.mean_delta_swf_high_tercile,
        ]
        if any(ismissing, vals)
            continue
        end
        p = bar(
            ["Low", "Mid", "High"],
            Float64.(vals),
            color = [RGB(0.73, 0.82, 0.93), RGB(0.40, 0.62, 0.80), RGB(0.11, 0.37, 0.62)],
            legend = false,
            xlabel = "Driver tercile",
            ylabel = "Mean delta SWF (EUR)",
            title = String(row.label),
        )
        hline!(p, [0.0], color = :black, linestyle = :dash, linewidth = 1)
        push!(panels, p)
    end

    isempty(panels) && return nothing
    rows = ceil(Int, length(panels) / 2)
    combined = plot(panels..., layout = (rows, 2), size = (1200, 320 * rows), plot_title = "$pair_label: Mean Delta SWF by Driver Tercile")
    savefig(combined, output_path)
    return combined
end

function write_text_summary(df::DataFrame, corr_summary::DataFrame, output_path::AbstractString; pair_label::AbstractString)
    sorted = sort(df, :delta_social_welfare_eur, rev = true)
    top_days = first(sorted, min(3, nrow(sorted)))
    bottom_days = last(sorted, min(3, nrow(sorted)))

    open(output_path, "w") do io
        println(io, "DAILY DRIVER PATTERN SUMMARY")
        println(io, pair_label)
        println(io)
        println(io, "Top correlated features with delta SWF")
        println(io, "-"^72)
        for row in eachrow(first(corr_summary, min(8, nrow(corr_summary))))
            @printf(io, "%-35s corr=%8.4f | low=%10.2f | mid=%10.2f | high=%10.2f\n",
                String(row.label),
                row.corr_with_delta_swf,
                ismissing(row.mean_delta_swf_low_tercile) ? NaN : Float64(row.mean_delta_swf_low_tercile),
                ismissing(row.mean_delta_swf_mid_tercile) ? NaN : Float64(row.mean_delta_swf_mid_tercile),
                ismissing(row.mean_delta_swf_high_tercile) ? NaN : Float64(row.mean_delta_swf_high_tercile),
            )
        end

        println(io)
        println(io, "Top positive delta SWF days")
        println(io, "-"^72)
        for row in eachrow(top_days)
            @printf(io, "Day %2d | %s | delta_swf=%10.2f | delta_cost=%10.2f | delta_demand=%10.2f | delta_storage_rev=%10.2f\n",
                Int(row.simulation_day),
                "$(row.calendar_day)",
                Float64(row.delta_social_welfare_eur),
                Float64(row.delta_generation_cost_eur),
                Float64(row.delta_demand_value_eur),
                Float64(row.delta_storage_revenue_eur),
            )
        end

        println(io)
        println(io, "Top negative delta SWF days")
        println(io, "-"^72)
        for row in eachrow(sort(bottom_days, :delta_social_welfare_eur))
            @printf(io, "Day %2d | %s | delta_swf=%10.2f | delta_cost=%10.2f | delta_demand=%10.2f | delta_storage_rev=%10.2f\n",
                Int(row.simulation_day),
                "$(row.calendar_day)",
                Float64(row.delta_social_welfare_eur),
                Float64(row.delta_generation_cost_eur),
                Float64(row.delta_demand_value_eur),
                Float64(row.delta_storage_revenue_eur),
            )
        end
    end
end

function analyze_comparison(df::DataFrame, output_dir::AbstractString; case_a::AbstractString, case_b::AbstractString)
    subset = filter(row -> String(row.case_a) == case_a && String(row.case_b) == case_b, df)
    isempty(subset) && error("No rows found for comparison: $case_b - $case_a")
    ensure_dir(output_dir)

    working = augment_driver_features(subset)
    corr_summary = build_correlation_summary(working)
    CSV.write(joinpath(output_dir, "driver_correlation_summary.csv"), corr_summary)
    CSV.write(joinpath(output_dir, "comparison_rows.csv"), working)

    pair_label = "$case_b - $case_a"
    plot_sorted_delta_swf(working, joinpath(output_dir, "sorted_delta_swf.png"); pair_label = pair_label)
    scatter_specs = if case_a == "High-storage Fixed 36h" && case_b == "High-storage Rolling 36h"
        [
            (feature = :delta_net_storage_discharge_mwh, title = "Net storage discharge", xlabel = "Delta net storage discharge [MWh]"),
            (feature = :delta_mid_peak_dispatch_mwh, title = "Mid + peak dispatch", xlabel = "Delta Mid + Peak dispatch [MWh]"),
            (feature = :delta_demand_value_eur, title = "Demand value", xlabel = "Delta demand value [EUR]"),
            (feature = :delta_avg_tail_abs_forecast_error, title = "Forecast error", xlabel = "Delta tail forecast error [-]"),
        ]
    else
        nothing
    end
    plot_scatter_panels(
        working,
        corr_summary,
        joinpath(output_dir, "top_driver_scatter_panels.png");
        pair_label = pair_label,
        panel_specs_override = scatter_specs,
    )
    plot_simplified_driver_panels(working, joinpath(output_dir, "simplified_driver_panels.png"); pair_label = pair_label)
    plot_storage_dispatch_imbalance_panels(working, joinpath(output_dir, "sdi_panels.png"); pair_label = pair_label)
    plot_tercile_bars(corr_summary, joinpath(output_dir, "top_driver_tercile_bars.png"); pair_label = pair_label)
    write_text_summary(working, corr_summary, joinpath(output_dir, "pattern_summary.txt"); pair_label = pair_label)

    return corr_summary
end

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
    return path
end

function run_daily_driver_pattern_analysis(summary_dir::AbstractString;
                                           case_a::Union{Nothing, AbstractString}=nothing,
                                           case_b::Union{Nothing, AbstractString}=nothing,
                                           verbose::Bool=true)
    df, csv_path = load_daily_drivers(summary_dir)

    if !isnothing(case_a) && !isnothing(case_b)
        requested = [(String(case_a), String(case_b))]
    else
        requested = available_comparisons(df)
    end

    output_root = ensure_dir(joinpath(summary_dir, DEFAULT_OUTPUT_DIRNAME))
    overview_rows = NamedTuple[]

    if verbose
        println("Resolved summary directory: $summary_dir")
        println("Loaded daily drivers from: $csv_path")
        println("Writing pattern outputs to: $output_root")
        println("Comparisons to analyze: $(length(requested))")
        println("-"^80)
    end

    for (case_a_name, case_b_name) in requested
        verbose && println("Starting comparison: $case_b_name - $case_a_name")
        pair_dir = ensure_dir(joinpath(output_root, comparison_slug(case_a_name, case_b_name)))
        corr_summary = analyze_comparison(df, pair_dir; case_a = case_a_name, case_b = case_b_name)
        top_feature = nrow(corr_summary) > 0 ? String(corr_summary.feature[1]) : ""
        top_label = nrow(corr_summary) > 0 ? String(corr_summary.label[1]) : ""
        top_corr = nrow(corr_summary) > 0 ? Float64(corr_summary.corr_with_delta_swf[1]) : NaN
        push!(overview_rows, (
            case_a = case_a_name,
            case_b = case_b_name,
            output_dir = pair_dir,
            top_feature = top_feature,
            top_feature_label = top_label,
            top_correlation = top_corr,
        ))
        if verbose
            if !isempty(top_label)
                println("Finished comparison: $case_b_name - $case_a_name | top feature: $top_label | corr=$(round(top_corr; digits=3))")
            else
                println("Finished comparison: $case_b_name - $case_a_name | no usable driver correlations found")
            end
        end
    end

    overview_df = DataFrame(overview_rows)
    overview_path = joinpath(output_root, "comparison_overview.csv")
    CSV.write(overview_path, overview_df)
    verbose && println("Saved overview: $overview_path")

    return Dict(
        :summary_dir => summary_dir,
        :daily_drivers_csv => csv_path,
        :output_root => output_root,
        :overview_path => overview_path,
        :overview_table => overview_df,
        :requested_comparisons => requested,
    )
end

function main(args)
    effective_args = configured_args(args)
    println()
    println("="^80)
    println("DAILY DRIVER PATTERN ANALYSIS")
    println("="^80)
    println("Project root: $PROJECT_ROOT")
    println("Run selector: $(isempty(strip(RUN_SELECTOR)) ? "<latest compatible run>" : RUN_SELECTOR)")
    if length(effective_args) >= 3
        println("Comparison filter: $(effective_args[3]) - $(effective_args[2])")
    else
        println("Comparison filter: all available comparisons")
    end
    summary_dir = resolve_summary_dir(effective_args)
    analysis_result =
        if length(effective_args) >= 3
            run_daily_driver_pattern_analysis(summary_dir; case_a=effective_args[2], case_b=effective_args[3], verbose=true)
        else
            run_daily_driver_pattern_analysis(summary_dir; verbose=true)
        end
    println("="^80)
    println("DAILY DRIVER PATTERN ANALYSIS COMPLETE")
    println("="^80)
    return analysis_result
end

function should_auto_run_when_included()
    return AUTO_RUN_WHEN_INCLUDED && isinteractive() && !isempty(strip(RUN_SELECTOR))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
elseif should_auto_run_when_included()
    println("AUTO_RUN_WHEN_INCLUDED is enabled. Running daily driver analysis for RUN_SELECTOR=$(RUN_SELECTOR)")
    main(String[])
end

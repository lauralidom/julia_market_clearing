using JuMP
using Serialization
using Statistics
using Printf
using Plots

const DEFAULT_RUN_ROOT = joinpath("Results", "thesis_runs")
const CASE_FOLDERS = Dict(
    "Fixed 36h" => "fixed_36h",
    "Rolling 36h" => "rolling_36h",
)
const LAST_HOURS = 6

function latest_baseline_run(root::AbstractString)
    entries = filter(name -> startswith(name, "baseline_"), readdir(root))
    isempty(entries) && error("No baseline run folders found under $root")
    sort!(entries)
    return joinpath(root, entries[end])
end

function resolve_run_dir(args)
    return isempty(args) ? latest_baseline_run(DEFAULT_RUN_ROOT) : args[1]
end

function load_case(run_dir::AbstractString, case_folder::AbstractString)
    case_dir = joinpath(run_dir, case_folder)
    isdir(case_dir) || error("Missing case directory: $case_dir")
    all_results = deserialize(joinpath(case_dir, "all_results.jls"))
    cfg = deserialize(joinpath(case_dir, "cfg.jls"))
    return all_results, cfg
end

function safe_ratio(num::Real, den::Real)
    return den > 1e-9 ? float(num) / float(den) : 0.0
end

function collect_horizon_end_rows(case_name::AbstractString, all_results::Dict)
    clearing_details = all_results[:clearing_details]
    rows = NamedTuple[]

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        look_ahead = Int(details[:look_ahead])
        tail_start = max(1, look_ahead - LAST_HOURS + 1)
        tail_range = tail_start:look_ahead

        charging = Float64.(details[:charging])
        discharging = Float64.(details[:discharging])
        total_charge = sum(charging)
        total_discharge = sum(discharging)
        tail_charge = sum(charging[tail_range])
        tail_discharge = sum(discharging[tail_range])
        pre_tail_range = 1:(tail_start - 1)
        pre_tail_charge = isempty(pre_tail_range) ? 0.0 : sum(charging[pre_tail_range])
        pre_tail_discharge = isempty(pre_tail_range) ? 0.0 : sum(discharging[pre_tail_range])

        push!(rows, (
            case_name = String(case_name),
            clearing = Int(clearing_num),
            current_hour = Int(details[:current_hour]),
            look_ahead = look_ahead,
            soc_end_window = float(details[:storage_soc_end_window]),
            marginal_soc_value = -float(details[:storage_initial_soc_dual]),
            tail_charge_mwh = tail_charge,
            tail_discharge_mwh = tail_discharge,
            tail_net_discharge_mwh = tail_discharge - tail_charge,
            total_charge_mwh = total_charge,
            total_discharge_mwh = total_discharge,
            pre_tail_charge_mwh = pre_tail_charge,
            pre_tail_discharge_mwh = pre_tail_discharge,
            soc_start = float(details[:storage_soc_start]),
            share_charge_last6 = safe_ratio(tail_charge, total_charge),
            share_discharge_last6 = safe_ratio(tail_discharge, total_discharge),
        ))
    end

    return rows
end

function collect_relative_hour_profiles(case_name::AbstractString, all_results::Dict)
    clearing_details = all_results[:clearing_details]
    grouped_charge = Dict{Int, Vector{Float64}}()
    grouped_discharge = Dict{Int, Vector{Float64}}()

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        charging = Float64.(details[:charging])
        discharging = Float64.(details[:discharging])
        look_ahead = Int(details[:look_ahead])

        for h in 1:look_ahead
            rel_to_end = look_ahead - h + 1
            push!(get!(grouped_charge, rel_to_end, Float64[]), charging[h])
            push!(get!(grouped_discharge, rel_to_end, Float64[]), discharging[h])
        end
    end

    rel_hours = sort(collect(keys(grouped_charge)))
    return (
        case_name = String(case_name),
        rel_hours = rel_hours,
        avg_charge = [mean(grouped_charge[h]) for h in rel_hours],
        avg_discharge = [mean(grouped_discharge[h]) for h in rel_hours],
    )
end

function case_style(case_name::AbstractString)
    return occursin("Fixed", case_name) ? (:steelblue, :circle) : (:darkorange, :diamond)
end

function fixed_cycle_sequence(cfg::Dict)
    rh = cfg["rolling_horizon"]
    max_look_ahead = Int(rh["look_ahead_window"])
    min_look_ahead = Int(get(rh, "fixed_horizon_min_window", max_look_ahead))
    reclear_freq = Int(rh["reclear_frequency"])

    sequence = Int[]
    current = max_look_ahead
    while true
        push!(sequence, current)
        next_value = current - reclear_freq
        next_value >= min_look_ahead || break
        current = next_value
    end
    return sequence
end

function writable_output_path(path::AbstractString)
    if !isfile(path)
        return String(path)
    end

    stem, ext = splitext(String(path))
    candidate = String(path)
    suffix = 2
    while true
        try
            io = open(candidate, "a")
            close(io)
            return candidate
        catch
            candidate = "$(stem)_$(suffix)$(ext)"
            suffix += 1
        end
    end
end

function collect_fixed_cycle_phase_rows(case_name::AbstractString, all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    cycle = fixed_cycle_sequence(cfg)
    cycle_len = length(cycle)
    rows = NamedTuple[]

    for (idx, clearing_num) in enumerate(sort(collect(keys(clearing_details))))
        details = clearing_details[clearing_num]
        pseudo_look_ahead = cycle[mod1(idx, cycle_len)]
        push!(rows, (
            case_name = String(case_name),
            clearing = Int(clearing_num),
            current_hour = Int(details[:current_hour]),
            cycle_index = mod1(idx, cycle_len),
            pseudo_look_ahead = pseudo_look_ahead,
            marginal_soc_value = -float(details[:storage_initial_soc_dual]),
        ))
    end

    return rows
end

function grouped_metric(rows::Vector{<:NamedTuple}, metric::Symbol)
    grouped = Dict{Int, Vector{Float64}}()
    for row in rows
        push!(get!(grouped, row.look_ahead, Float64[]), Float64(getproperty(row, metric)))
    end

    look_aheads = sort(collect(keys(grouped)))
    means = [mean(grouped[look_ahead]) for look_ahead in look_aheads]
    return look_aheads, means
end

function plot_last6_energy_vs_lookahead(case_rows::Dict{String, Vector{NamedTuple}})
    p_charge = plot(
        xlabel="Current look-ahead (h)",
        ylabel="Average last-6h charging (MWh)",
        title="Charging in the Last 6 Visible Hours",
        legend=:topright,
        linewidth=3,
        markersize=6,
        size=(1000, 420),
    )
    p_discharge = plot(
        xlabel="Current look-ahead (h)",
        ylabel="Average last-6h discharging (MWh)",
        title="Discharging in the Last 6 Visible Hours",
        legend=:topright,
        linewidth=3,
        markersize=6,
        size=(1000, 420),
    )

    for case_name in ["Fixed 36h", "Rolling 36h"]
        rows = case_rows[case_name]
        color, marker = case_style(case_name)

        look_aheads_charge, charge_means = grouped_metric(rows, :tail_charge_mwh)
        plot!(
            p_charge,
            look_aheads_charge,
            charge_means,
            label=case_name,
            color=color,
            marker=marker,
        )

        look_aheads_discharge, discharge_means = grouped_metric(rows, :tail_discharge_mwh)
        plot!(
            p_discharge,
            look_aheads_discharge,
            discharge_means,
            label=case_name,
            color=color,
            marker=marker,
        )
    end

    return plot(p_charge, p_discharge, layout=(2, 1), size=(1000, 820), plot_title="End-of-Horizon Activity vs Visible Horizon")
end

function plot_horizon_end_metrics(case_rows::Dict{String, Vector{NamedTuple}})
    metric_specs = [
        (:soc_end_window, "Average SOC at End of Visible Window", "MWh"),
        (:share_charge_last6, "Share of Charging in Last 6 Hours", "Share"),
        (:share_discharge_last6, "Share of Discharging in Last 6 Hours", "Share"),
    ]

    panels = Any[]
    for (metric, title_text, ylabel_text) in metric_specs
        p = plot(
            xlabel="Current look-ahead (h)",
            ylabel=ylabel_text,
            title=title_text,
            legend=:topright,
            linewidth=3,
            markersize=6,
            size=(1000, 320),
        )

        for case_name in ["Fixed 36h", "Rolling 36h"]
            rows = case_rows[case_name]
            color, marker = case_style(case_name)
            look_aheads, means = grouped_metric(rows, metric)
            plot!(
                p,
                look_aheads,
                means,
                label=case_name,
                color=color,
                marker=marker,
            )
        end

        if metric in (:share_charge_last6, :share_discharge_last6)
            ylims!(p, 0, 1)
        end

        push!(panels, p)
    end

    return plot(panels..., layout=(3, 1), size=(1000, 1120), plot_title="Horizon-End Diagnostics vs Visible Horizon")
end

function plot_marginal_soc_value_cycle_comparison(case_phase_rows::Dict{String, Vector{NamedTuple}})
    p = plot(
        xlabel="Comparable fixed-cycle look-ahead (h)",
        ylabel="Average marginal SOC value (EUR/MWh)",
        title="Average Marginal SOC Value Across the Fixed-Horizon Cycle",
        legend=:topright,
        linewidth=3,
        markersize=6,
        size=(1320, 680),
        left_margin=28Plots.mm,
        right_margin=16Plots.mm,
        top_margin=12Plots.mm,
        bottom_margin=22Plots.mm,
        guidefontsize=18,
        tickfontsize=14,
        titlefontsize=22,
        legendfontsize=14,
    )

    for case_name in ["Fixed 36h", "Rolling 36h"]
        rows = case_phase_rows[case_name]
        grouped = Dict{Int, Vector{Float64}}()
        for row in rows
            push!(get!(grouped, row.pseudo_look_ahead, Float64[]), row.marginal_soc_value)
        end
        x = sort(collect(keys(grouped)))
        y = [mean(grouped[k]) for k in x]
        color, marker = case_style(case_name)
        plot!(p, x, y, label=case_name, color=color, marker=marker)
    end

    return p
end

function plot_relative_hour_to_end_profiles(case_profiles::Dict{String, NamedTuple})
    p_charge = plot(
        xlabel="Relative hour-to-end (1 = final visible hour)",
        ylabel="Average charging (MWh)",
        title="Average Charging by Relative Hour-to-End",
        legend=:topright,
        linewidth=3,
        markersize=5,
        size=(1000, 420),
    )
    p_discharge = plot(
        xlabel="Relative hour-to-end (1 = final visible hour)",
        ylabel="Average discharging (MWh)",
        title="Average Discharging by Relative Hour-to-End",
        legend=:topright,
        linewidth=3,
        markersize=5,
        size=(1000, 420),
    )

    for case_name in ["Fixed 36h", "Rolling 36h"]
        profile = case_profiles[case_name]
        color, marker = case_style(case_name)
        plot!(p_charge, profile.rel_hours, profile.avg_charge, label=case_name, color=color, marker=marker)
        plot!(p_discharge, profile.rel_hours, profile.avg_discharge, label=case_name, color=color, marker=marker)
    end

    xflip!(p_charge)
    xflip!(p_discharge)
    return plot(p_charge, p_discharge, layout=(2, 1), size=(1000, 820), plot_title="Storage Activity by Distance to Horizon End")
end

function plot_matched_phase_storage_trajectories(case_rows::Dict{String, Vector{NamedTuple}}, case_phase_rows::Dict{String, Vector{NamedTuple}})
    metrics = [
        (:soc_start, "Average Storage SOC at Start of Clearing", "MWh"),
        (:pre_tail_charge_mwh, "Average Charge Before Last 6 Hours", "MWh"),
        (:pre_tail_discharge_mwh, "Average Discharge Before Last 6 Hours", "MWh"),
        (:tail_charge_mwh, "Average Charge in Last 6 Hours", "MWh"),
        (:tail_discharge_mwh, "Average Discharge in Last 6 Hours", "MWh"),
    ]

    panels = Any[]
    for (metric, title_text, ylabel_text) in metrics
        p = plot(
            xlabel="Comparable fixed-cycle look-ahead (h)",
            ylabel=ylabel_text,
            title=title_text,
            legend=:topright,
            linewidth=3,
            markersize=5,
            size=(1000, 320),
        )

        for case_name in ["Fixed 36h", "Rolling 36h"]
            grouped = Dict{Int, Vector{Float64}}()
            phase_rows = case_phase_rows[case_name]
            base_rows = case_rows[case_name]
            @assert length(phase_rows) == length(base_rows) "Phase rows and base rows must align for $case_name"
            for idx in eachindex(base_rows)
                look = phase_rows[idx].pseudo_look_ahead
                push!(get!(grouped, look, Float64[]), Float64(getproperty(base_rows[idx], metric)))
            end
            x = sort(collect(keys(grouped)))
            y = [mean(grouped[k]) for k in x]
            color, marker = case_style(case_name)
            plot!(p, x, y, label=case_name, color=color, marker=marker)
        end

        push!(panels, p)
    end

    return plot(panels..., layout=(5, 1), size=(1000, 1750), plot_title="Matched-Phase Storage Trajectories")
end

function write_summary(case_rows::Dict{String, Vector{NamedTuple}}, output_path::AbstractString)
    open(output_path, "w") do io
        println(io, "case_name,look_ahead,avg_soc_end_window,avg_marginal_soc_value,avg_tail_charge_mwh,avg_tail_discharge_mwh,avg_share_charge_last6,avg_share_discharge_last6,n_clearings")
        for case_name in ["Fixed 36h", "Rolling 36h"]
            rows = case_rows[case_name]
            look_aheads = sort(unique(row.look_ahead for row in rows))
            for look_ahead in look_aheads
                subset = filter(row -> row.look_ahead == look_ahead, rows)
                @printf(
                    io,
                    "%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d\n",
                    case_name,
                    look_ahead,
                    mean(row.soc_end_window for row in subset),
                    mean(row.marginal_soc_value for row in subset),
                    mean(row.tail_charge_mwh for row in subset),
                    mean(row.tail_discharge_mwh for row in subset),
                    mean(row.share_charge_last6 for row in subset),
                    mean(row.share_discharge_last6 for row in subset),
                    length(subset),
                )
            end
        end
    end
end

function write_cycle_summary(case_phase_rows::Dict{String, Vector{NamedTuple}}, output_path::AbstractString)
    open(output_path, "w") do io
        println(io, "case_name,pseudo_look_ahead,avg_marginal_soc_value,n_clearings")
        for case_name in ["Fixed 36h", "Rolling 36h"]
            rows = case_phase_rows[case_name]
            look_aheads = sort(unique(row.pseudo_look_ahead for row in rows))
            for look_ahead in look_aheads
                subset = filter(row -> row.pseudo_look_ahead == look_ahead, rows)
                @printf(
                    io,
                    "%s,%d,%.6f,%d\n",
                    case_name,
                    look_ahead,
                    mean(row.marginal_soc_value for row in subset),
                    length(subset),
                )
            end
        end
    end
end

function write_matched_phase_storage_summary(case_rows::Dict{String, Vector{NamedTuple}}, case_phase_rows::Dict{String, Vector{NamedTuple}}, output_path::AbstractString)
    open(output_path, "w") do io
        println(io, "case_name,pseudo_look_ahead,avg_soc_start,avg_pre_tail_charge_mwh,avg_pre_tail_discharge_mwh,avg_tail_charge_mwh,avg_tail_discharge_mwh,n_clearings")
        for case_name in ["Fixed 36h", "Rolling 36h"]
            grouped = Dict{Int, Vector{NamedTuple}}()
            phase_rows = case_phase_rows[case_name]
            base_rows = case_rows[case_name]
            @assert length(phase_rows) == length(base_rows) "Phase rows and base rows must align for $case_name"
            for idx in eachindex(base_rows)
                look = phase_rows[idx].pseudo_look_ahead
                push!(get!(grouped, look, NamedTuple[]), base_rows[idx])
            end

            for look_ahead in sort(collect(keys(grouped)))
                subset = grouped[look_ahead]
                @printf(
                    io,
                    "%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%d\n",
                    case_name,
                    look_ahead,
                    mean(row.soc_start for row in subset),
                    mean(row.pre_tail_charge_mwh for row in subset),
                    mean(row.pre_tail_discharge_mwh for row in subset),
                    mean(row.tail_charge_mwh for row in subset),
                    mean(row.tail_discharge_mwh for row in subset),
                    length(subset),
                )
            end
        end
    end
end

function main(args)
    run_dir = resolve_run_dir(args)
    output_dir = joinpath(run_dir, "_horizon_end_effects")
    isdir(output_dir) || mkpath(output_dir)

    case_rows = Dict{String, Vector{NamedTuple}}()
    case_phase_rows = Dict{String, Vector{NamedTuple}}()
    case_profiles = Dict{String, NamedTuple}()
    for (case_name, case_folder) in CASE_FOLDERS
        all_results, cfg = load_case(run_dir, case_folder)
        case_rows[case_name] = collect_horizon_end_rows(case_name, all_results)
        case_phase_rows[case_name] = collect_fixed_cycle_phase_rows(case_name, all_results, cfg)
        case_profiles[case_name] = collect_relative_hour_profiles(case_name, all_results)
    end

    p1 = plot_last6_energy_vs_lookahead(case_rows)
    p2 = plot_horizon_end_metrics(case_rows)
    p3 = plot_marginal_soc_value_cycle_comparison(case_phase_rows)
    p4 = plot_relative_hour_to_end_profiles(case_profiles)
    p5 = plot_matched_phase_storage_trajectories(case_rows, case_phase_rows)
    savefig(p1, writable_output_path(joinpath(output_dir, "horizon_end_last6_energy_vs_lookahead.png")))
    savefig(p2, writable_output_path(joinpath(output_dir, "horizon_end_metrics_vs_lookahead.png")))
    savefig(p3, writable_output_path(joinpath(output_dir, "marginal_soc_value_fixed_cycle_comparison.png")))
    savefig(p4, writable_output_path(joinpath(output_dir, "relative_hour_to_end_charge_discharge.png")))
    savefig(p5, writable_output_path(joinpath(output_dir, "matched_phase_storage_trajectories.png")))
    write_summary(case_rows, writable_output_path(joinpath(output_dir, "horizon_end_summary.csv")))
    write_cycle_summary(case_phase_rows, writable_output_path(joinpath(output_dir, "marginal_soc_value_fixed_cycle_summary.csv")))
    write_matched_phase_storage_summary(case_rows, case_phase_rows, writable_output_path(joinpath(output_dir, "matched_phase_storage_summary.csv")))

    println("Saved horizon-end diagnostics to: $output_dir")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end

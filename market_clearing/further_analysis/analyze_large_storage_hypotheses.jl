using Serialization
using Statistics
using CSV
using DataFrames
using Plots
using Printf
using JuMP

include(joinpath(@__DIR__, "..", "src", "costs.jl"))

const DEFAULT_RUN_ROOT = joinpath("Results", "thesis_runs")
const CASE_ORDER = [
    ("High-storage Rolling 36h", "high_storage_rolling_36h", 36),
    ("High-storage Rolling 48h", "high_storage_rolling_48h", 48),
    ("High-storage Rolling 72h", "high_storage_rolling_72h", 72),
]
const LAST_HOURS = 6

function latest_high_storage_run(root::AbstractString)
    entries = filter(name -> startswith(name, "high_storage_"), readdir(root))
    isempty(entries) && error("No high-storage run folders found under $root")
    sort!(entries)

    required_folders = [folder for (_, folder, _) in CASE_ORDER]
    for entry in reverse(entries)
        run_dir = joinpath(root, entry)
        if all(isfile(joinpath(run_dir, folder, "all_results.jls")) for folder in required_folders)
            return run_dir
        end
    end

    error("No completed high-storage run found under $root")
end

function resolve_run_dir(args)
    return isempty(args) ? latest_high_storage_run(DEFAULT_RUN_ROOT) : args[1]
end

function writable_output_path(path::AbstractString)
    parent = dirname(String(path))
    isdir(parent) || mkpath(parent)
    return String(path)
end

function save_plot_safe(plot_obj, path::AbstractString)
    output_path = writable_output_path(path)
    savefig(plot_obj, output_path)
    return output_path
end

function load_case(run_dir::AbstractString, case_folder::AbstractString)
    case_dir = joinpath(run_dir, case_folder)
    isdir(case_dir) || error("Missing case directory: $case_dir")
    all_results = deserialize(joinpath(case_dir, "all_results.jls"))
    cfg = deserialize(joinpath(case_dir, "cfg.jls"))
    return all_results, cfg
end

function average_executed_price(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    total_price = 0.0
    total_hours = 0

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        for h in 1:executed_hours
            total_price += details[:prices][h]
            total_hours += 1
        end
    end

    return total_hours > 0 ? total_price / total_hours : 0.0
end

function normalization_days(cfg::Dict, all_results::Dict)
    sim_days = Int(cfg["rolling_horizon"]["simulation_days"])
    actual_days = executed_days(all_results)
    return haskey(cfg["rolling_horizon"], "comparable_delivery_hours_override") ? actual_days : sim_days
end

function anchored_forecast_std(lead_time::Int, max_noise_std::Float64)
    lead_time <= 1 && return 0.0

    anchor_hours = [1, 36, 48, 72]
    anchor_stds = [
        0.0,
        max_noise_std,
        max_noise_std + 0.05,
        max_noise_std + 0.10,
    ]

    if lead_time <= anchor_hours[2]
        return anchor_stds[2] * sqrt((lead_time - 1) / (anchor_hours[2] - 1))
    end

    if lead_time >= anchor_hours[end]
        return anchor_stds[end]
    end

    for idx in 2:(length(anchor_hours) - 1)
        h1 = anchor_hours[idx]
        h2 = anchor_hours[idx + 1]
        s1 = anchor_stds[idx]
        s2 = anchor_stds[idx + 1]
        if h1 < lead_time <= h2
            frac = (lead_time - h1) / (h2 - h1)
            curved_frac = sqrt(frac)
            return s1 + (s2 - s1) * curved_frac
        end
    end

    return anchor_stds[end]
end

function dispatch_value(details::Dict, gen::AbstractString, h::Int)
    return details[:g_planned][gen, h]
end

function collect_case_kpi_row(case_name::AbstractString, look_ahead::Int, all_results::Dict, cfg::Dict)
    welfare = calculate_social_welfare(all_results, cfg)
    storage = calculate_storage_revenue(all_results, cfg)
    days = normalization_days(cfg, all_results)
    total_curtailment = haskey(all_results, :curtailment_energy) ? sum(all_results[:curtailment_energy]) : 0.0
    total_imbalance = haskey(all_results, :imbalance_energy) ? sum(all_results[:imbalance_energy]) : 0.0
    spread = storage[:avg_discharge_price] - storage[:avg_charging_price]

    return (
        case_name = String(case_name),
        look_ahead = Int(look_ahead),
        normalized_days = days,
        social_welfare_per_day = welfare[:social_welfare] / days,
        demand_value_per_day = welfare[:total_demand_value] / days,
        generation_cost_per_day = welfare[:total_generation_cost] / days,
        avg_executed_price = average_executed_price(all_results),
        wind_curtailment_per_day = total_curtailment / days,
        storage_revenue_per_day = storage[:net_revenue] / days,
        storage_charge_per_day = storage[:total_charging_energy] / days,
        storage_discharge_per_day = storage[:total_discharge_energy] / days,
        storage_throughput_per_day = (storage[:total_charging_energy] + storage[:total_discharge_energy]) / days,
        avg_charge_price = storage[:avg_charging_price],
        avg_discharge_price = storage[:avg_discharge_price],
        avg_spread = spread,
        imbalance_mwh_per_day = total_imbalance / days,
    )
end

function collect_executed_hour_rows(case_name::AbstractString, look_ahead::Int, all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    rows = NamedTuple[]

    bid_base = float(cfg["dispatchableGenerators"]["Base"]["bidPrice"])
    bid_mid = float(cfg["dispatchableGenerators"]["Mid"]["bidPrice"])
    bid_peak = float(cfg["dispatchableGenerators"]["Peak"]["bidPrice"])

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        current_hour = details[:current_hour]

        for h in 1:executed_hours
            global_hour = current_hour + h - 1
            base = dispatch_value(details, "Base", h)
            mid = dispatch_value(details, "Mid", h)
            peak = dispatch_value(details, "Peak", h)
            wind = dispatch_value(details, "Wind", h)
            solar = dispatch_value(details, "Solar", h)
            charge = details[:charging][h]
            discharge = details[:discharging][h]
            flex_demand = details[:demand_flex][h]
            demand_total = details[:demand_base][h] + flex_demand
            thermal_cost = base * bid_base + mid * bid_mid + peak * bid_peak

            push!(rows, (
                case_name = String(case_name),
                look_ahead = Int(look_ahead),
                clearing = Int(clearing_num),
                global_hour = Int(global_hour),
                hour_of_day = Int(mod(global_hour - 1, 24) + 1),
                price = float(details[:prices][h]),
                flex_demand = float(flex_demand),
                total_demand = float(demand_total),
                charge = float(charge),
                discharge = float(discharge),
                net_discharge = float(discharge - charge),
                base = float(base),
                mid = float(mid),
                peak = float(peak),
                wind = float(wind),
                solar = float(solar),
                thermal_cost = float(thermal_cost),
                wind_curtailment = float(get(details, :wind_curtailment_h1, 0.0)),
            ))
        end
    end

    return rows
end

function collect_clearing_rows(case_name::AbstractString, look_ahead::Int, all_results::Dict)
    clearing_details = all_results[:clearing_details]
    rows = NamedTuple[]

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        charging = Float64.(details[:charging])
        discharging = Float64.(details[:discharging])
        look = Int(details[:look_ahead])
        tail_start = max(1, look - LAST_HOURS + 1)
        tail_range = tail_start:look

        push!(rows, (
            case_name = String(case_name),
            look_ahead = Int(look_ahead),
            clearing = Int(clearing_num),
            current_hour = Int(details[:current_hour]),
            soc_start = float(details[:storage_soc_start]),
            soc_end_executed = float(details[:storage_soc_end_executed]),
            soc_end_window = float(details[:storage_soc_end_window]),
            marginal_soc_value = -float(details[:storage_initial_soc_dual]),
            total_charge = sum(charging),
            total_discharge = sum(discharging),
            tail_charge = sum(charging[tail_range]),
            tail_discharge = sum(discharging[tail_range]),
            share_charge_last6 = sum(charging) > 1e-9 ? sum(charging[tail_range]) / sum(charging) : 0.0,
            share_discharge_last6 = sum(discharging) > 1e-9 ? sum(discharging[tail_range]) / sum(discharging) : 0.0,
        ))
    end

    return rows
end

function safe_cor(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    (length(x) > 1 && std(x) > 0 && std(y) > 0) ? cor(x, y) : NaN
end

function paired_delta_df(df::DataFrame, left_case::AbstractString, right_case::AbstractString)
    left = select(
        filter(:case_name => ==(left_case), df),
        :global_hour,
        :price,
        :flex_demand,
        :net_discharge,
        :thermal_cost,
        :wind_curtailment,
        :mid,
        :peak,
    )
    rename!(left,
        :price => :price_left,
        :flex_demand => :flex_demand_left,
        :net_discharge => :net_discharge_left,
        :thermal_cost => :thermal_cost_left,
        :wind_curtailment => :wind_curtailment_left,
        :mid => :mid_left,
        :peak => :peak_left,
    )

    right = select(
        filter(:case_name => ==(right_case), df),
        :global_hour,
        :price,
        :flex_demand,
        :net_discharge,
        :thermal_cost,
        :wind_curtailment,
        :mid,
        :peak,
    )
    rename!(right,
        :price => :price_right,
        :flex_demand => :flex_demand_right,
        :net_discharge => :net_discharge_right,
        :thermal_cost => :thermal_cost_right,
        :wind_curtailment => :wind_curtailment_right,
        :mid => :mid_right,
        :peak => :peak_right,
    )

    paired = innerjoin(left, right, on=:global_hour)
    paired.delta_price = paired.price_right .- paired.price_left
    paired.delta_flex_demand = paired.flex_demand_right .- paired.flex_demand_left
    paired.delta_net_discharge = paired.net_discharge_right .- paired.net_discharge_left
    paired.delta_thermal_cost = paired.thermal_cost_right .- paired.thermal_cost_left
    paired.delta_mid_peak = (paired.mid_right .+ paired.peak_right) .- (paired.mid_left .+ paired.peak_left)
    paired.delta_curtailment = paired.wind_curtailment_right .- paired.wind_curtailment_left
    return paired
end

function print_hypothesis_summary(kpi_df::DataFrame, executed_df::DataFrame, clearing_df::DataFrame, cfg::Dict)
    println()
    println("Large-storage hypothesis diagnostics")
    println("="^84)
    println()

    println("Hypothesis 1: higher cost can still be welfare-improving if demand value rises more.")
    for row in eachrow(sort(kpi_df, :look_ahead))
        @printf(
            "  %2dh | welfare/day = %.0f | demand value/day = %.0f | generation cost/day = %.0f | flex spread = %.2f\n",
            row.look_ahead,
            row.social_welfare_per_day,
            row.demand_value_per_day,
            row.generation_cost_per_day,
            row.avg_spread,
        )
    end
    println()

    println("Hypothesis 2: longer look-ahead makes the battery more selective, not necessarily more active.")
    for row in eachrow(sort(kpi_df, :look_ahead))
        @printf(
            "  %2dh | throughput/day = %.1f | revenue/day = %.0f | avg charge price = %.2f | avg discharge price = %.2f\n",
            row.look_ahead,
            row.storage_throughput_per_day,
            row.storage_revenue_per_day,
            row.avg_charge_price,
            row.avg_discharge_price,
        )
    end
    println()

    println("Hypothesis 3: the outer horizon adds noisier forecast information.")
    max_noise_std = float(cfg["rolling_horizon"]["forecast_noise_std"])
    for h in [1, 12, 24, 36, 48, 72]
        @printf("  lead %2dh -> forecast std %.4f\n", h, anchored_forecast_std(h, max_noise_std))
    end
    println()

    println("Hypothesis 4: horizon-end incentives may keep SOC valuable and bias behavior.")
    grouped = combine(
        groupby(clearing_df, :look_ahead),
        :marginal_soc_value => mean => :avg_marginal_soc_value,
        :soc_end_window => mean => :avg_soc_end_window,
        :share_charge_last6 => mean => :avg_share_charge_last6,
        :share_discharge_last6 => mean => :avg_share_discharge_last6,
    )
    for row in eachrow(sort(grouped, :look_ahead))
        @printf(
            "  %2dh | avg marginal SOC value = %.2f | avg SOC end window = %.1f | charge share in last 6h = %.3f | discharge share in last 6h = %.3f\n",
            row.look_ahead,
            row.avg_marginal_soc_value,
            row.avg_soc_end_window,
            row.avg_share_charge_last6,
            row.avg_share_discharge_last6,
        )
    end
    println()

    pair_48_36 = paired_delta_df(executed_df, "High-storage Rolling 36h", "High-storage Rolling 48h")
    pair_72_48 = paired_delta_df(executed_df, "High-storage Rolling 48h", "High-storage Rolling 72h")
    println("Aligned delta checks")
    println("-"^84)
    @printf(
        "  48h - 36h: mean delta flex demand = %.4f | mean delta cost = %.2f | corr(delta cost, delta flex demand) = %.4f\n",
        mean(pair_48_36.delta_flex_demand),
        mean(pair_48_36.delta_thermal_cost),
        safe_cor(pair_48_36.delta_thermal_cost, pair_48_36.delta_flex_demand),
    )
    @printf(
        "  72h - 48h: mean delta flex demand = %.4f | mean delta cost = %.2f | corr(delta cost, delta flex demand) = %.4f\n",
        mean(pair_72_48.delta_flex_demand),
        mean(pair_72_48.delta_thermal_cost),
        safe_cor(pair_72_48.delta_thermal_cost, pair_72_48.delta_flex_demand),
    )
end

function plot_welfare_decomposition(kpi_df::DataFrame, output_dir::AbstractString)
    df = sort(kpi_df, :look_ahead)
    x = df.look_ahead

    p1 = plot(
        x,
        [df.social_welfare_per_day, df.demand_value_per_day, df.generation_cost_per_day],
        label=["Welfare/day" "Demand value/day" "Generation cost/day"],
        marker=[:circle :diamond :square],
        linewidth=3,
        xlabel="Look-ahead (h)",
        ylabel="EUR/day",
        title="Welfare Decomposition Across Large-Storage Horizons",
        size=(1000, 500),
    )

    p2 = plot(
        x,
        [df.storage_throughput_per_day, df.storage_revenue_per_day, df.avg_spread],
        label=["Storage throughput/day (MWh)" "Storage revenue/day (EUR)" "Avg charge-discharge spread (EUR/MWh)"],
        marker=[:circle :diamond :square],
        linewidth=3,
        xlabel="Look-ahead (h)",
        ylabel="Level",
        title="Battery Activity Becomes More Selective",
        size=(1000, 500),
    )

    combined = plot(p1, p2, layout=(2, 1), size=(1000, 950))
    save_plot_safe(combined, joinpath(output_dir, "hypothesis_01_welfare_and_selectivity.png"))
    return combined
end

function plot_forecast_noise_curve(cfg::Dict, output_dir::AbstractString)
    max_noise_std = float(cfg["rolling_horizon"]["forecast_noise_std"])
    leads = 1:72
    stds = [anchored_forecast_std(h, max_noise_std) for h in leads]

    p = plot(
        leads,
        stds,
        linewidth=3,
        color=:firebrick,
        xlabel="Lead time (h)",
        ylabel="Forecast error std",
        title="Forecast Noise Increases with Look-ahead Distance",
        size=(1000, 450),
        label="Anchored forecast std",
    )
    vline!(p, [36, 48, 72], color=[:steelblue :darkorange :forestgreen], linestyle=:dash, label=["36h horizon" "48h horizon" "72h horizon"])
    save_plot_safe(p, joinpath(output_dir, "hypothesis_02_forecast_noise_curve.png"))
    return p
end

function plot_horizon_end_diagnostics(clearing_df::DataFrame, output_dir::AbstractString)
    grouped = combine(
        groupby(clearing_df, :look_ahead),
        :marginal_soc_value => mean => :avg_marginal_soc_value,
        :soc_end_window => mean => :avg_soc_end_window,
        :share_charge_last6 => mean => :avg_share_charge_last6,
        :share_discharge_last6 => mean => :avg_share_discharge_last6,
    )
    grouped = sort(grouped, :look_ahead)

    x = grouped.look_ahead
    p1 = plot(
        x,
        [grouped.avg_marginal_soc_value, grouped.avg_soc_end_window],
        label=["Avg marginal SOC value" "Avg SOC at visible horizon end"],
        marker=[:circle :diamond],
        linewidth=3,
        xlabel="Look-ahead (h)",
        ylabel="Level",
        title="Storage End-of-Horizon Value",
        size=(1000, 450),
    )

    p2 = plot(
        x,
        [grouped.avg_share_charge_last6, grouped.avg_share_discharge_last6],
        label=["Share of charging in last 6h" "Share of discharging in last 6h"],
        marker=[:circle :diamond],
        linewidth=3,
        xlabel="Look-ahead (h)",
        ylabel="Share",
        ylims=(0, 1),
        title="How Much Battery Activity Sits Near the Horizon End",
        size=(1000, 450),
    )

    combined = plot(p1, p2, layout=(2, 1), size=(1000, 900))
    save_plot_safe(combined, joinpath(output_dir, "hypothesis_03_horizon_end_effects.png"))
    return combined
end

function plot_delta_evidence(executed_df::DataFrame, output_dir::AbstractString)
    pair_48_36 = paired_delta_df(executed_df, "High-storage Rolling 36h", "High-storage Rolling 48h")
    pair_72_48 = paired_delta_df(executed_df, "High-storage Rolling 48h", "High-storage Rolling 72h")

    p1 = scatter(
        pair_48_36.delta_flex_demand,
        pair_48_36.delta_thermal_cost,
        alpha=0.5,
        markersize=3,
        xlabel="48h - 36h delta flexible demand (MWh/h)",
        ylabel="48h - 36h delta thermal cost (EUR/h)",
        title="Cost Increase vs Extra Demand Value Proxy",
        label="",
    )
    p2 = scatter(
        pair_48_36.delta_net_discharge,
        pair_48_36.delta_thermal_cost,
        alpha=0.5,
        markersize=3,
        xlabel="48h - 36h delta net discharge (MWh/h)",
        ylabel="48h - 36h delta thermal cost (EUR/h)",
        title="Battery Shift vs Thermal Cost",
        label="",
    )
    p3 = scatter(
        pair_72_48.delta_flex_demand,
        pair_72_48.delta_thermal_cost,
        alpha=0.5,
        markersize=3,
        xlabel="72h - 48h delta flexible demand (MWh/h)",
        ylabel="72h - 48h delta thermal cost (EUR/h)",
        title="Further Horizon: Cost vs Flex Demand",
        label="",
    )
    p4 = scatter(
        pair_72_48.delta_net_discharge,
        pair_72_48.delta_thermal_cost,
        alpha=0.5,
        markersize=3,
        xlabel="72h - 48h delta net discharge (MWh/h)",
        ylabel="72h - 48h delta thermal cost (EUR/h)",
        title="Further Horizon: Battery Shift vs Cost",
        label="",
    )

    combined = plot(p1, p2, p3, p4, layout=(2, 2), size=(1200, 900))
    save_plot_safe(combined, joinpath(output_dir, "hypothesis_04_aligned_hourly_deltas.png"))

    CSV.write(joinpath(output_dir, "aligned_deltas_48_minus_36.csv"), pair_48_36)
    CSV.write(joinpath(output_dir, "aligned_deltas_72_minus_48.csv"), pair_72_48)
    return combined
end

function main(args)
    run_dir = resolve_run_dir(args)
    println("Analyzing run: $run_dir")
    output_dir = joinpath(run_dir, "_large_storage_hypothesis_analysis")
    isdir(output_dir) || mkpath(output_dir)

    kpi_rows = NamedTuple[]
    executed_rows = NamedTuple[]
    clearing_rows = NamedTuple[]
    representative_cfg = nothing

    for (case_name, folder_name, look_ahead) in CASE_ORDER
        all_results, cfg = load_case(run_dir, folder_name)
        representative_cfg = representative_cfg === nothing ? cfg : representative_cfg
        push!(kpi_rows, collect_case_kpi_row(case_name, look_ahead, all_results, cfg))
        append!(executed_rows, collect_executed_hour_rows(case_name, look_ahead, all_results, cfg))
        append!(clearing_rows, collect_clearing_rows(case_name, look_ahead, all_results))
    end

    kpi_df = DataFrame(kpi_rows)
    executed_df = DataFrame(executed_rows)
    clearing_df = DataFrame(clearing_rows)

    CSV.write(joinpath(output_dir, "large_storage_kpi_diagnostics.csv"), kpi_df)
    CSV.write(joinpath(output_dir, "large_storage_executed_hour_metrics.csv"), executed_df)
    CSV.write(joinpath(output_dir, "large_storage_clearing_diagnostics.csv"), clearing_df)

    print_hypothesis_summary(kpi_df, executed_df, clearing_df, representative_cfg)
    plot_welfare_decomposition(kpi_df, output_dir)
    plot_forecast_noise_curve(representative_cfg, output_dir)
    plot_horizon_end_diagnostics(clearing_df, output_dir)
    plot_delta_evidence(executed_df, output_dir)

    println()
    println("Saved large-storage hypothesis analysis to: $output_dir")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end

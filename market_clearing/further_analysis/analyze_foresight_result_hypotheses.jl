using JuMP
using Serialization
using Statistics
using CSV
using DataFrames
using Plots
using StatsPlots
using Printf

const RUN_DIR = normpath(joinpath(@__DIR__, "..", "Results", "thesis_runs", "foresight_20260509_145432"))
const CASE_FOLDERS = Dict(
    "Rolling 36h" => "rolling_36h",
    "Rolling 48h" => "rolling_48h",
    "Rolling 72h" => "rolling_72h",
)
const CASE_ORDER = ["Rolling 36h", "Rolling 48h", "Rolling 72h"]
const LAST_HOURS = 6
const COLOR_PURPLE = RGB(150/255, 41/255, 148/255)
const COLOR_GOLD = RGB(245/255, 187/255, 12/255)
const COLOR_TEAL = RGB(53/255, 134/255, 140/255)
const COLOR_BLUE = RGB(62/255, 106/255, 201/255)
const COLOR_CORAL = RGB(230/255, 118/255, 92/255)
const COLOR_GREEN = RGB(75/255, 156/255, 120/255)
const CASE_COLORS = Dict(
    "Rolling 36h" => RGB(0.725, 0.361, 0.859),
    "Rolling 48h" => RGB(0.961, 0.733, 0.047),
    "Rolling 72h" => RGB(0.216, 0.596, 0.792),
)

default(
    guidefontsize=10,
    tickfontsize=9,
    titlefontsize=11,
    legendfontsize=9,
)

function load_case(run_dir::AbstractString, case_folder::AbstractString)
    case_dir = joinpath(run_dir, case_folder)
    all_results = deserialize(joinpath(case_dir, "all_results.jls"))
    cfg = deserialize(joinpath(case_dir, "cfg.jls"))
    return all_results, cfg
end

function load_kpi_summary(run_dir::AbstractString)
    summary_dir = joinpath(run_dir, "_summary")
    for filename in ("kpi_summary.csv", "kpi_summary_fore2.csv")
        path = joinpath(summary_dir, filename)
        if isfile(path)
            return CSV.read(path, DataFrame)
        end
    end
    error("No KPI summary CSV found under $summary_dir")
end

dispatch_value(details::Dict, gen::AbstractString, h::Int) = details[:g_planned][gen, h]

function safe_cor(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    (length(x) > 1 && std(x) > 0 && std(y) > 0) ? cor(x, y) : NaN
end

function share_at_mask(values::AbstractVector{<:Real}, mask::AbstractVector{Bool})
    total = sum(values)
    return total > 1e-9 ? sum(values[mask]) / total : 0.0
end

function executed_hourly_df(case_name::AbstractString, all_results::Dict, cfg::Dict)
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
            hour_of_day = mod(global_hour - 1, 24) + 1
            base = dispatch_value(details, "Base", h)
            mid = dispatch_value(details, "Mid", h)
            peak = dispatch_value(details, "Peak", h)
            charge = Float64(details[:charging][h])
            discharge = Float64(details[:discharging][h])
            flex = Float64(details[:demand_flex][h])

            push!(rows, (
                case_name = String(case_name),
                clearing = Int(clearing_num),
                global_hour = Int(global_hour),
                hour_of_day = Int(hour_of_day),
                price = Float64(details[:prices][h]),
                charge = charge,
                discharge = discharge,
                net_discharge = discharge - charge,
                flex_demand = flex,
                mid_peak = Float64(mid + peak),
                thermal_cost = Float64(base * bid_base + mid * bid_mid + peak * bid_peak),
            ))
        end
    end

    return DataFrame(rows)
end

function clearing_summary_df(case_name::AbstractString, all_results::Dict)
    clearing_details = all_results[:clearing_details]
    rows = NamedTuple[]

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        look_ahead = Int(details[:look_ahead])
        charging = Float64.(details[:charging])
        discharging = Float64.(details[:discharging])
        prices = Float64.(details[:prices])
        tail_start = max(1, look_ahead - LAST_HOURS + 1)
        tail_range = tail_start:look_ahead
        low_cut = quantile(prices, 0.2)
        high_cut = quantile(prices, 0.8)

        push!(rows, (
            case_name = String(case_name),
            clearing = Int(clearing_num),
            current_hour = Int(details[:current_hour]),
            start_soc = Float64(details[:storage_soc_start]),
            end_soc_window = Float64(details[:storage_soc_end_window]),
            end_soc_executed = Float64(details[:storage_soc_end_executed]),
            marginal_soc_value = -Float64(details[:storage_initial_soc_dual]),
            share_charge_last6 = share_at_mask(charging, collect(1:look_ahead) .>= tail_start),
            share_discharge_last6 = share_at_mask(discharging, collect(1:look_ahead) .>= tail_start),
            share_charge_low20 = share_at_mask(charging, prices .<= low_cut),
            share_discharge_high20 = share_at_mask(discharging, prices .>= high_cut),
        ))
    end

    return DataFrame(rows)
end

function case_summary_row(df_case::DataFrame, clearing_df_case::DataFrame)
    prices = df_case.price
    low_cut = quantile(prices, 0.2)
    high_cut = quantile(prices, 0.8)
    avg_charge_price = sum(df_case.price .* df_case.charge) / max(sum(df_case.charge), 1e-9)
    avg_discharge_price = sum(df_case.price .* df_case.discharge) / max(sum(df_case.discharge), 1e-9)

    return (
        case_name = String(first(df_case.case_name)),
        executed_hours = nrow(df_case),
        avg_price = mean(df_case.price),
        avg_thermal_cost = mean(df_case.thermal_cost),
        avg_mid_peak = mean(df_case.mid_peak),
        avg_flex_demand = mean(df_case.flex_demand),
        avg_net_discharge = mean(df_case.net_discharge),
        throughput = sum(df_case.charge) + sum(df_case.discharge),
        avg_charge_price = avg_charge_price,
        avg_discharge_price = avg_discharge_price,
        charge_share_low20 = share_at_mask(df_case.charge, df_case.price .<= low_cut),
        discharge_share_high20 = share_at_mask(df_case.discharge, df_case.price .>= high_cut),
        avg_share_discharge_last6 = mean(clearing_df_case.share_discharge_last6),
        avg_end_soc_window = mean(clearing_df_case.end_soc_window),
        final_soc_executed = last(clearing_df_case.end_soc_executed),
    )
end

function paired_delta_df(df::DataFrame, left_case::AbstractString, right_case::AbstractString)
    cols = [:global_hour, :price, :thermal_cost, :net_discharge, :flex_demand, :mid_peak]
    left = select(filter(:case_name => ==(left_case), df), cols)
    right = select(filter(:case_name => ==(right_case), df), cols)
    rename!(left, Dict(name => Symbol(string(name), "_left") for name in propertynames(left) if name != :global_hour))
    rename!(right, Dict(name => Symbol(string(name), "_right") for name in propertynames(right) if name != :global_hour))

    paired = innerjoin(left, right, on=:global_hour)
    paired[!, :delta_price] = paired.price_right .- paired.price_left
    paired[!, :delta_thermal_cost] = paired.thermal_cost_right .- paired.thermal_cost_left
    paired[!, :delta_net_discharge] = paired.net_discharge_right .- paired.net_discharge_left
    paired[!, :delta_flex_demand] = paired.flex_demand_right .- paired.flex_demand_left
    paired[!, :delta_mid_peak] = paired.mid_peak_right .- paired.mid_peak_left
    return paired
end

function pair_summary_row(paired::DataFrame, left_case::AbstractString, right_case::AbstractString)
    return (
        pair = "$right_case - $left_case",
        aligned_hours = nrow(paired),
        mean_delta_price = mean(paired.delta_price),
        mean_delta_thermal_cost = mean(paired.delta_thermal_cost),
        mean_delta_mid_peak = mean(paired.delta_mid_peak),
        mean_delta_flex_demand = mean(paired.delta_flex_demand),
        mean_delta_net_discharge = mean(paired.delta_net_discharge),
        corr_price_vs_flex = safe_cor(paired.delta_price, paired.delta_flex_demand),
        corr_cost_vs_midpeak = safe_cor(paired.delta_thermal_cost, paired.delta_mid_peak),
        corr_price_vs_netdischarge = safe_cor(paired.delta_price, paired.delta_net_discharge),
    )
end

function print_case_story(row)
    println()
    println("Case summary: $(row.case_name)")
    println("-"^72)
    @printf("Executed hours: %d\n", row.executed_hours)
    @printf("Average executed price (EUR/MWh): %.4f\n", row.avg_price)
    @printf("Average thermal cost (EUR/h): %.2f\n", row.avg_thermal_cost)
    @printf("Average Mid+Peak dispatch (MWh/h): %.4f\n", row.avg_mid_peak)
    @printf("Average flex demand served (MWh/h): %.4f\n", row.avg_flex_demand)
    @printf("Average net battery discharge (MWh/h): %.4f\n", row.avg_net_discharge)
    @printf("Storage throughput (MWh over executed hours): %.2f\n", row.throughput)
    @printf("Charge-weighted price (EUR/MWh): %.4f\n", row.avg_charge_price)
    @printf("Discharge-weighted price (EUR/MWh): %.4f\n", row.avg_discharge_price)
    @printf("Share of charging in cheapest 20%% hours: %.4f\n", row.charge_share_low20)
    @printf("Share of discharging in most expensive 20%% hours: %.4f\n", row.discharge_share_high20)
    @printf("Average discharge share in last 6 visible hours: %.4f\n", row.avg_share_discharge_last6)
    @printf("Average end-of-window SOC (MWh): %.2f\n", row.avg_end_soc_window)
    @printf("Final executed SOC (MWh): %.2f\n", row.final_soc_executed)
end

function print_pair_story(row)
    println()
    println("Pair analysis: $(row.pair)")
    println("-"^72)
    @printf("Aligned executed hours: %d\n", row.aligned_hours)
    @printf("Mean delta price (EUR/MWh): %.4f\n", row.mean_delta_price)
    @printf("Mean delta thermal cost (EUR/h): %.2f\n", row.mean_delta_thermal_cost)
    @printf("Mean delta Mid+Peak dispatch (MWh/h): %.4f\n", row.mean_delta_mid_peak)
    @printf("Mean delta flex demand (MWh/h): %.4f\n", row.mean_delta_flex_demand)
    @printf("Mean delta net battery discharge (MWh/h): %.4f\n", row.mean_delta_net_discharge)
    @printf("corr(delta price, delta flex demand): %.4f\n", row.corr_price_vs_flex)
    @printf("corr(delta thermal cost, delta Mid+Peak dispatch): %.4f\n", row.corr_cost_vs_midpeak)
    @printf("corr(delta price, delta net discharge): %.4f\n", row.corr_price_vs_netdischarge)
end

function print_hypothesis_assessment(case_summary_df::DataFrame, pair_summary_df::DataFrame)
    println()
    println("Hypothesis assessment")
    println("="^72)
    println("H1: Higher storage revenue comes mostly from better price selectivity, not from much more throughput.")
    for row in eachrow(case_summary_df)
        @printf("  %-11s throughput = %8.1f, charge px = %6.2f, discharge px = %6.2f\n", row.case_name, row.throughput, row.avg_charge_price, row.avg_discharge_price)
    end
    println("H2: Higher prices suppress flexible demand and reduce demand value.")
    for row in eachrow(pair_summary_df)
        @printf("  %-25s dPrice = %6.3f, dFlex = %7.3f, corr = %6.3f\n", row.pair, row.mean_delta_price, row.mean_delta_flex_demand, row.corr_price_vs_flex)
    end
    println("H3: Lower generation cost comes from lower Mid+Peak thermal dispatch.")
    for row in eachrow(pair_summary_df)
        @printf("  %-25s dCost = %8.2f, dMidPeak = %7.3f, corr = %6.3f\n", row.pair, row.mean_delta_thermal_cost, row.mean_delta_mid_peak, row.corr_cost_vs_midpeak)
    end
    println("H4: Longer foresight exploits more end-of-window discharge and leaves lower final SOC.")
    for row in eachrow(case_summary_df)
        @printf("  %-11s last6 discharge share = %.3f, avg end SOC = %7.1f, final SOC = %7.1f\n", row.case_name, row.avg_share_discharge_last6, row.avg_end_soc_window, row.final_soc_executed)
    end
end

function plot_hourly_profiles(df::DataFrame, output_dir::AbstractString)
    hourly = combine(
        groupby(df, [:case_name, :hour_of_day]),
        :price => mean => :avg_price,
        :thermal_cost => mean => :avg_thermal_cost,
    )

    metrics = [
        (:avg_price, "Average delivery-hour price", "EUR/MWh"),
        (:avg_thermal_cost, "Average Thermal Cost", "EUR"),
    ]

    p = plot(
        layout=(2, 1),
        size=(1200, 760),
        plot_titlefontsize=14,
        titlefontsize=11,
        guidefontsize=10,
        tickfontsize=9,
        legendfontsize=9,
        framestyle=:box,
        gridalpha=0.18,
        left_margin=8Plots.mm,
        right_margin=8Plots.mm,
        top_margin=4Plots.mm,
        bottom_margin=5Plots.mm,
    )
    for (idx, (metric, title_text, ylabel_text)) in enumerate(metrics)
        for case_name in CASE_ORDER
            subset = sort(filter(:case_name => ==(case_name), hourly), :hour_of_day)
            plot!(
                p[idx],
                subset.hour_of_day,
                subset[!, metric],
                linewidth=2.0,
                marker=:circle,
                markersize=3,
                color=get(CASE_COLORS, case_name, :steelblue),
                xlabel="Hour of day",
                ylabel=ylabel_text,
                title=title_text,
                label=case_name,
                legend=(idx == 1 ? :topleft : :topright),
            )
        end
    end
    savefig(p, joinpath(output_dir, "foresight_hourly_hypothesis_profiles.png"))
    return p
end

function plot_price_duration(df::DataFrame, output_dir::AbstractString)
    p = plot(size=(1000, 500), xlabel="Executed hour rank", ylabel="Price (EUR/MWh)", title="Executed Price Duration Curves")
    for case_name in CASE_ORDER
        prices = sort(collect(filter(:case_name => ==(case_name), df).price), rev=true)
        plot!(p, 1:length(prices), prices, linewidth=3, label=case_name)
    end
    savefig(p, joinpath(output_dir, "foresight_price_duration_curves.png"))
    return p
end

function plot_storage_selectivity(case_summary_df::DataFrame, output_dir::AbstractString)
    x = collect(1:nrow(case_summary_df))
    charge_vals = Float64.(case_summary_df.charge_share_low20)
    discharge_vals = Float64.(case_summary_df.discharge_share_high20)
    shared_style = (
        xticks=(x, case_summary_df.case_name),
        guidefontsize=10,
        tickfontsize=9,
        titlefontsize=11,
        legendfontsize=9,
        framestyle=:box,
        gridalpha=0.18,
        left_margin=8Plots.mm,
        right_margin=6Plots.mm,
        top_margin=4Plots.mm,
        bottom_margin=5Plots.mm,
    )
    p = groupedbar(
        x,
        hcat(charge_vals, discharge_vals),
        bar_position=:dodge,
        label=["Charge in bottom 20% prices" "Discharge in top 20% prices"],
        color=[COLOR_PURPLE COLOR_GOLD],
        ylabel="Share",
        ylim=(0, 1),
        title="Where the Battery Buys and Sells",
        size=(900, 430),
        legend=:topright;
        shared_style...,
    )

    label_offset = 0.025
    for i in eachindex(x)
        annotate!(
            p,
            x[i] - 0.19,
            charge_vals[i] + label_offset,
            text(@sprintf("%.2f", charge_vals[i]), 9, :center),
        )
        annotate!(
            p,
            x[i] + 0.19,
            discharge_vals[i] + label_offset,
            text(@sprintf("%.2f", discharge_vals[i]), 9, :center),
        )
    end

    savefig(p, joinpath(output_dir, "foresight_storage_selectivity.png"))
    return p
end

function plot_horizon_end_diagnostics(case_summary_df::DataFrame, output_dir::AbstractString)
    x = collect(1:nrow(case_summary_df))
    p1 = bar(x, case_summary_df.avg_share_discharge_last6, xticks=(x, case_summary_df.case_name), ylabel="Share", ylim=(0, 1), title="Average Discharge Share in Last 6 Visible Hours", legend=false, size=(1000, 380))
    p2 = groupedbar(x, hcat(case_summary_df.avg_end_soc_window, case_summary_df.final_soc_executed), bar_position=:dodge, label=["Average end-of-window SOC" "Final executed SOC"], xticks=(x, case_summary_df.case_name), ylabel="MWh", title="SOC End Effects", size=(1000, 420))
    combined = plot(p1, p2, layout=(2, 1), size=(1000, 800))
    savefig(combined, joinpath(output_dir, "foresight_horizon_end_diagnostics.png"))
    return combined
end

function plot_delta_scatter(paired::DataFrame, pair_name::AbstractString, output_dir::AbstractString)
    p1 = scatter(paired.delta_mid_peak, paired.delta_thermal_cost, xlabel="Delta Mid+Peak dispatch (MWh/h)", ylabel="Delta thermal cost (EUR/h)", title="$pair_name: Thermal Cost vs Mid+Peak", alpha=0.6, markersize=3, label="")
    p2 = scatter(paired.delta_price, paired.delta_flex_demand, xlabel="Delta price (EUR/MWh)", ylabel="Delta flex demand (MWh/h)", title="$pair_name: Price vs Flex Demand", alpha=0.6, markersize=3, label="")
    combined = plot(p1, p2, layout=(1, 2), size=(1300, 500))
    filename = replace(lowercase(pair_name), r"[^a-z0-9]+" => "_")
    savefig(combined, joinpath(output_dir, "delta_scatter_$filename.png"))
    return combined
end

function kpi_label(metric::AbstractString, value::Real)
    if metric == "Curtailment"
        return @sprintf("%.0f", value)
    else
        return @sprintf("%.2fM", value / 1e6)
    end
end

function tofloat(x)
    if x isa Number
        return Float64(x)
    end
    cleaned = replace(strip(String(x)), "," => "")
    return parse(Float64, cleaned)
end

function plot_main_kpi_bars(kpi_df::DataFrame, output_dir::AbstractString)
    sort!(kpi_df, [:case_name], by=x -> findfirst(==(x), CASE_ORDER))

    metrics = [
        ("Social welfare", :social_welfare_eur_per_day),
        ("System cost", :generation_cost_eur_per_day),
        ("Curtailment", :wind_curtailment_mwh_per_day),
        ("Storage revenue", :storage_net_revenue_eur_per_day),
    ]

    bar_colors = [COLOR_BLUE, COLOR_CORAL, COLOR_GREEN]
    labels = String.(kpi_df.case_name)
    n_metrics = length(metrics)
    x = collect(1:n_metrics)
    offsets = [-0.24, 0.0, 0.24]
    width = 0.22

    normalized = zeros(Float64, n_metrics, nrow(kpi_df))
    actual = zeros(Float64, n_metrics, nrow(kpi_df))
    for (i, (_, col)) in enumerate(metrics)
        baseline = tofloat(kpi_df[1, col])
        for j in 1:nrow(kpi_df)
            actual[i, j] = tofloat(kpi_df[j, col])
            normalized[i, j] = baseline == 0 ? 0.0 : 100 * actual[i, j] / baseline
        end
    end

    p = plot(
        xlabel="KPI",
        ylabel="Relative to 36h (%)",
        xticks=(x, first.(metrics)),
        ylim=(0, max(125, maximum(normalized) + 12)),
        xlims=(0.5, n_metrics + 0.5),
        legend=:top,
        title="KPIs across market length",
        size=(1200, 650),
        guidefontsize=16,
        tickfontsize=13,
        titlefontsize=18,
        legendfontsize=9,
        bottom_margin=28Plots.mm,
        left_margin=20Plots.mm,
    )

    for j in 1:nrow(kpi_df)
        xpos = x .+ offsets[j]
        bar!(
            p,
            xpos,
            normalized[:, j],
            bar_width=width,
            color=bar_colors[j],
            alpha=0.95,
            label=labels[j],
        )

        for i in 1:n_metrics
            annotate!(
                p,
                xpos[i],
                normalized[i, j] + 2.5,
                text(kpi_label(metrics[i][1], actual[i, j]), 11, bar_colors[j], :center),
            )
        end
    end

    savefig(p, joinpath(output_dir, "foresight_main_kpi_bars.png"))
    return p
end

function main()
    isdir(RUN_DIR) || error("Run directory not found: $RUN_DIR")
    output_dir = joinpath(RUN_DIR, "_hypothesis_analysis")
    isdir(output_dir) || mkpath(output_dir)
    kpi_df = load_kpi_summary(RUN_DIR)

    case_dfs = DataFrame[]
    clearing_dfs = DataFrame[]
    case_summary_rows = NamedTuple[]

    for case_name in CASE_ORDER
        all_results, cfg = load_case(RUN_DIR, CASE_FOLDERS[case_name])
        df_case = executed_hourly_df(case_name, all_results, cfg)
        clearing_df_case = clearing_summary_df(case_name, all_results)
        push!(case_dfs, df_case)
        push!(clearing_dfs, clearing_df_case)
        row = case_summary_row(df_case, clearing_df_case)
        push!(case_summary_rows, row)
        print_case_story(row)
    end

    df = vcat(case_dfs...)
    clearing_df = vcat(clearing_dfs...)
    case_summary_df = DataFrame(case_summary_rows)

    paired_48_36 = paired_delta_df(df, "Rolling 36h", "Rolling 48h")
    paired_72_48 = paired_delta_df(df, "Rolling 48h", "Rolling 72h")
    pair_summary_df = DataFrame([
        pair_summary_row(paired_48_36, "Rolling 36h", "Rolling 48h"),
        pair_summary_row(paired_72_48, "Rolling 48h", "Rolling 72h"),
    ])

    for row in eachrow(pair_summary_df)
        print_pair_story(row)
    end
    print_hypothesis_assessment(case_summary_df, pair_summary_df)

    CSV.write(joinpath(output_dir, "executed_hourly_metrics_20260509.csv"), df)
    CSV.write(joinpath(output_dir, "executed_hourly_metrics.csv"), df)
    CSV.write(joinpath(output_dir, "clearing_hypothesis_metrics_20260509.csv"), clearing_df)
    CSV.write(joinpath(output_dir, "clearing_hypothesis_metrics.csv"), clearing_df)
    CSV.write(joinpath(output_dir, "case_hypothesis_summary_20260509.csv"), case_summary_df)
    CSV.write(joinpath(output_dir, "pair_hypothesis_summary_20260509.csv"), pair_summary_df)
    CSV.write(joinpath(output_dir, "paired_deltas_48_minus_36_20260509.csv"), paired_48_36)
    CSV.write(joinpath(output_dir, "paired_deltas_72_minus_48_20260509.csv"), paired_72_48)

    plot_hourly_profiles(df, output_dir)
    plot_price_duration(df, output_dir)
    plot_storage_selectivity(case_summary_df, output_dir)
    plot_horizon_end_diagnostics(case_summary_df, output_dir)
    plot_delta_scatter(paired_48_36, "Rolling 48h - Rolling 36h", output_dir)
    plot_delta_scatter(paired_72_48, "Rolling 72h - Rolling 48h", output_dir)
    plot_main_kpi_bars(kpi_df, output_dir)

    println()
    println("Saved hypothesis-analysis outputs to: $output_dir")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

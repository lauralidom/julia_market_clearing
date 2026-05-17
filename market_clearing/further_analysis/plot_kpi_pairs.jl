using Serialization
using JuMP
using StatsPlots
using Printf

include("src/costs.jl")

const RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260320_205737_withstoragestory")
const CASE_FOLDERS = Dict(
    "Fixed 36h" => "fixed_36h",
    "Rolling 36h" => "rolling_36h",
)

function load_case(run_dir::AbstractString, case_folder::AbstractString)
    case_dir = joinpath(run_dir, case_folder)
    all_results = deserialize(joinpath(case_dir, "all_results.jls"))
    cfg = deserialize(joinpath(case_dir, "cfg.jls"))
    return all_results, cfg
end

function executed_days(all_results::Dict)
    clearing_details = get(all_results, :clearing_details, Dict())
    total_executed_hours = sum(details[:executed_hours] for details in values(clearing_details))
    return total_executed_hours / 24
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

function collect_plot_kpis(all_results::Dict, cfg::Dict)
    welfare = calculate_social_welfare(all_results, cfg)
    storage = calculate_storage_revenue(all_results, cfg)
    days = normalization_days(cfg, all_results)
    total_curtailment = haskey(all_results, :curtailment_energy) ? sum(all_results[:curtailment_energy]) : 0.0

    return Dict(
        "Social welfare" => welfare[:social_welfare] / days,
        "System cost" => welfare[:total_generation_cost] / days,
        "Curtailment" => total_curtailment / days,
        "Delivered-hour price" => average_executed_price(all_results),
        "Storage revenue" => storage[:net_revenue] / days,
    )
end

function label_text(metric::AbstractString, value::Float64)
    if metric == "Delivered-hour price"
        return @sprintf("%.1f", value)
    elseif metric == "Curtailment"
        return @sprintf("%.0f", value)
    else
        return @sprintf("%.2fM", value / 1e6)
    end
end

function build_kpi_pair_chart(fixed_kpis::Dict{String, Float64}, rolling_kpis::Dict{String, Float64})
    metrics = ["Social welfare", "System cost", "Curtailment", "Delivered-hour price", "Storage revenue"]
    fixed_vals = [fixed_kpis[m] for m in metrics]
    rolling_vals = [rolling_kpis[m] for m in metrics]

    # Scale each pair relative to its larger value so all KPI clusters fit on one axis.
    normalized_fixed = Float64[]
    normalized_rolling = Float64[]
    for i in eachindex(metrics)
        scale = max(fixed_vals[i], rolling_vals[i])
        if scale <= 0
            push!(normalized_fixed, 0.0)
            push!(normalized_rolling, 0.0)
        else
            push!(normalized_fixed, 100 * fixed_vals[i] / scale)
            push!(normalized_rolling, 100 * rolling_vals[i] / scale)
        end
    end

    x = collect(1:length(metrics))
    offset = 0.16
    bar_width = 0.28

    p = bar(
        x .- offset,
        normalized_fixed,
        bar_width=bar_width,
        color=:steelblue,
        alpha=0.9,
        ylabel="Relative within KPI pair (%)",
        xlabel="KPI\nBars are normalized within each KPI pair; labels show actual values (EUR/day, MWh/day, or EUR/MWh).",
        label="Fixed 36h",
        legend=false,
        ylim=(0, 120),
        xlims=(0.4, length(metrics) + 0.6),
        xticks=(x, metrics),
        size=(1460, 860),
        title="Baseline Case KPI Comparison",
        xrotation=0,
        bottom_margin=42Plots.mm,
        left_margin=16Plots.mm,
        right_margin=10Plots.mm,
        top_margin=18Plots.mm,
        guidefontsize=19,
        tickfontsize=15,
        titlefontsize=24,
        legendfontsize=15,
    )

    bar!(
        p,
        x .+ offset,
        normalized_rolling,
        bar_width=bar_width,
        color=:darkorange,
        alpha=0.9,
        label="Rolling 36h",
    )

    plot!(p, legend=:top, legend_position=(0.5, 1.40))

    for i in eachindex(metrics)
        annotate!(p, x[i] - offset, normalized_fixed[i] + 2.5, text(label_text(metrics[i], fixed_vals[i]), 15, :steelblue, :center))
        annotate!(p, x[i] + offset, normalized_rolling[i] + 2.5, text(label_text(metrics[i], rolling_vals[i]), 15, :darkorange, :center))
    end

    return p
end

function main()
    isdir(RUN_DIR) || error("Run directory not found: $RUN_DIR")

    fixed_results, fixed_cfg = load_case(RUN_DIR, CASE_FOLDERS["Fixed 36h"])
    rolling_results, rolling_cfg = load_case(RUN_DIR, CASE_FOLDERS["Rolling 36h"])

    fixed_kpis = collect_plot_kpis(fixed_results, fixed_cfg)
    rolling_kpis = collect_plot_kpis(rolling_results, rolling_cfg)

    p = build_kpi_pair_chart(fixed_kpis, rolling_kpis)

    output_dir = joinpath(RUN_DIR, "_clean_saved_plots")
    isdir(output_dir) || mkpath(output_dir)
    output_path = joinpath(output_dir, "baseline_kpi_pairs.png")
    savefig(p, output_path)

    println("Saved KPI comparison figure to: $output_path")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

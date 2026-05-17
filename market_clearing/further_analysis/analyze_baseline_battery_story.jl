using Serialization
using Statistics
using Printf
using Dates
using Plots

struct CaseAnalysis
    case_name::String
    case_dir::String
    all_results::Dict
    cfg::Dict
    executed_prices::Vector{Float64}
    executed_charge::Vector{Float64}
    executed_discharge::Vector{Float64}
    executed_net_discharge::Vector{Float64}
    total_demand_served::Vector{Float64}
    demand_base_served::Vector{Float64}
    demand_flex_served::Vector{Float64}
    wind_curtailment::Vector{Float64}
end

function load_case(case_dir::AbstractString)
    all_results_path = joinpath(case_dir, "all_results.jls")
    cfg_path = joinpath(case_dir, "cfg.jls")
    isfile(all_results_path) || error("Missing results file: $all_results_path")
    isfile(cfg_path) || error("Missing config file: $cfg_path")

    all_results = deserialize(all_results_path)
    cfg = deserialize(cfg_path)
    clearing_details = all_results[:clearing_details]

    executed_prices = Float64[]
    executed_charge = Float64[]
    executed_discharge = Float64[]
    executed_net_discharge = Float64[]
    total_demand_served = Float64[]
    demand_base_served = Float64[]
    demand_flex_served = Float64[]
    wind_curtailment = Float64[]

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        for h in 1:executed_hours
            push!(executed_prices, details[:prices][h])
            push!(executed_charge, details[:charging][h])
            push!(executed_discharge, details[:discharging][h])
            push!(executed_net_discharge, details[:discharging][h] - details[:charging][h])
            push!(demand_base_served, details[:demand_base][h])
            push!(demand_flex_served, details[:demand_flex][h])
            push!(total_demand_served, details[:demand_base][h] + details[:demand_flex][h])
            push!(wind_curtailment, h == 1 ? details[:wind_curtailment_h1] : 0.0)
        end
    end

    return CaseAnalysis(
        basename(case_dir),
        String(case_dir),
        all_results,
        cfg,
        executed_prices,
        executed_charge,
        executed_discharge,
        executed_net_discharge,
        total_demand_served,
        demand_base_served,
        demand_flex_served,
        wind_curtailment,
    )
end

function daily_chunks(values::Vector{Float64})
    days = div(length(values), 24)
    days > 0 || error("Need at least 24 executed hours to build daily diagnostics.")
    return [values[(24 * (d - 1) + 1):(24 * d)] for d in 1:days]
end

mean_abs_hourly_change(prices::Vector{Float64}) =
    length(prices) <= 1 ? 0.0 : mean(abs.(diff(prices)))

function summarize_case(case::CaseAnalysis)
    prices_by_day = daily_chunks(case.executed_prices)
    charge_by_day = daily_chunks(case.executed_charge)
    discharge_by_day = daily_chunks(case.executed_discharge)
    total_demand_by_day = daily_chunks(case.total_demand_served)
    flex_demand_by_day = daily_chunks(case.demand_flex_served)
    curtailment_by_day = daily_chunks(case.wind_curtailment)

    daily_price_range = [maximum(day) - minimum(day) for day in prices_by_day]
    daily_price_volatility = [mean_abs_hourly_change(day) for day in prices_by_day]
    daily_charge = [sum(day) for day in charge_by_day]
    daily_discharge = [sum(day) for day in discharge_by_day]
    daily_throughput = daily_charge .+ daily_discharge
    daily_revenue = [
        sum(dis .* pr for (dis, pr) in zip(discharge_by_day[d], prices_by_day[d])) -
        sum(ch .* pr for (ch, pr) in zip(charge_by_day[d], prices_by_day[d]))
        for d in eachindex(prices_by_day)
    ]
    daily_total_demand = [sum(day) for day in total_demand_by_day]
    daily_flex_demand = [sum(day) for day in flex_demand_by_day]
    daily_curtailment = [sum(day) for day in curtailment_by_day]

    storage_energy_capacity = float(case.cfg["batteryStorage"]["energyCapacity"])
    equivalent_full_cycles = daily_throughput ./ (2 * storage_energy_capacity)
    revenue_per_throughput = [
        throughput > 0 ? revenue / throughput : 0.0
        for (revenue, throughput) in zip(daily_revenue, daily_throughput)
    ]

    return Dict(
        :daily_price_range => daily_price_range,
        :daily_price_volatility => daily_price_volatility,
        :daily_charge => daily_charge,
        :daily_discharge => daily_discharge,
        :daily_throughput => daily_throughput,
        :daily_revenue => daily_revenue,
        :daily_total_demand => daily_total_demand,
        :daily_flex_demand => daily_flex_demand,
        :daily_curtailment => daily_curtailment,
        :equivalent_full_cycles => equivalent_full_cycles,
        :revenue_per_throughput => revenue_per_throughput,
        :avg_price_range => mean(daily_price_range),
        :avg_price_volatility => mean(daily_price_volatility),
        :avg_daily_throughput => mean(daily_throughput),
        :avg_daily_revenue => mean(daily_revenue),
        :avg_daily_total_demand => mean(daily_total_demand),
        :avg_daily_flex_demand => mean(daily_flex_demand),
        :avg_daily_curtailment => mean(daily_curtailment),
        :avg_equivalent_full_cycles => mean(equivalent_full_cycles),
        :avg_revenue_per_throughput => mean(revenue_per_throughput),
        :throughput_spread_corr => cor(daily_throughput, daily_price_range),
        :throughput_volatility_corr => cor(daily_throughput, daily_price_volatility),
    )
end

function latest_baseline_run(root::AbstractString)
    entries = filter(name -> startswith(name, "baseline_"), readdir(root))
    isempty(entries) && error("No baseline run folders found under $root")
    sort!(entries)
    return joinpath(root, entries[end])
end

function resolve_run_dir(args)
    if !isempty(args)
        return args[1]
    end
    return latest_baseline_run(joinpath("Results", "thesis_runs"))
end

function find_case_dir(run_dir::AbstractString, slug::AbstractString)
    case_dir = joinpath(run_dir, slug)
    isdir(case_dir) || error("Missing case directory: $case_dir")
    return case_dir
end

function plot_metric_pair(days, left_values, right_values, left_label, right_label;
                          title::AbstractString, ylabel::AbstractString)
    p1 = plot(days, left_values, linewidth=2.5, marker=:circle, color=:steelblue,
              xlabel="Day", ylabel=ylabel, title=left_label, legend=false)
    p2 = plot(days, right_values, linewidth=2.5, marker=:circle, color=:darkorange,
              xlabel="Day", ylabel=ylabel, title=right_label, legend=false)
    return plot(p1, p2, layout=(1, 2), size=(1200, 420), plot_title=title)
end

function plot_scatter_pair(x1, y1, x2, y2, label1, label2;
                           xlabel::AbstractString, ylabel::AbstractString, title::AbstractString)
    p = scatter(x1, y1, color=:steelblue, markerstrokewidth=0, alpha=0.75, label=label1,
                xlabel=xlabel, ylabel=ylabel, title=title, size=(850, 500))
    scatter!(p, x2, y2, color=:darkorange, markerstrokewidth=0, alpha=0.75, label=label2)
    return p
end

function save_story_plots(run_dir::AbstractString, fixed_case::CaseAnalysis, rolling_case::CaseAnalysis,
                          fixed_summary::Dict, rolling_summary::Dict)
    output_dir = joinpath(run_dir, "_story_diagnostics")
    isdir(output_dir) || mkpath(output_dir)
    days = 1:length(fixed_summary[:daily_price_range])

    p1 = plot_metric_pair(
        days,
        fixed_summary[:daily_price_range],
        rolling_summary[:daily_price_range],
        "Fixed 36h",
        "Rolling 36h";
        title="Daily Executed Price Range",
        ylabel="EUR/MWh",
    )
    savefig(p1, joinpath(output_dir, "story_01_daily_price_range.png"))

    p2 = plot_metric_pair(
        days,
        fixed_summary[:daily_throughput],
        rolling_summary[:daily_throughput],
        "Fixed 36h",
        "Rolling 36h";
        title="Daily Battery Throughput",
        ylabel="MWh/day",
    )
    savefig(p2, joinpath(output_dir, "story_02_daily_battery_throughput.png"))

    p3 = plot_scatter_pair(
        fixed_summary[:daily_price_range],
        fixed_summary[:daily_throughput],
        rolling_summary[:daily_price_range],
        rolling_summary[:daily_throughput],
        "Fixed 36h",
        "Rolling 36h";
        xlabel="Daily Price Range (EUR/MWh)",
        ylabel="Daily Battery Throughput (MWh)",
        title="Battery Throughput vs Short-Term Price Spreads",
    )
    savefig(p3, joinpath(output_dir, "story_03_throughput_vs_price_range.png"))

    system_metrics = [:avg_daily_total_demand, :avg_daily_flex_demand, :avg_daily_curtailment, :avg_daily_revenue]
    metric_titles = [
        "Avg Daily Demand Served",
        "Avg Daily Flex Demand Served",
        "Avg Daily Wind Curtailment",
        "Avg Daily Storage Revenue",
    ]
    metric_values_fixed = [fixed_summary[m] for m in system_metrics]
    metric_values_rolling = [rolling_summary[m] for m in system_metrics]

    p4 = plot(layout=(2, 2), size=(1100, 700), plot_title="Outcome Comparison: Private Storage Gains vs System Outcomes")
    for idx in eachindex(system_metrics)
        bar!(
            p4[idx],
            ["Fixed 36h", "Rolling 36h"],
            [metric_values_fixed[idx], metric_values_rolling[idx]],
            title=metric_titles[idx],
            legend=false,
            color=[:steelblue :darkorange],
            alpha=0.85,
            xrotation=10,
        )
    end
    savefig(p4, joinpath(output_dir, "story_04_private_vs_system_outcomes.png"))

    p5 = plot_metric_pair(
        days,
        fixed_summary[:daily_revenue],
        rolling_summary[:daily_revenue],
        "Fixed 36h",
        "Rolling 36h";
        title="Daily Storage Net Revenue",
        ylabel="EUR/day",
    )
    savefig(p5, joinpath(output_dir, "story_05_daily_storage_revenue.png"))

    return output_dir
end

function print_story_summary(fixed_summary::Dict, rolling_summary::Dict)
    println()
    println("="^90)
    println("BASELINE STORY DIAGNOSTICS")
    println("="^90)
    println()
    println("Hypothesis 1: A more myopic market design can create stronger short-term spreads and more battery cycling.")
    @printf("  Fixed 36h avg daily price range:        %8.2f EUR/MWh\n", fixed_summary[:avg_price_range])
    @printf("  Rolling 36h avg daily price range:      %8.2f EUR/MWh\n", rolling_summary[:avg_price_range])
    @printf("  Fixed 36h avg hourly price change:      %8.2f EUR/MWh\n", fixed_summary[:avg_price_volatility])
    @printf("  Rolling 36h avg hourly price change:    %8.2f EUR/MWh\n", rolling_summary[:avg_price_volatility])
    @printf("  Fixed 36h avg daily throughput:         %8.2f MWh/day\n", fixed_summary[:avg_daily_throughput])
    @printf("  Rolling 36h avg daily throughput:       %8.2f MWh/day\n", rolling_summary[:avg_daily_throughput])
    @printf("  Fixed 36h avg equivalent full cycles:   %8.3f cycles/day\n", fixed_summary[:avg_equivalent_full_cycles])
    @printf("  Rolling 36h avg equivalent full cycles: %8.3f cycles/day\n", rolling_summary[:avg_equivalent_full_cycles])
    @printf("  Fixed throughput-price-range corr:      %8.3f\n", fixed_summary[:throughput_spread_corr])
    @printf("  Rolling throughput-price-range corr:    %8.3f\n", rolling_summary[:throughput_spread_corr])

    println()
    println("Hypothesis 2: More throughput can mean the battery is exploiting local spreads, not that the overall dispatch is better.")
    @printf("  Fixed 36h avg daily storage revenue:    %8.2f EUR/day\n", fixed_summary[:avg_daily_revenue])
    @printf("  Rolling 36h avg daily storage revenue:  %8.2f EUR/day\n", rolling_summary[:avg_daily_revenue])
    @printf("  Fixed revenue per throughput:           %8.2f EUR/MWh\n", fixed_summary[:avg_revenue_per_throughput])
    @printf("  Rolling revenue per throughput:         %8.2f EUR/MWh\n", rolling_summary[:avg_revenue_per_throughput])
    @printf("  Fixed avg daily demand served:          %8.2f MWh/day\n", fixed_summary[:avg_daily_total_demand])
    @printf("  Rolling avg daily demand served:        %8.2f MWh/day\n", rolling_summary[:avg_daily_total_demand])
    @printf("  Fixed avg daily flex demand served:     %8.2f MWh/day\n", fixed_summary[:avg_daily_flex_demand])
    @printf("  Rolling avg daily flex demand served:   %8.2f MWh/day\n", rolling_summary[:avg_daily_flex_demand])
    @printf("  Fixed avg daily wind curtailment:       %8.2f MWh/day\n", fixed_summary[:avg_daily_curtailment])
    @printf("  Rolling avg daily wind curtailment:     %8.2f MWh/day\n", rolling_summary[:avg_daily_curtailment])
    println()
    println("Interpretation guide:")
    println("  If Fixed shows higher price range/volatility and higher throughput, that supports the short-term spread story.")
    println("  If Fixed also shows higher storage revenue but higher curtailment or only a small demand gain, that supports the")
    println("  idea that extra battery use is exploiting local spreads rather than improving total system coordination.")
end

function main(args)
    run_dir = resolve_run_dir(args)
    fixed_case = load_case(find_case_dir(run_dir, "fixed_36h"))
    rolling_case = load_case(find_case_dir(run_dir, "rolling_36h"))

    fixed_summary = summarize_case(fixed_case)
    rolling_summary = summarize_case(rolling_case)
    output_dir = save_story_plots(run_dir, fixed_case, rolling_case, fixed_summary, rolling_summary)

    println("Loaded baseline run: $run_dir")
    println("Story plots saved to: $output_dir")
    print_story_summary(fixed_summary, rolling_summary)
end

main(ARGS)

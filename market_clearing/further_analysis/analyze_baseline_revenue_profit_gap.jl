using JuMP
using HiGHS
using YAML
using Serialization
using CSV
using DataFrames
using Statistics
using Printf
using Plots
using StatsPlots

include(joinpath(@__DIR__, "..", "src", "costs.jl"))

const DEFAULT_RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260320_205737_withstoragestory")
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

function generator_bid_prices(cfg::Dict)
    prices = Dict{String, Float64}()
    for (gname, gdata) in cfg["dispatchableGenerators"]
        prices[String(gname)] = float(gdata["bidPrice"])
    end
    for (gname, gdata) in cfg["variableGenerators"]
        prices[String(gname)] = float(gdata["bidPrice"])
    end
    return prices
end

function demand_bid_prices(cfg::Dict)
    prices = Dict{String, Float64}()
    for (dname, ddata) in cfg["demand"]["segments"]
        prices[String(dname)] = float(ddata["bidPrice"])
    end
    return prices
end

function executed_hour_rows(case_name::AbstractString, all_results::Dict, cfg::Dict)
    bid_prices = generator_bid_prices(cfg)
    demand_prices = demand_bid_prices(cfg)
    clearing_details = all_results[:clearing_details]
    rows = NamedTuple[]

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        current_hour = details[:current_hour]
        g_planned = details[:g_planned]

        for h in 1:executed_hours
            global_hour = current_hour + h - 1
            base = g_planned["Base", h]
            mid = g_planned["Mid", h]
            peak = g_planned["Peak", h]
            solar = g_planned["Solar", h]
            wind = g_planned["Wind", h]

            total_demand = details[:demand_base][h] + details[:demand_flex][h]
            thermal_cost =
                base * bid_prices["Base"] +
                mid * bid_prices["Mid"] +
                peak * bid_prices["Peak"]
            demand_value =
                details[:demand_base][h] * demand_prices["Base"] +
                details[:demand_flex][h] * demand_prices["Flex"]

            push!(rows, (
                case_name = String(case_name),
                global_hour = global_hour,
                price = details[:prices][h],
                base = base,
                mid = mid,
                peak = peak,
                solar = solar,
                wind = wind,
                thermal_cost = thermal_cost,
                demand_value = demand_value,
                welfare = demand_value - thermal_cost,
                total_demand = total_demand,
                flex_demand = details[:demand_flex][h],
                charging = details[:charging][h],
                discharging = details[:discharging][h],
                net_discharge = details[:discharging][h] - details[:charging][h],
                wind_curtailment = h == 1 ? get(details, :wind_curtailment_h1, 0.0) : 0.0,
            ))
        end
    end

    return DataFrame(rows)
end

function financial_hour_rows(case_name::AbstractString, all_results::Dict, cfg::Dict)
    ledger, executed, exec_price = compute_delivery_hour_ledger(all_results, cfg)
    bid_prices = generator_bid_prices(cfg)
    rows = NamedTuple[]

    for ((gen, global_hour), rec) in sort(collect(ledger); by=x -> (x[1][2], x[1][1]))
        exec_qty = get(executed, (gen, global_hour), 0.0)
        price = get(exec_price, global_hour, NaN)
        executed_revenue = exec_qty * price
        full_cashflow = rec[:cashflow]
        push!(rows, (
            case_name = String(case_name),
            generator = gen,
            global_hour = global_hour,
            exec_price = price,
            executed_qty = exec_qty,
            gross_trade = rec[:gross_qty],
            full_cashflow = full_cashflow,
            executed_revenue = executed_revenue,
            retrade_adjustment = full_cashflow - executed_revenue,
            production_cost = exec_qty * bid_prices[gen],
        ))
    end

    return DataFrame(rows)
end

function generator_summary(case_name::AbstractString, all_results::Dict, cfg::Dict)
    exec_rev = calculate_generator_revenues_executed(all_results, cfg)
    full_rev = calculate_generator_revenues_full(all_results)
    costs = calculate_system_costs(all_results, cfg)

    generators = sort(collect(keys(full_rev[:generator_revenues])))
    rows = NamedTuple[]

    for gen in generators
        executed_revenue = exec_rev[:generator_revenues][gen]
        full_revenue = full_rev[:generator_revenues][gen]
        production_cost = get(costs[:generator_costs], gen, 0.0)
        push!(rows, (
            case_name = String(case_name),
            generator = gen,
            executed_energy = exec_rev[:generator_energy][gen],
            executed_revenue = executed_revenue,
            full_revenue = full_revenue,
            retrade_adjustment = full_revenue - executed_revenue,
            production_cost = production_cost,
            profit = full_revenue - production_cost,
            gross_traded = full_rev[:traded_gross][gen],
            net_traded = full_rev[:traded_net][gen],
            sold_qty = full_rev[:sold_qty][gen],
            buyback_qty = full_rev[:buyback_qty][gen],
            avg_sell_price = full_rev[:avg_sell_price][gen],
            avg_buyback_price = full_rev[:avg_buyback_price][gen],
        ))
    end

    return DataFrame(rows)
end

function system_summary(case_name::AbstractString, all_results::Dict, cfg::Dict)
    welfare = calculate_social_welfare(all_results, cfg)
    storage = calculate_storage_revenue(all_results, cfg)
    costs = calculate_system_costs(all_results, cfg)
    exec_rev = calculate_generator_revenues_executed(all_results, cfg)
    full_rev = calculate_generator_revenues_full(all_results)
    total_executed_energy = sum(values(exec_rev[:generator_energy]))
    total_curtailment = haskey(all_results, :curtailment_energy) ? sum(all_results[:curtailment_energy]) : 0.0

    return (
        case_name = String(case_name),
        executed_energy = total_executed_energy,
        executed_revenue = exec_rev[:total_revenue],
        full_revenue = full_rev[:total_revenue],
        retrade_adjustment = full_rev[:total_revenue] - exec_rev[:total_revenue],
        system_cost = costs[:total_cost],
        demand_value = welfare[:total_demand_value],
        welfare = welfare[:social_welfare],
        storage_net_revenue = storage[:net_revenue],
        curtailment = total_curtailment,
    )
end

function suffix_case_columns!(df::DataFrame, suffix::AbstractString)
    rename_pairs = Pair{Symbol, Symbol}[]
    for name in names(df)
        sym = Symbol(name)
        if sym != :global_hour
            push!(rename_pairs, sym => Symbol(sym, "_", suffix))
        end
    end
    rename!(df, rename_pairs)
    return df
end

function paired_hourly_df(physical_df::DataFrame, financial_df::DataFrame)
    financial_hourly = combine(
        groupby(financial_df, [:case_name, :global_hour]),
        :gross_trade => sum => :gross_trade,
        :full_cashflow => sum => :full_cashflow,
        :executed_revenue => sum => :executed_revenue,
        :retrade_adjustment => sum => :retrade_adjustment,
    )

    fixed_physical = filter(:case_name => ==("Fixed 36h"), physical_df)
    select!(fixed_physical, Not(:case_name))
    suffix_case_columns!(fixed_physical, "Fixed 36h")

    rolling_physical = filter(:case_name => ==("Rolling 36h"), physical_df)
    select!(rolling_physical, Not(:case_name))
    suffix_case_columns!(rolling_physical, "Rolling 36h")

    fixed_financial = filter(:case_name => ==("Fixed 36h"), financial_hourly)
    select!(fixed_financial, Not(:case_name))
    suffix_case_columns!(fixed_financial, "Fixed 36h")

    rolling_financial = filter(:case_name => ==("Rolling 36h"), financial_hourly)
    select!(rolling_financial, Not(:case_name))
    suffix_case_columns!(rolling_financial, "Rolling 36h")

    paired = innerjoin(fixed_physical, rolling_physical, on=:global_hour)
    paired = innerjoin(paired, fixed_financial, on=:global_hour)
    paired = innerjoin(paired, rolling_financial, on=:global_hour)

    for metric in [
        :price, :thermal_cost, :demand_value, :welfare, :total_demand, :flex_demand,
        :net_discharge, :wind_curtailment, :base, :mid, :peak, :solar, :wind,
        :gross_trade, :full_cashflow, :executed_revenue, :retrade_adjustment,
    ]
        fixed_col = Symbol(metric, "_Fixed 36h")
        rolling_col = Symbol(metric, "_Rolling 36h")
        delta_col = Symbol("delta_", metric)
        paired[!, delta_col] = paired[!, fixed_col] .- paired[!, rolling_col]
    end

    return sort(paired, :global_hour)
end

function print_case_story(system_df::DataFrame)
    fixed = only(filter(:case_name => ==("Fixed 36h"), system_df))
    rolling = only(filter(:case_name => ==("Rolling 36h"), system_df))

    println()
    println("="^90)
    println("BASELINE FIXED VS ROLLING REVENUE/PROFIT STORY")
    println("="^90)
    println()
    @printf("Executed energy difference (Fixed - Rolling): %12.2f MWh\n", fixed.executed_energy - rolling.executed_energy)
    @printf("Executed producer revenue difference:         %12.2f EUR\n", fixed.executed_revenue - rolling.executed_revenue)
    @printf("Full financial revenue difference:            %12.2f EUR\n", fixed.full_revenue - rolling.full_revenue)
    @printf("Re-trading adjustment difference:             %12.2f EUR\n", fixed.retrade_adjustment - rolling.retrade_adjustment)
    @printf("System cost difference:                       %12.2f EUR\n", fixed.system_cost - rolling.system_cost)
    @printf("Demand value difference:                      %12.2f EUR\n", fixed.demand_value - rolling.demand_value)
    @printf("Social welfare difference:                    %12.2f EUR\n", fixed.welfare - rolling.welfare)
    @printf("Curtailment difference:                       %12.2f MWh\n", fixed.curtailment - rolling.curtailment)
    @printf("Storage net revenue difference:               %12.2f EUR\n", fixed.storage_net_revenue - rolling.storage_net_revenue)
    println()
    println("Interpretation:")
    println("  If executed energy and executed revenue are similar, but full financial revenue diverges sharply,")
    println("  then the profit gap is being driven by repeated re-trading / buy-back losses rather than by much")
    println("  larger physical delivery. That is exactly the mechanism this script tests generator by generator")
    println("  and delivery hour by delivery hour.")
end

function build_generator_adjustment_plot(generator_df::DataFrame, output_dir::AbstractString)
    gens = unique(generator_df.generator)
    fixed = filter(:case_name => ==("Fixed 36h"), generator_df)
    rolling = filter(:case_name => ==("Rolling 36h"), generator_df)

    fixed_adj = [only(filter(:generator => ==(g), fixed)).retrade_adjustment / 1e6 for g in gens]
    rolling_adj = [only(filter(:generator => ==(g), rolling)).retrade_adjustment / 1e6 for g in gens]
    fixed_profit = [only(filter(:generator => ==(g), fixed)).profit / 1e6 for g in gens]
    rolling_profit = [only(filter(:generator => ==(g), rolling)).profit / 1e6 for g in gens]

    p1 = groupedbar(
        gens,
        [fixed_adj rolling_adj],
        color=[:steelblue :darkorange],
        label=["Fixed 36h" "Rolling 36h"],
        title="Re-trading Adjustment by Generator",
        ylabel="EUR million",
        xrotation=20,
        size=(1050, 450),
    )

    p2 = groupedbar(
        gens,
        [fixed_profit rolling_profit],
        color=[:steelblue :darkorange],
        label=["Fixed 36h" "Rolling 36h"],
        title="Profit by Generator",
        ylabel="EUR million",
        xrotation=20,
        size=(1050, 450),
    )

    combined = plot(p1, p2, layout=(2, 1), size=(1100, 850))
    savefig(combined, joinpath(output_dir, "generator_adjustment_profit_comparison.png"))
end

function build_buyback_plot(generator_df::DataFrame, output_dir::AbstractString)
    gens = unique(generator_df.generator)
    fixed = filter(:case_name => ==("Fixed 36h"), generator_df)
    rolling = filter(:case_name => ==("Rolling 36h"), generator_df)

    fixed_buy = [only(filter(:generator => ==(g), fixed)).buyback_qty for g in gens]
    rolling_buy = [only(filter(:generator => ==(g), rolling)).buyback_qty for g in gens]
    fixed_sell_gap = [only(filter(:generator => ==(g), fixed)).avg_sell_price - only(filter(:generator => ==(g), fixed)).avg_buyback_price for g in gens]
    rolling_sell_gap = [only(filter(:generator => ==(g), rolling)).avg_sell_price - only(filter(:generator => ==(g), rolling)).avg_buyback_price for g in gens]

    p1 = groupedbar(
        gens,
        [fixed_buy rolling_buy],
        color=[:steelblue :darkorange],
        label=["Fixed 36h" "Rolling 36h"],
        title="Buy-back Quantity by Generator",
        ylabel="MWh",
        xrotation=20,
        size=(1050, 450),
    )

    p2 = groupedbar(
        gens,
        [fixed_sell_gap rolling_sell_gap],
        color=[:steelblue :darkorange],
        label=["Fixed 36h" "Rolling 36h"],
        title="Average Sell Price - Average Buy-back Price",
        ylabel="EUR/MWh",
        xrotation=20,
        size=(1050, 450),
    )

    combined = plot(p1, p2, layout=(2, 1), size=(1100, 850))
    savefig(combined, joinpath(output_dir, "generator_buyback_comparison.png"))
end

function build_hourly_story_plot(hourly_df::DataFrame, output_dir::AbstractString)
    p1 = plot(
        hourly_df.global_hour,
        hourly_df.delta_retrade_adjustment ./ 1e3,
        linewidth=2.5,
        color=:firebrick,
        xlabel="Global delivery hour",
        ylabel="Fixed - Rolling (kEUR)",
        title="Hourly Re-trading Adjustment Difference",
        label="Re-trading adjustment",
    )
    hline!(p1, [0.0], color=:black, linestyle=:dash, label="")

    p2 = plot(
        hourly_df.global_hour,
        hourly_df.delta_thermal_cost ./ 1e3,
        linewidth=2.5,
        color=:steelblue,
        xlabel="Global delivery hour",
        ylabel="Fixed - Rolling (kEUR/h)",
        title="Hourly System Cost Difference",
        label="Thermal cost",
    )
    hline!(p2, [0.0], color=:black, linestyle=:dash, label="")

    p3 = plot(
        hourly_df.global_hour,
        hourly_df.delta_welfare ./ 1e3,
        linewidth=2.5,
        color=:darkgreen,
        xlabel="Global delivery hour",
        ylabel="Fixed - Rolling (kEUR/h)",
        title="Hourly Welfare Difference",
        label="Welfare",
    )
    hline!(p3, [0.0], color=:black, linestyle=:dash, label="")

    x = hourly_df.delta_gross_trade
    y = hourly_df.delta_retrade_adjustment ./ 1e3
    corr_xy = (length(x) > 1 && std(x) > 0 && std(y) > 0) ? cor(x, y) : NaN
    fit = hcat(ones(length(x)), x) \ y
    xline = range(minimum(x), maximum(x), length=200)
    yline = fit[1] .+ fit[2] .* xline

    p4 = scatter(
        hourly_df.delta_gross_trade,
        y,
        color=:purple,
        alpha=0.65,
        markersize=4,
        xlabel="Fixed - Rolling gross traded volume (MWh)",
        ylabel="Fixed - Rolling re-trading adjustment (kEUR)",
        title="More Re-trading, Better or Worse Trading Cashflow?",
        label="",
    )
    plot!(p4, xline, yline, color=:black, linewidth=2, linestyle=:dash, label="")
    annotate!(
        p4,
        minimum(x) + 0.06 * (maximum(x) - minimum(x)),
        maximum(y) - 0.08 * (maximum(y) - minimum(y)),
        text(@sprintf("corr = %.2f", corr_xy), 10, :black, :left),
    )

    combined = plot(p1, p2, p3, p4, layout=(2, 2), size=(1250, 850))
    savefig(combined, joinpath(output_dir, "hourly_financial_vs_physical_story.png"))
end

function build_generator_scatter_plot(financial_df::DataFrame, output_dir::AbstractString)
    hourly_gen = combine(
        groupby(financial_df, [:case_name, :generator, :global_hour]),
        :gross_trade => sum => :gross_trade,
        :retrade_adjustment => sum => :retrade_adjustment,
    )

    fixed = filter(:case_name => ==("Fixed 36h"), hourly_gen)
    select!(fixed, Not(:case_name))
    rename!(fixed, [:generator, :global_hour, :gross_trade_fixed, :retrade_adjustment_fixed])

    rolling = filter(:case_name => ==("Rolling 36h"), hourly_gen)
    select!(rolling, Not(:case_name))
    rename!(rolling, [:generator, :global_hour, :gross_trade_rolling, :retrade_adjustment_rolling])

    paired = innerjoin(fixed, rolling, on=[:generator, :global_hour])
    paired[!, :delta_gross_trade] = paired.gross_trade_fixed .- paired.gross_trade_rolling
    paired[!, :delta_retrade_adjustment_keur] =
        (paired.retrade_adjustment_fixed .- paired.retrade_adjustment_rolling) ./ 1e3

    generators = ["Base", "Mid", "Peak", "Solar", "Wind"]
    panels = Plots.Plot[]

    for gen in generators
        sub = filter(:generator => ==(gen), paired)
        x = sub.delta_gross_trade
        y = sub.delta_retrade_adjustment_keur
        p = scatter(
            x,
            y,
            color=:purple,
            alpha=0.65,
            markersize=3.5,
            xlabel="Fixed - Rolling gross traded volume (MWh)",
            ylabel="Fixed - Rolling re-trading adjustment (kEUR)",
            title=gen,
            label="",
        )
        hline!(p, [0.0], color=:black, linestyle=:dot, linewidth=1, label="")
        vline!(p, [0.0], color=:black, linestyle=:dot, linewidth=1, label="")
        if length(x) > 1 && std(x) > 0 && std(y) > 0
            corr_xy = cor(x, y)
            fit = hcat(ones(length(x)), x) \ y
            xline = range(minimum(x), maximum(x), length=100)
            yline = fit[1] .+ fit[2] .* xline
            plot!(p, xline, yline, color=:black, linewidth=1.5, linestyle=:dash, label="")
            annotate!(
                p,
                minimum(x) + 0.06 * (maximum(x) - minimum(x)),
                maximum(y) - 0.10 * (maximum(y) - minimum(y)),
                text(@sprintf("corr = %.2f", corr_xy), 9, :black, :left),
            )
        end
        push!(panels, p)
    end

    combined = plot(
        panels...,
        layout=(3, 2),
        size=(1350, 1000),
        plot_title="Generator-Level Re-trading Volume vs Trading Cashflow",
    )
    savefig(combined, joinpath(output_dir, "generator_retrade_scatter_panels.png"))
end

function build_duration_curve_plot(financial_df::DataFrame, output_dir::AbstractString)
    hourly = combine(
        groupby(financial_df, [:case_name, :global_hour]),
        :retrade_adjustment => sum => :retrade_adjustment,
    )

    p = plot(
        xlabel="Executed delivery hour rank",
        ylabel="Re-trading adjustment (kEUR)",
        title="Delivery-Hour Re-trading Adjustment Duration Curve",
        size=(1050, 500),
    )

    for case_name in ["Fixed 36h", "Rolling 36h"]
        vals = sort(collect(filter(:case_name => ==(case_name), hourly).retrade_adjustment), rev=true) ./ 1e3
        plot!(p, 1:length(vals), vals, linewidth=3, label=case_name)
    end

    savefig(p, joinpath(output_dir, "retrade_adjustment_duration_curve.png"))
end

function main()
    run_dir = length(ARGS) >= 1 ? ARGS[1] : DEFAULT_RUN_DIR
    isdir(run_dir) || error("Run directory not found: $run_dir")

    output_dir = joinpath(run_dir, "_revenue_profit_gap_analysis")
    isdir(output_dir) || mkpath(output_dir)

    generator_frames = DataFrame[]
    physical_frames = DataFrame[]
    financial_frames = DataFrame[]
    system_rows = NamedTuple[]

    for (case_name, folder_name) in CASE_FOLDERS
        all_results, cfg = load_case(run_dir, folder_name)
        push!(generator_frames, generator_summary(case_name, all_results, cfg))
        push!(physical_frames, executed_hour_rows(case_name, all_results, cfg))
        push!(financial_frames, financial_hour_rows(case_name, all_results, cfg))
        push!(system_rows, system_summary(case_name, all_results, cfg))
    end

    generator_df = vcat(generator_frames...)
    physical_df = vcat(physical_frames...)
    financial_df = vcat(financial_frames...)
    system_df = DataFrame(system_rows)
    hourly_df = paired_hourly_df(physical_df, financial_df)

    top_loss_hours = sort(
        select(
            hourly_df,
            :global_hour,
            :delta_retrade_adjustment,
            :delta_thermal_cost,
            :delta_welfare,
            :delta_gross_trade,
            :delta_price,
            :delta_net_discharge,
        ),
        :delta_retrade_adjustment,
        rev=true,
    )

    CSV.write(joinpath(output_dir, "generator_financial_comparison.csv"), generator_df)
    CSV.write(joinpath(output_dir, "executed_hourly_physical_comparison.csv"), physical_df)
    CSV.write(joinpath(output_dir, "generator_hourly_financial_comparison.csv"), financial_df)
    CSV.write(joinpath(output_dir, "system_level_comparison.csv"), system_df)
    CSV.write(joinpath(output_dir, "hourly_fixed_minus_rolling_comparison.csv"), hourly_df)
    CSV.write(joinpath(output_dir, "top_fixed_minus_rolling_retrade_hours.csv"), first(top_loss_hours, min(25, nrow(top_loss_hours))))

    build_generator_adjustment_plot(generator_df, output_dir)
    build_buyback_plot(generator_df, output_dir)
    build_hourly_story_plot(hourly_df, output_dir)
    build_generator_scatter_plot(financial_df, output_dir)
    build_duration_curve_plot(financial_df, output_dir)

    print_case_story(system_df)
    println()
    println("Saved revenue/profit gap analysis to: $output_dir")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

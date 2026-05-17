using CSV
using DataFrames
using Plots
using Plots.PlotMeasures
using Printf
using StatsPlots
using Statistics

const PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_RUN_DIR = joinpath(PROJECT_ROOT, "Results", "thesis_runs", "baseline_20260505_162324_seedA")
const GENERATORS = ["Base", "Solar", "Wind"]
const CASES = ["Fixed 36h", "Rolling 36h"]

default(
    guidefontsize = 18,
    tickfontsize = 15,
    titlefontsize = 22,
    legendfontsize = 14,
    linewidth = 3.0,
    left_margin = 10mm,
    right_margin = 6mm,
    bottom_margin = 8mm,
    top_margin = 6mm,
)

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
    return path
end

function load_required_csv(path::AbstractString)
    isfile(path) || error("Missing required CSV: $path")
    return CSV.read(path, DataFrame)
end

function case_generator_matrix(df::DataFrame, value_col::Symbol; scale::Float64=1.0)
    mat = zeros(Float64, length(GENERATORS), length(CASES))
    for (i, gen) in enumerate(GENERATORS), (j, case_name) in enumerate(CASES)
        rows = df[(df.generator .== gen) .& (df.case_name .== case_name), :]
        nrow(rows) == 1 || error("Expected one row for $case_name / $gen, found $(nrow(rows))")
        mat[i, j] = Float64(rows[1, value_col]) / scale
    end
    return mat
end

function label_bars!(x_positions, values; digits=1, suffix="")
    for (x, y) in zip(x_positions, values)
        annotate!(x, y, text("$(round(y; digits=digits))$suffix", 8, :bottom))
    end
end

function grouped_case_bar(title_text, ylabel_text, values; colors=[:steelblue3 :darkorange2])
    ymax = maximum(values)
    p = groupedbar(
        GENERATORS,
        values,
        label = reshape(CASES, 1, :),
        bar_position = :dodge,
        color = colors,
        ylabel = ylabel_text,
        title = title_text,
        legend = :topright,
        grid = :y,
        framestyle = :box,
        ylims = (0, ymax * 1.18),
        size = (1300, 760),
        left_margin = 16mm,
        bottom_margin = 14mm,
    )
    return p
end

function plot_profit_panel(financial_df::DataFrame)
    profit = case_generator_matrix(financial_df, :profit; scale=1e6)
    p = grouped_case_bar("Generator Profit", "EUR million", profit)
    hline!(p, [0.0], color=:black, linestyle=:dash, label=false)
    return p
end

function plot_volume_panel(trade_df::DataFrame)
    sold = case_generator_matrix(trade_df, :sold_qty; scale=1e6)
    buyback = case_generator_matrix(trade_df, :buyback_qty; scale=1e6)
    ymax = maximum(vcat(vec(sold), vec(buyback)))

    case_offsets = [-0.18, 0.18]
    p = plot(
        title = "Sold and Buyback Volumes",
        ylabel = "Volume (million MWh)",
        xticks = (1:length(GENERATORS), GENERATORS),
        xlims = (0.45, length(GENERATORS) + 0.55),
        ylims = (0, ymax * 1.22),
        legend = :topright,
        grid = :y,
        framestyle = :box,
        size = (1300, 760),
        left_margin = 16mm,
        bottom_margin = 14mm,
    )

    for (j, case_name) in enumerate(CASES)
        xpos = (1:length(GENERATORS)) .+ case_offsets[j]
        bar!(p, xpos, sold[:, j], bar_width=0.32, color=j == 1 ? :steelblue3 : :darkorange2,
             label="$case_name sold")
        scatter!(p, xpos, buyback[:, j], marker=:diamond, markersize=9,
                 color=j == 1 ? :navy : :orangered4, label="$case_name buyback")
    end
    return p
end

function plot_price_panel(trade_df::DataFrame)
    sell = case_generator_matrix(trade_df, :avg_sell_price)
    buyback = case_generator_matrix(trade_df, :avg_buyback_price)
    ymax = maximum(vcat(vec(sell), vec(buyback)))

    p = plot(
        title = "Average Sell and Buyback Prices",
        ylabel = "EUR/MWh",
        xticks = (1:length(GENERATORS), GENERATORS),
        xlims = (0.45, length(GENERATORS) + 0.55),
        ylims = (-2, ymax * 1.22),
        legend = :topright,
        grid = :y,
        framestyle = :box,
        size = (1400, 760),
        left_margin = 16mm,
        bottom_margin = 14mm,
    )

    offsets = [-0.18, 0.18]
    for (j, case_name) in enumerate(CASES)
        xpos = (1:length(GENERATORS)) .+ offsets[j]
        scatter!(p, xpos, sell[:, j], marker=:circle, markersize=10,
                 color=j == 1 ? :steelblue3 : :darkorange2, label="$case_name sell")
        scatter!(p, xpos, buyback[:, j], marker=:utriangle, markersize=10,
                 color=j == 1 ? :navy : :orangered4, label="$case_name buyback")
        for i in 1:length(GENERATORS)
            plot!(p, [xpos[i], xpos[i]], [buyback[i, j], sell[i, j]],
                  color=j == 1 ? :steelblue3 : :darkorange2, alpha=0.55, label=false)
        end
    end
    return p
end

function plot_base_lead_panel(base_lead_df::DataFrame)
    lead_order = ["lead_01_12", "lead_13_24", "lead_25_36"]
    lead_labels = ["1-12h", "13-24h", "25-36h"]
    volume = zeros(Float64, length(lead_order), length(CASES))
    price = zeros(Float64, length(lead_order), length(CASES))

    for (i, lead) in enumerate(lead_order), (j, case_name) in enumerate(CASES)
        rows = base_lead_df[(base_lead_df.lead_bucket .== lead) .& (base_lead_df.case_name .== case_name), :]
        nrow(rows) == 1 || error("Expected one Base lead row for $case_name / $lead, found $(nrow(rows))")
        volume[i, j] = Float64(rows[1, :sold_qty]) / 1e6
        price[i, j] = Float64(rows[1, :avg_price])
    end

    p1 = groupedbar(
        lead_labels,
        volume,
        label = reshape(CASES, 1, :),
        bar_position = :dodge,
        color = [:steelblue3 :darkorange2],
        ylabel = "Sold volume (m MWh)",
        title = "Base Sales by Lead Time",
        legend = :topright,
        grid = :y,
        framestyle = :box,
        ylims = (0, maximum(volume) * 1.22),
        left_margin = 16mm,
        bottom_margin = 14mm,
    )

    p2 = groupedbar(
        lead_labels,
        price,
        label = reshape(CASES, 1, :),
        bar_position = :dodge,
        color = [:steelblue3 :darkorange2],
        ylabel = "Avg sell price (EUR/MWh)",
        title = "Base Sell Price by Lead Time",
        legend = :bottomleft,
        grid = :y,
        framestyle = :box,
        ylims = (0, maximum(price) * 1.20),
        left_margin = 16mm,
        bottom_margin = 14mm,
    )

    return plot(p1, p2, layout=(1, 2), size=(1700, 700), bottom_margin=15mm)
end

function write_summary_table(financial_df::DataFrame, trade_df::DataFrame, output_dir::AbstractString)
    rows = NamedTuple[]
    for gen in GENERATORS
        fixed_fin = only(eachrow(financial_df[(financial_df.generator .== gen) .& (financial_df.case_name .== "Fixed 36h"), :]))
        rolling_fin = only(eachrow(financial_df[(financial_df.generator .== gen) .& (financial_df.case_name .== "Rolling 36h"), :]))
        fixed_trade = only(eachrow(trade_df[(trade_df.generator .== gen) .& (trade_df.case_name .== "Fixed 36h"), :]))
        rolling_trade = only(eachrow(trade_df[(trade_df.generator .== gen) .& (trade_df.case_name .== "Rolling 36h"), :]))

        push!(rows, (
            generator = gen,
            fixed_profit_mEUR = Float64(fixed_fin.profit) / 1e6,
            rolling_profit_mEUR = Float64(rolling_fin.profit) / 1e6,
            delta_profit_mEUR = (Float64(rolling_fin.profit) - Float64(fixed_fin.profit)) / 1e6,
            fixed_avg_sell_price = Float64(fixed_trade.avg_sell_price),
            rolling_avg_sell_price = Float64(rolling_trade.avg_sell_price),
            fixed_avg_buyback_price = Float64(fixed_trade.avg_buyback_price),
            rolling_avg_buyback_price = Float64(rolling_trade.avg_buyback_price),
            fixed_sold_mMWh = Float64(fixed_trade.sold_qty) / 1e6,
            rolling_sold_mMWh = Float64(rolling_trade.sold_qty) / 1e6,
            fixed_buyback_mMWh = Float64(fixed_trade.buyback_qty) / 1e6,
            rolling_buyback_mMWh = Float64(rolling_trade.buyback_qty) / 1e6,
        ))
    end
    out = DataFrame(rows)
    CSV.write(joinpath(output_dir, "seedA_trading_income_story_table.csv"), out)
    return out
end

function run_seedA_trading_income_plots(run_dir::AbstractString=DEFAULT_RUN_DIR)
    analysis_dir = joinpath(run_dir, "_revenue_profit_gap_analysis")
    output_dir = ensure_dir(joinpath(analysis_dir, "_trading_income_story_figures"))

    financial_df = load_required_csv(joinpath(analysis_dir, "generator_financial_comparison.csv"))
    trade_df = load_required_csv(joinpath(analysis_dir, "actual_trade_price_summary.csv"))
    base_lead_df = load_required_csv(joinpath(analysis_dir, "base_sold_by_lead_bucket.csv"))

    financial_df = financial_df[in.(financial_df.generator, Ref(GENERATORS)), :]
    trade_df = trade_df[in.(trade_df.generator, Ref(GENERATORS)), :]

    p_profit = plot_profit_panel(financial_df)
    p_volume = plot_volume_panel(trade_df)
    p_price = plot_price_panel(trade_df)
    p_base = plot_base_lead_panel(base_lead_df)

    combined = plot(
        p_profit,
        p_volume,
        p_price,
        p_base,
        layout = @layout([a b; c; d]),
        size = (2400, 2700),
        plot_title = "Seed A: Why Generator Trading Income Is Lower Under Rolling",
        left_margin = 20mm,
        right_margin = 12mm,
        bottom_margin = 18mm,
        top_margin = 14mm,
    )

    savefig(combined, joinpath(output_dir, "seedA_trading_income_story_combined.png"))
    savefig(p_profit, joinpath(output_dir, "seedA_profit_by_generator.png"))
    savefig(p_volume, joinpath(output_dir, "seedA_sold_buyback_volumes.png"))
    savefig(p_price, joinpath(output_dir, "seedA_sell_buyback_prices.png"))
    savefig(p_base, joinpath(output_dir, "seedA_base_lead_time_mechanism.png"))

    summary = write_summary_table(financial_df, trade_df, output_dir)

    println("Seed A trading-income figures written to:")
    println(output_dir)
    println()
    println("Summary table:")
    show(summary, allcols=true, allrows=true)
    println()
    return Dict(:output_dir => output_dir, :summary => summary)
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_dir = length(ARGS) >= 1 ? ARGS[1] : DEFAULT_RUN_DIR
    run_seedA_trading_income_plots(run_dir)
end

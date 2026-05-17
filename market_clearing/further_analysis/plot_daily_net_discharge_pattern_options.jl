using CSV
using DataFrames
using Plots
using Statistics

const RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260505_162324_seedA")
const HOURLY_CSV = joinpath(RUN_DIR, "_revenue_profit_gap_analysis", "executed_hourly_physical_comparison.csv")
const DAILY_CSV = joinpath(RUN_DIR, "_summary", "daily_drivers.csv")
const OUTPUT_DIR = joinpath(RUN_DIR, "_summary", "thesis_ready_figures")

const FIXED_LABEL = "Fixed 36h"
const ROLLING_LABEL = "Rolling 36h"

function add_day_hour!(df::DataFrame)
    df.simulation_day = fld.(df.global_hour .- 1, 24) .+ 1
    df.hour_of_day = mod.(df.global_hour .- 1, 24) .+ 1
    return df
end

function complete_days(df::DataFrame)
    counts = combine(groupby(df, [:case_name, :simulation_day]), nrow => :n)
    complete = counts[counts.n .== 24, [:case_name, :simulation_day]]
    return innerjoin(df, complete, on=[:case_name, :simulation_day])
end

function case_matrix(df::DataFrame, case_name::AbstractString; days=nothing)
    case_df = df[df.case_name .== case_name, :]
    selected_days = isnothing(days) ? sort(unique(case_df.simulation_day)) : collect(days)
    mat = fill(NaN, length(selected_days), 24)
    for (i, day) in enumerate(selected_days)
        day_df = sort(case_df[case_df.simulation_day .== day, :], :hour_of_day)
        if nrow(day_df) == 24
            mat[i, :] .= day_df.net_discharge
        end
    end
    return selected_days, mat
end

function hourly_quantiles(mat::AbstractMatrix)
    q10 = Float64[]
    q25 = Float64[]
    q50 = Float64[]
    q75 = Float64[]
    q90 = Float64[]
    for h in 1:size(mat, 2)
        vals = collect(skipmissing(mat[:, h]))
        push!(q10, quantile(vals, 0.10))
        push!(q25, quantile(vals, 0.25))
        push!(q50, quantile(vals, 0.50))
        push!(q75, quantile(vals, 0.75))
        push!(q90, quantile(vals, 0.90))
    end
    return q10, q25, q50, q75, q90
end

function save_both(plt, basename::AbstractString)
    mkpath(OUTPUT_DIR)
    png_path = joinpath(OUTPUT_DIR, basename * ".png")
    pdf_path = joinpath(OUTPUT_DIR, basename * ".pdf")
    savefig(plt, png_path)
    savefig(plt, pdf_path)
    println("Saved: ", png_path)
    println("Saved: ", pdf_path)
end

function plot_median_band(df::DataFrame)
    hours = 1:24
    fixed_days, fixed_mat = case_matrix(df, FIXED_LABEL)
    rolling_days, rolling_mat = case_matrix(df, ROLLING_LABEL)
    _, fq25, fq50, fq75, _ = hourly_quantiles(fixed_mat)
    _, rq25, rq50, rq75, _ = hourly_quantiles(rolling_mat)

    plt = plot(
        size=(840, 500),
        dpi=300,
        title="Daily Battery Net Discharge by Hour of Day",
        xlabel="Hour of day",
        ylabel="Net discharge (MWh)",
        xlims=(1, 24),
        xticks=1:2:24,
        legend=:topright,
        grid=true,
        framestyle=:box,
        background_color=:white,
        foreground_color=:black,
        margin=6Plots.mm,
    )
    hline!(plt, [0.0], label="", color=:gray55, linewidth=1.0)

    for i in 1:length(fixed_days)
        plot!(plt, hours, fixed_mat[i, :], color=:steelblue, alpha=0.12, linewidth=0.9, label="")
    end
    for i in 1:length(rolling_days)
        plot!(plt, hours, rolling_mat[i, :], color=:darkorange, alpha=0.12, linewidth=0.9, label="")
    end

    plot!(
        plt, hours, fq50,
        ribbon=(fq50 .- fq25, fq75 .- fq50),
        color=:steelblue,
        fillalpha=0.18,
        linewidth=3,
        label="fixed median and IQR",
    )
    plot!(
        plt, hours, rq50,
        ribbon=(rq50 .- rq25, rq75 .- rq50),
        color=:darkorange,
        fillalpha=0.18,
        linewidth=3,
        label="rolling median and IQR",
    )

    save_both(plt, "baseline_13_daily_net_discharge_median_iqr_seedA")
end

function plot_fixed_rolling_heatmaps(df::DataFrame)
    days, fixed_mat = case_matrix(df, FIXED_LABEL)
    _, rolling_mat = case_matrix(df, ROLLING_LABEL; days=days)
    zlim = maximum(abs.([fixed_mat[:]; rolling_mat[:]]))

    p1 = heatmap(
        1:24, days, fixed_mat,
        title="fixed",
        xlabel="Hour of day",
        ylabel="Simulation day",
        color=:balance,
        clim=(-zlim, zlim),
        xlims=(1, 24),
        xticks=1:2:24,
        colorbar_title="MWh",
        framestyle=:box,
    )
    p2 = heatmap(
        1:24, days, rolling_mat,
        title="rolling",
        xlabel="Hour of day",
        ylabel="Simulation day",
        color=:balance,
        clim=(-zlim, zlim),
        xlims=(1, 24),
        xticks=1:2:24,
        colorbar_title="MWh",
        framestyle=:box,
    )
    plt = plot(p1, p2, layout=(1, 2), size=(980, 430), dpi=300, margin=6Plots.mm)
    save_both(plt, "baseline_14_daily_net_discharge_heatmaps_fixed_rolling_seedA")
end

function welfare_ordered_days(df::DataFrame)
    daily = CSV.read(DAILY_CSV, DataFrame)
    rows = daily[daily.delta_definition .== "Rolling 36h - Fixed 36h", :]
    complete = unique(df.simulation_day)
    rows = rows[in.(rows.simulation_day, Ref(complete)), :]
    sort!(rows, :delta_social_welfare_eur, rev=true)
    return collect(rows.simulation_day), collect(rows.delta_social_welfare_eur)
end

function plot_ordered_heatmaps(df::DataFrame)
    ordered_days, delta_swf = welfare_ordered_days(df)
    _, fixed_mat = case_matrix(df, FIXED_LABEL; days=ordered_days)
    _, rolling_mat = case_matrix(df, ROLLING_LABEL; days=ordered_days)
    delta_mat = rolling_mat .- fixed_mat

    y = 1:length(ordered_days)
    zlim = maximum(abs.([fixed_mat[:]; rolling_mat[:]]))
    dzlim = maximum(abs.(delta_mat[:]))

    p1 = heatmap(
        1:24, y, fixed_mat,
        title="fixed",
        xlabel="Hour of day",
        ylabel="Days ranked by ΔSWF",
        color=:balance,
        clim=(-zlim, zlim),
        xticks=1:2:24,
        yticks=(y, string.(ordered_days)),
        colorbar_title="MWh",
        framestyle=:box,
    )
    p2 = heatmap(
        1:24, y, rolling_mat,
        title="rolling",
        xlabel="Hour of day",
        ylabel="",
        color=:balance,
        clim=(-zlim, zlim),
        xticks=1:2:24,
        yticks=false,
        colorbar_title="MWh",
        framestyle=:box,
    )
    p3 = heatmap(
        1:24, y, delta_mat,
        title="rolling minus fixed",
        xlabel="Hour of day",
        ylabel="",
        color=:balance,
        clim=(-dzlim, dzlim),
        xticks=1:2:24,
        yticks=false,
        colorbar_title="MWh",
        framestyle=:box,
    )
    plt = plot(p1, p2, p3, layout=(1, 3), size=(1320, 520), dpi=300, margin=6Plots.mm)
    save_both(plt, "baseline_15_daily_net_discharge_ordered_by_swf_fixed_rolling_delta_seedA")
end

function main()
    df = CSV.read(HOURLY_CSV, DataFrame)
    add_day_hour!(df)
    df = complete_days(df)
    plot_median_band(df)
    plot_fixed_rolling_heatmaps(df)
    plot_ordered_heatmaps(df)
end

main()

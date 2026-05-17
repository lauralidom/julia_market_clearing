using CSV
using DataFrames
using Dates
using Plots
using Serialization
using Statistics

const RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260505_162324_seedA")
const HOURLY_CSV = joinpath(RUN_DIR, "_revenue_profit_gap_analysis", "executed_hourly_physical_comparison.csv")
const OUTPUT_DIR = joinpath(RUN_DIR, "_summary", "thesis_ready_figures")
const FIXED_LABEL = "Fixed 36h"
const ROLLING_LABEL = "Rolling 36h"

function load_simulation_start()
    cfg_path = joinpath(RUN_DIR, "fixed_36h", "cfg.jls")
    cfg = deserialize(cfg_path)
    rh = cfg["rolling_horizon"]
    sim_month = Int(rh["simulation_month"])
    sim_start_hour = Int(get(rh, "simulation_start_hour", 0))
    return DateTime(2025, sim_month, 1, sim_start_hour), sim_start_hour
end

function add_clock_time!(df::DataFrame, sim_start_dt::DateTime)
    df[!, :timestamp] = sim_start_dt .+ Hour.(Int.(df.global_hour) .- 1)
    df[!, :calendar_date] = Date.(df.timestamp)
    df[!, :clock_hour] = Dates.hour.(df.timestamp)
    df[!, :original_plot_hour] = mod.(Int.(df.global_hour) .- 1, 24) .+ 1
    return df
end

function complete_calendar_days(df::DataFrame)
    counts = combine(groupby(df, [:case_name, :calendar_date]), nrow => :n)
    complete = counts[counts.n .== 24, [:case_name, :calendar_date]]
    return innerjoin(df, complete, on=[:case_name, :calendar_date])
end

function clock_hour_quantiles(df::DataFrame, case_name::AbstractString)
    case_df = df[df.case_name .== case_name, :]
    rows = NamedTuple[]
    for h in 0:23
        vals = Float64.(case_df[case_df.clock_hour .== h, :net_discharge])
        isempty(vals) && continue
        push!(rows, (
            clock_hour = h,
            n = length(vals),
            q25 = quantile(vals, 0.25),
            median = quantile(vals, 0.50),
            q75 = quantile(vals, 0.75),
            mean = mean(vals),
        ))
    end
    return DataFrame(rows)
end

function case_calendar_matrix(df::DataFrame, case_name::AbstractString; dates=nothing)
    case_df = df[df.case_name .== case_name, :]
    selected_dates = isnothing(dates) ? sort(unique(case_df.calendar_date)) : collect(dates)
    mat = fill(NaN, length(selected_dates), 24)
    for (i, date) in enumerate(selected_dates)
        day_df = sort(case_df[case_df.calendar_date .== date, :], :clock_hour)
        if nrow(day_df) == 24
            mat[i, :] .= Float64.(day_df.net_discharge)
        end
    end
    return selected_dates, mat
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

function save_mapping(sim_start_hour::Int)
    rows = [
        (
            original_plot_hour = h,
            clock_hour = mod(sim_start_hour + h - 1, 24),
            note = "Original plot hour $h is clock hour $(lpad(string(mod(sim_start_hour + h - 1, 24)), 2, '0')):00"
        )
        for h in 1:24
    ]
    path = joinpath(OUTPUT_DIR, "baseline_13_time_axis_mapping_seedA.csv")
    CSV.write(path, DataFrame(rows))
    println("Saved: ", path)
end

function plot_clock_median_band(df::DataFrame)
    fixed = clock_hour_quantiles(df, FIXED_LABEL)
    rolling = clock_hour_quantiles(df, ROLLING_LABEL)

    plt = plot(
        size=(880, 500),
        dpi=300,
        title="Daily Battery Net Discharge by Clock Hour",
        xlabel="Clock hour (start of interval)",
        ylabel="Net discharge (MWh)",
        xlims=(0, 23),
        xticks=0:1:23,
        legend=:topright,
        grid=true,
        framestyle=:box,
        background_color=:white,
        foreground_color=:black,
        margin=6Plots.mm,
    )
    hline!(plt, [0.0], label="", color=:gray55, linewidth=1.0)

    _, fixed_mat = case_calendar_matrix(df, FIXED_LABEL)
    _, rolling_mat = case_calendar_matrix(df, ROLLING_LABEL)
    hours = collect(0:23)
    for i in 1:size(fixed_mat, 1)
        plot!(plt, hours, fixed_mat[i, :], color=:steelblue, alpha=0.12, linewidth=0.9, label="")
    end
    for i in 1:size(rolling_mat, 1)
        plot!(plt, hours, rolling_mat[i, :], color=:darkorange, alpha=0.12, linewidth=0.9, label="")
    end

    plot!(
        plt, fixed.clock_hour, fixed.median,
        ribbon=(fixed.median .- fixed.q25, fixed.q75 .- fixed.median),
        color=:steelblue,
        fillalpha=0.18,
        linewidth=3,
        label="fixed median and IQR",
    )
    plot!(
        plt, rolling.clock_hour, rolling.median,
        ribbon=(rolling.median .- rolling.q25, rolling.q75 .- rolling.median),
        color=:darkorange,
        fillalpha=0.18,
        linewidth=3,
        label="rolling median and IQR",
    )

    save_both(plt, "baseline_13_daily_net_discharge_median_iqr_clock_hour_seedA")
end

function plot_clock_heatmaps(df::DataFrame)
    dates, fixed_mat = case_calendar_matrix(df, FIXED_LABEL)
    _, rolling_mat = case_calendar_matrix(df, ROLLING_LABEL; dates=dates)
    zlim = maximum(abs.([fixed_mat[:]; rolling_mat[:]]))
    ylabels = Dates.format.(dates, dateformat"mm-dd")

    p1 = heatmap(
        0:23, 1:length(dates), fixed_mat,
        title="fixed",
        xlabel="Clock hour",
        ylabel="Calendar date",
        color=:balance,
        clim=(-zlim, zlim),
        xlims=(0, 23),
        xticks=0:2:23,
        yticks=(1:length(dates), ylabels),
        colorbar_title="MWh",
        framestyle=:box,
    )
    p2 = heatmap(
        0:23, 1:length(dates), rolling_mat,
        title="rolling",
        xlabel="Clock hour",
        ylabel="",
        color=:balance,
        clim=(-zlim, zlim),
        xlims=(0, 23),
        xticks=0:2:23,
        yticks=false,
        colorbar_title="MWh",
        framestyle=:box,
    )
    plt = plot(p1, p2, layout=(1, 2), size=(1000, 480), dpi=300, margin=6Plots.mm)
    save_both(plt, "baseline_14_daily_net_discharge_heatmaps_clock_hour_seedA")
end

function print_clock_summary(df::DataFrame, sim_start_dt::DateTime, sim_start_hour::Int)
    println("Simulation starts at: ", sim_start_dt)
    println("simulation_start_hour: ", sim_start_hour)
    println("Original plot hour mapping:")
    for h in 1:24
        @info "plot_hour=$h clock_hour=$(mod(sim_start_hour + h - 1, 24))"
    end

    fixed = clock_hour_quantiles(df, FIXED_LABEL)
    rolling = clock_hour_quantiles(df, ROLLING_LABEL)
    paired = innerjoin(
        select(fixed, :clock_hour, :median => :fixed_median),
        select(rolling, :clock_hour, :median => :rolling_median),
        on=:clock_hour,
    )
    paired[!, :fixed_minus_rolling_median] = paired.fixed_median .- paired.rolling_median
    println("\nClock-hour median net discharge:")
    show(paired, allrows=true, allcols=true)
    println()
end

function main()
    sim_start_dt, sim_start_hour = load_simulation_start()
    df = CSV.read(HOURLY_CSV, DataFrame)
    add_clock_time!(df, sim_start_dt)
    complete = complete_calendar_days(df)

    mkpath(OUTPUT_DIR)
    CSV.write(joinpath(OUTPUT_DIR, "baseline_13_executed_hourly_with_clock_time_seedA.csv"), complete)
    save_mapping(sim_start_hour)
    plot_clock_median_band(complete)
    plot_clock_heatmaps(complete)
    print_clock_summary(complete, sim_start_dt, sim_start_hour)
end

main()

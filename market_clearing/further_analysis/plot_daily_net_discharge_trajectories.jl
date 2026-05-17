using CSV
using DataFrames
using Plots

const RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260505_162324_seedA")
const INPUT_CSV = joinpath(RUN_DIR, "_revenue_profit_gap_analysis", "executed_hourly_physical_comparison.csv")
const OUTPUT_DIR = joinpath(RUN_DIR, "_summary", "thesis_ready_figures")

function add_day_hour!(df::DataFrame)
    df.simulation_day = fld.(df.global_hour .- 1, 24) .+ 1
    df.hour_of_day = mod.(df.global_hour .- 1, 24) .+ 1
    return df
end

function complete_days(df::DataFrame)
    counts = combine(groupby(df, [:case_name, :simulation_day]), nrow => :n)
    complete = counts[counts.n .== 24, [:case_name, :simulation_day]]
    innerjoin(df, complete, on=[:case_name, :simulation_day])
end

function plot_daily_net_discharge_trajectories()
    df = CSV.read(INPUT_CSV, DataFrame)
    add_day_hour!(df)
    df = complete_days(df)

    fixed_df = df[df.case_name .== "Fixed 36h", :]
    rolling_df = df[df.case_name .== "Rolling 36h", :]

    plt = plot(
        size=(760, 460),
        dpi=300,
        title="Battery Net Discharge by Hour of Day: Daily Trajectories",
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

    fixed_days = sort(unique(fixed_df.simulation_day))
    rolling_days = sort(unique(rolling_df.simulation_day))

    for (i, day) in enumerate(fixed_days)
        day_df = sort(fixed_df[fixed_df.simulation_day .== day, :], :hour_of_day)
        plot!(
            plt,
            day_df.hour_of_day,
            day_df.net_discharge,
            color=:steelblue,
            alpha=0.24,
            linewidth=1.2,
            label=i == 1 ? "fixed" : "",
        )
    end

    for (i, day) in enumerate(rolling_days)
        day_df = sort(rolling_df[rolling_df.simulation_day .== day, :], :hour_of_day)
        plot!(
            plt,
            day_df.hour_of_day,
            day_df.net_discharge,
            color=:darkorange,
            alpha=0.24,
            linewidth=1.2,
            label=i == 1 ? "rolling" : "",
        )
    end

    mkpath(OUTPUT_DIR)
    png_path = joinpath(OUTPUT_DIR, "baseline_12_daily_net_discharge_trajectories_seedA.png")
    pdf_path = joinpath(OUTPUT_DIR, "baseline_12_daily_net_discharge_trajectories_seedA.pdf")
    savefig(plt, png_path)
    savefig(plt, pdf_path)
    println("Saved: ", png_path)
    println("Saved: ", pdf_path)
end

plot_daily_net_discharge_trajectories()

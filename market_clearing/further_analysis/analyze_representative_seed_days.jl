using CSV
using DataFrames
using Dates
using Plots
using Printf
using Serialization
using Statistics

include(joinpath(@__DIR__, "..", "src", "thesis_runner.jl"))

const SCRIPT_DIR = @__DIR__
const PROJECT_ROOT = normpath(joinpath(SCRIPT_DIR, ".."))
const DEFAULT_RUN_ROOT = joinpath(PROJECT_ROOT, "Results", "thesis_runs")
const OUTPUT_DIRNAME = "_representative_seed_days"

const RUN_SELECTORS = [
    "baseline_20260505_162324_seedA",
    "baseline_20260505_162603_seedB",
    "baseline_20260505_162837_seedC",
]

const AUTO_RUN_WHEN_INCLUDED = true

default(
    guidefontsize = 12,
    tickfontsize = 9,
    titlefontsize = 14,
    legendfontsize = 9,
)

struct LoadedCase
    run_name::String
    case_name::String
    all_results::Dict
    cfg::Dict
    hourly::DataFrame
    realized_supply::DataFrame
end

function slugify(text::AbstractString)
    safe = replace(lowercase(String(text)), r"[^a-z0-9]+" => "_")
    safe = replace(safe, r"^_+|_+$" => "")
    return isempty(safe) ? "item" : safe
end

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
    return path
end

function simulation_start_datetime(cfg::Dict)
    rh = cfg["rolling_horizon"]
    sim_month = Int(get(rh, "simulation_month", 1))
    sim_start_hour = Int(get(rh, "simulation_start_hour", 0))
    return DateTime(2025, sim_month, 1, sim_start_hour)
end

function total_hours_for_cfg(cfg::Dict)
    rh = cfg["rolling_horizon"]
    simulated_delivery_hours = Int(get(rh, "comparable_delivery_hours_override", calculate_comparable_delivery_hours(cfg)))
    look_ahead = Int(rh["look_ahead_window"])
    return simulated_delivery_hours + look_ahead
end

function resolve_run_dir(selector::AbstractString)
    raw = strip(String(selector))
    isempty(raw) && error("Empty run selector provided.")

    candidates = String[
        normpath(raw),
        normpath(joinpath(PROJECT_ROOT, raw)),
        normpath(joinpath(DEFAULT_RUN_ROOT, raw)),
    ]

    for path in candidates
        isdir(path) && return path
    end

    error("Could not resolve run directory from selector: $raw")
end

function load_daily_driver_rows(run_dir::AbstractString)
    path = joinpath(run_dir, "_summary", "daily_drivers.csv")
    isfile(path) || error("Missing daily_drivers.csv: $path")
    df = CSV.read(path, DataFrame)
    df = df[(df.case_a .== "Fixed 36h") .& (df.case_b .== "Rolling 36h"), :]
    insertcols!(df, 1, :run_name => fill(basename(run_dir), nrow(df)))
    return df
end

function cross_seed_day_table(run_dirs::Vector{String})
    all_rows = DataFrame()
    for run_dir in run_dirs
        df = load_daily_driver_rows(run_dir)
        all_rows = isempty(all_rows) ? df : vcat(all_rows, df, cols = :union)
    end

    summary = combine(
        groupby(all_rows, :calendar_day),
        :delta_social_welfare_eur => mean => :mean_delta_swf,
        :delta_social_welfare_eur => median => :median_delta_swf,
        :delta_social_welfare_eur => std => :std_delta_swf,
        :delta_social_welfare_eur => (x -> sum(x .> 0)) => :n_positive,
        :delta_social_welfare_eur => (x -> sum(x .< 0)) => :n_negative,
        :delta_social_welfare_eur => (x -> sum(x .== 0)) => :n_zero,
    )

    summary.sign_pattern = [
        row.n_positive == length(run_dirs) ? "all_positive" :
        row.n_negative == length(run_dirs) ? "all_negative" :
        "mixed"
        for row in eachrow(summary)
    ]
    summary.abs_mean_delta_swf = abs.(summary.mean_delta_swf)
    return all_rows, summary
end

function select_representative_days(summary::DataFrame)
    positive = sort(summary[summary.sign_pattern .== "all_positive", :], :mean_delta_swf, rev = true)
    negative = sort(summary[summary.sign_pattern .== "all_negative", :], :mean_delta_swf)
    mixed = sort(summary[summary.sign_pattern .== "mixed", :], [:std_delta_swf, :abs_mean_delta_swf], rev = [true, true])

    selected = DataFrame()
    for (source, category) in ((positive, "best_positive"), (negative, "worst_negative"), (mixed, "flip"))
        n = min(2, nrow(source))
        if n > 0
            picked = source[1:n, :]
            insertcols!(picked, 1, :selection_category => fill(String(category), n))
            selected = isempty(selected) ? picked : vcat(selected, picked, cols = :union)
        end
    end

    return selected
end

function extract_hourly_case_rows(all_results::Dict, cfg::Dict)
    details_dict = all_results[:clearing_details]
    sim_start_dt = simulation_start_datetime(cfg)
    rows = NamedTuple[]

    for clearing_num in sort(collect(keys(details_dict)))
        details = details_dict[clearing_num]
        current_hour = Int(details[:current_hour])
        executed_hours = Int(details[:executed_hours])

        for h in 1:executed_hours
            abs_hour = current_hour + h - 1
            hour_dt = sim_start_dt + Hour(abs_hour - 1)
            mid_dispatch = float(details[:g_planned]["Mid", h])
            peak_dispatch = float(details[:g_planned]["Peak", h])
            base_dispatch = float(details[:g_planned]["Base", h])
            charge = float(details[:charging][h])
            discharge = float(details[:discharging][h])
            soc_end = h <= length(details[:storage_soc_path]) ? float(details[:storage_soc_path][h]) : float(details[:storage_soc_end_executed])

            push!(rows, (
                clearing_num = clearing_num,
                abs_hour = abs_hour,
                hour_dt = hour_dt,
                calendar_day = Date(hour_dt),
                hour_of_day = hour(hour_dt),
                price = float(details[:prices][h]),
                charge = charge,
                discharge = discharge,
                net_discharge = discharge - charge,
                soc_end = soc_end,
                soc_start_clearing = float(details[:storage_soc_start]),
                mid_dispatch = mid_dispatch,
                peak_dispatch = peak_dispatch,
                mid_peak_dispatch = mid_dispatch + peak_dispatch,
                base_dispatch = base_dispatch,
                thermal_dispatch = base_dispatch + mid_dispatch + peak_dispatch,
                wind_dispatch = float(details[:g_planned]["Wind", h]),
                solar_dispatch = float(details[:g_planned]["Solar", h]),
                demand_base = float(details[:demand_base][h]),
                demand_flex = float(details[:demand_flex][h]),
                total_demand = float(details[:demand_base][h]) + float(details[:demand_flex][h]),
                imbalance = h == 1 ? float(get(details, :imbalance_h1, 0.0)) : 0.0,
            ))
        end
    end

    return DataFrame(rows)
end

function realized_supply_df(cfg::Dict)
    total_hours = total_hours_for_cfg(cfg)
    _, q_gen_full, _, _ = load_and_expand_timeseries(cfg, total_hours)
    sim_start_dt = simulation_start_datetime(cfg)
    rows = NamedTuple[]
    available_hours = sort(unique(h for (g, h) in keys(q_gen_full) if g == "Wind"))

    for abs_hour in available_hours
        hour_dt = sim_start_dt + Hour(abs_hour - 1)
        push!(rows, (
            abs_hour = abs_hour,
            hour_dt = hour_dt,
            calendar_day = Date(hour_dt),
            hour_of_day = hour(hour_dt),
            wind_available = float(q_gen_full[("Wind", abs_hour)]),
            solar_available = float(q_gen_full[("Solar", abs_hour)]),
        ))
    end

    return DataFrame(rows)
end

function load_case(run_dir::AbstractString, case_slug::AbstractString, case_name::AbstractString)
    case_dir = joinpath(run_dir, case_slug)
    isdir(case_dir) || error("Missing case directory: $case_dir")
    all_results = deserialize(joinpath(case_dir, "all_results.jls"))
    cfg = deserialize(joinpath(case_dir, "cfg.jls"))
    return LoadedCase(
        basename(run_dir),
        case_name,
        all_results,
        cfg,
        extract_hourly_case_rows(all_results, cfg),
        realized_supply_df(cfg),
    )
end

function load_seed_pair(run_dir::AbstractString)
    return Dict(
        :fixed => load_case(run_dir, "fixed_36h", "Fixed 36h"),
        :rolling => load_case(run_dir, "rolling_36h", "Rolling 36h"),
    )
end

function day_global_hour_bounds(cfg::Dict, calendar_day::Date)
    sim_start_dt = simulation_start_datetime(cfg)
    day_start_dt = DateTime(calendar_day)
    day_start_hour = Int(Dates.value(day_start_dt - sim_start_dt) ÷ (60 * 60 * 1000)) + 1
    day_end_hour = day_start_hour + 23
    return day_start_hour, day_end_hour
end

function build_wind_forecast_snapshots(cfg::Dict, calendar_day::Date)
    scenario_path = String(cfg["rolling_horizon"]["wind_noise_scenario_path"])
    forecast_errors, _, _ = wind_forecast_error_rows_from_csv(scenario_path)
    supply = realized_supply_df(cfg)
    day_supply = supply[supply.calendar_day .== calendar_day, :]
    isempty(day_supply) && return DataFrame()

    day_start_hour, day_end_hour = day_global_hour_bounds(cfg, calendar_day)
    wind_capacity = float(cfg["variableGenerators"]["Wind"]["capacity"])
    look_ahead = Int(cfg["rolling_horizon"]["look_ahead_window"])

    snapshot_defs = [
        (max(1, day_start_hour - 24), "24h before day"),
        (day_start_hour, "Day start"),
        (min(day_end_hour, day_start_hour + 12), "Midday"),
    ]

    rows = NamedTuple[]
    for (window_start_hour, label) in snapshot_defs
        for row in eachrow(day_supply)
            abs_hour = Int(row.abs_hour)
            if abs_hour < window_start_hour || abs_hour > window_start_hour + look_ahead - 1
                continue
            end

            lead_time = abs_hour - window_start_hour + 1
            realized = float(row.wind_available)
            forecast =
                if lead_time == 1
                    realized
                else
                    err = get(forecast_errors, (window_start_hour, abs_hour), 0.0)
                    af = realized / wind_capacity
                    wind_capacity * clamp(af * (1 + err), 0.0, 1.0)
                end

            push!(rows, (
                snapshot_label = label,
                window_start_hour = window_start_hour,
                abs_hour = abs_hour,
                hour_dt = row.hour_dt,
                hour_of_day = Int(row.hour_of_day),
                realized_wind = realized,
                forecast_wind = forecast,
            ))
        end
    end

    return DataFrame(rows)
end

function executed_day_df(case::LoadedCase, calendar_day::Date)
    return sort(case.hourly[case.hourly.calendar_day .== calendar_day, :], :abs_hour)
end

function realized_day_supply_df(case::LoadedCase, calendar_day::Date)
    return sort(case.realized_supply[case.realized_supply.calendar_day .== calendar_day, :], :abs_hour)
end

function clearing_soc_value_df(case::LoadedCase, calendar_day::Date)
    sim_start_dt = simulation_start_datetime(case.cfg)
    rows = NamedTuple[]

    for clearing_num in sort(collect(keys(case.all_results[:clearing_details])))
        details = case.all_results[:clearing_details][clearing_num]
        current_hour = Int(details[:current_hour])
        hour_dt = sim_start_dt + Hour(current_hour - 1)
        if Date(hour_dt) != calendar_day
            continue
        end

        push!(rows, (
            clearing_num = clearing_num,
            current_hour = current_hour,
            hour_dt = hour_dt,
            hour_of_day = hour(hour_dt),
            marginal_soc_value = -float(details[:storage_initial_soc_dual]),
            storage_soc_start = float(details[:storage_soc_start]),
            look_ahead = Int(details[:look_ahead]),
        ))
    end

    return DataFrame(rows)
end

function day_storage_economics(df::DataFrame)
    total_charge = sum(df.charge)
    total_discharge = sum(df.discharge)
    charging_cost = sum(df.charge .* df.price)
    discharge_revenue = sum(df.discharge .* df.price)
    return (
        charge_mwh = total_charge,
        discharge_mwh = total_discharge,
        throughput_mwh = total_charge + total_discharge,
        net_revenue_eur = discharge_revenue - charging_cost,
        avg_charging_price = total_charge > 0 ? charging_cost / total_charge : 0.0,
        avg_discharging_price = total_discharge > 0 ? discharge_revenue / total_discharge : 0.0,
    )
end

function format_metric_line(io::IO, label::AbstractString, left::Real, right::Real)
    @printf(io, "  %-24s fixed=%12.2f | rolling=%12.2f | delta=%12.2f\n", label, left, right, right - left)
end

function plot_seed_day(fixed_case::LoadedCase, rolling_case::LoadedCase, calendar_day::Date, output_path::AbstractString;
                       day_row::Union{Nothing, DataFrameRow}=nothing)
    fixed_day = executed_day_df(fixed_case, calendar_day)
    rolling_day = executed_day_df(rolling_case, calendar_day)
    supply_day = realized_day_supply_df(fixed_case, calendar_day)

    nrow(fixed_day) > 0 || error("No executed fixed rows for $(fixed_case.run_name) on $calendar_day")
    nrow(rolling_day) > 0 || error("No executed rolling rows for $(rolling_case.run_name) on $calendar_day")

    x_fixed = fixed_day.hour_of_day
    x_rolling = rolling_day.hour_of_day
    x_supply = supply_day.hour_of_day

    p1 = plot(
        x_supply,
        supply_day.wind_available,
        label = "Wind",
        linewidth = 2.5,
        color = :seagreen4,
        xlabel = "Hour of day",
        ylabel = "MW",
        title = "Wind and solar generation",
    )
    plot!(p1, x_supply, supply_day.solar_available, label = "Solar", linewidth = 2.5, color = :goldenrod2)

    p2 = plot(
        x_fixed,
        fixed_day.price,
        label = "Fixed price",
        linewidth = 2.5,
        color = :gray35,
        linestyle = :dash,
        xlabel = "Hour of day",
        ylabel = "EUR/MWh",
        title = "Delivery-hour price",
    )
    plot!(p2, x_rolling, rolling_day.price, label = "Rolling price", linewidth = 2.5, color = :royalblue3)

    p3 = plot(
        x_fixed,
        fixed_day.discharge,
        label = "Fixed discharge",
        linewidth = 2.2,
        color = :gray35,
        linestyle = :solid,
        xlabel = "Hour of day",
        ylabel = "MW",
        title = "Storage Charging and Discharging",
    )
    plot!(p3, x_fixed, .-fixed_day.charge, label = "Fixed charge", linewidth = 2.0, color = :gray60, linestyle = :dash)
    plot!(p3, x_rolling, rolling_day.discharge, label = "Rolling discharge", linewidth = 2.2, color = :royalblue3)
    plot!(p3, x_rolling, .-rolling_day.charge, label = "Rolling charge", linewidth = 2.0, color = :deepskyblue3, linestyle = :dash)
    hline!(p3, [0.0], color = :black, alpha = 0.4, label = "")

    p4 = plot(
        x_fixed,
        fixed_day.soc_end,
        label = "Fixed SOC",
        linewidth = 2.5,
        color = :gray35,
        linestyle = :dash,
        xlabel = "Hour of day",
        ylabel = "MWh",
        title = "Storage State of Charge",
    )
    plot!(p4, x_rolling, rolling_day.soc_end, label = "Rolling SOC", linewidth = 2.5, color = :royalblue3)

    p5 = plot(
        x_fixed,
        fixed_day.mid_peak_dispatch,
        label = "Fixed Mid+Peak",
        linewidth = 2.5,
        color = :gray35,
        linestyle = :dash,
        xlabel = "Hour of day",
        ylabel = "MW",
        title = "Mid and Peak Dispatch",
    )
    plot!(p5, x_rolling, rolling_day.mid_peak_dispatch, label = "Rolling Mid+Peak", linewidth = 2.5, color = :royalblue3)
    plot!(p5, x_fixed, fixed_day.peak_dispatch, label = "Fixed Peak", linewidth = 1.8, color = :gray60, linestyle = :dot)
    plot!(p5, x_rolling, rolling_day.peak_dispatch, label = "Rolling Peak", linewidth = 1.8, color = :firebrick3, linestyle = :dot)

    combined = plot(
        p1, p2, p3, p4, p5;
        layout = (5, 1),
        size = (1250, 1750),
        plot_title = Dates.format(calendar_day, dateformat"d u yyyy"),
    )
    savefig(combined, output_path)
    return combined
end

function day_story_text(io::IO, day_row::DataFrameRow, run_rows::DataFrame, seed_pairs::Dict{String, Dict})
    println(io, "Date: $(day_row.calendar_day)")
    println(io, "Category: $(day_row.selection_category)")
    println(io, "Cross-seed sign pattern: $(day_row.sign_pattern)")
    @printf(io, "Cross-seed mean delta SWF: %.2f EUR | median: %.2f EUR | std: %.2f EUR\n", day_row.mean_delta_swf, day_row.median_delta_swf, day_row.std_delta_swf)
    @printf(io, "Sign counts: +%d / -%d / 0=%d\n", day_row.n_positive, day_row.n_negative, day_row.n_zero)
    println(io)

    for row in eachrow(sort(run_rows, :run_name))
        pair = seed_pairs[String(row.run_name)]
        fixed_day = executed_day_df(pair[:fixed], day_row.calendar_day)
        rolling_day = executed_day_df(pair[:rolling], day_row.calendar_day)
        fixed_econ = day_storage_economics(fixed_day)
        rolling_econ = day_storage_economics(rolling_day)
        fixed_soc_value = clearing_soc_value_df(pair[:fixed], day_row.calendar_day)
        rolling_soc_value = clearing_soc_value_df(pair[:rolling], day_row.calendar_day)

        println(io, "Run: $(row.run_name)")
        @printf(io, "  delta SWF=%12.2f EUR | delta GenCost=%12.2f EUR | delta DemandValue=%12.2f EUR\n", row.delta_social_welfare_eur, row.delta_generation_cost_eur, row.delta_demand_value_eur)
        @printf(io, "  delta Imbalance=%8.2f MWh | delta Wind=%8.2f MWh | delta Solar=%8.2f MWh | delta Mid+Peak=%8.2f MWh\n", row.delta_imbalance_mwh, row.delta_wind_mwh, row.delta_solar_mwh, row.delta_mid_peak_dispatch_mwh)
        @printf(io, "  delta NetStorageDischarge=%8.2f MWh | delta StorageRevenue=%12.2f EUR | delta Throughput=%8.2f MWh\n", row.delta_net_storage_discharge_mwh, row.delta_storage_revenue_eur, row.delta_storage_throughput_mwh)
        @printf(io, "  Visible |FE| delta=%7.4f | Tail |FE| delta=%7.4f | Renewable share delta=%7.4f\n", row.delta_avg_visible_abs_forecast_error, row.delta_avg_tail_abs_forecast_error, row.delta_renewable_share_of_demand)
        if nrow(fixed_soc_value) > 0 && nrow(rolling_soc_value) > 0
            format_metric_line(io, "Avg marginal SOC value", mean(fixed_soc_value.marginal_soc_value), mean(rolling_soc_value.marginal_soc_value))
            format_metric_line(io, "Max marginal SOC value", maximum(fixed_soc_value.marginal_soc_value), maximum(rolling_soc_value.marginal_soc_value))
        end
        format_metric_line(io, "Storage revenue", fixed_econ.net_revenue_eur, rolling_econ.net_revenue_eur)
        format_metric_line(io, "Charge (MWh)", fixed_econ.charge_mwh, rolling_econ.charge_mwh)
        format_metric_line(io, "Discharge (MWh)", fixed_econ.discharge_mwh, rolling_econ.discharge_mwh)
        format_metric_line(io, "Throughput (MWh)", fixed_econ.throughput_mwh, rolling_econ.throughput_mwh)
        format_metric_line(io, "Avg charging price", fixed_econ.avg_charging_price, rolling_econ.avg_charging_price)
        format_metric_line(io, "Avg discharging price", fixed_econ.avg_discharging_price, rolling_econ.avg_discharging_price)
        println(io)
    end

    println(io, "-"^100)
end

function run_representative_seed_day_analysis(run_selectors::Vector{String}=RUN_SELECTORS; verbose::Bool=true)
    run_dirs = [resolve_run_dir(selector) for selector in run_selectors]
    output_root = ensure_dir(joinpath(DEFAULT_RUN_ROOT, OUTPUT_DIRNAME))

    verbose && println("Representative seed-day analysis")
    verbose && println("Run directories:")
    for run_dir in run_dirs
        verbose && println("  - $run_dir")
    end

    all_rows, summary = cross_seed_day_table(run_dirs)
    selected = select_representative_days(summary)
    CSV.write(joinpath(output_root, "selected_days.csv"), selected)

    seed_pairs = Dict{String, Dict}()
    for run_dir in run_dirs
        seed_pairs[basename(run_dir)] = load_seed_pair(run_dir)
    end

    overview_path = joinpath(output_root, "representative_day_summary.txt")
    open(overview_path, "w") do io
        println(io, "REPRESENTATIVE CROSS-SEED DAY ANALYSIS")
        println(io, "="^100)
        println(io, "Runs:")
        for run_dir in run_dirs
            println(io, "  - $(basename(run_dir))")
        end
        println(io)
        println(io, "Selected days:")
        show(io, MIME("text/plain"), selected)
        println(io, "\n")

        for day_row in eachrow(selected)
            day_dir = ensure_dir(joinpath(output_root, "$(day_row.selection_category)_$(Dates.format(day_row.calendar_day, dateformat"yyyymmdd"))"))
            run_rows = sort(all_rows[all_rows.calendar_day .== day_row.calendar_day, :], :run_name)
            CSV.write(joinpath(day_dir, "daily_driver_rows.csv"), run_rows)

            for row in eachrow(run_rows)
                pair = seed_pairs[String(row.run_name)]
                plot_path = joinpath(day_dir, "$(slugify(row.run_name)).png")
                plot_seed_day(pair[:fixed], pair[:rolling], day_row.calendar_day, plot_path; day_row=row)
            end

            day_story_text(io, day_row, run_rows, seed_pairs)
        end
    end

    verbose && println("Wrote representative-day analysis to: $output_root")
    return Dict(
        :output_root => output_root,
        :selected_days => selected,
        :all_rows => all_rows,
        :summary => summary,
        :overview_path => overview_path,
    )
end

function run_seedA_selected_days(; verbose::Bool=true)
    run_dir = resolve_run_dir("baseline_20260505_162324_seedA")
    pair = load_seed_pair(run_dir)
    output_dir = ensure_dir(joinpath(DEFAULT_RUN_ROOT, OUTPUT_DIRNAME, "seedA"))
    selected_days = [
        ("positive", Date(2025, 5, 5)),
        ("positive", Date(2025, 5, 20)),
        ("negative", Date(2025, 5, 4)),
        ("negative", Date(2025, 5, 7)),
    ]

    verbose && println("Seed A selected-day plots")
    verbose && println("Run directory: $run_dir")
    verbose && println("Output directory: $output_dir")

    for (label, calendar_day) in selected_days
        filename = "$(label)_$(Dates.format(calendar_day, dateformat"yyyymmdd"))_seeda.png"
        output_path = joinpath(output_dir, filename)
        plot_seed_day(pair[:fixed], pair[:rolling], calendar_day, output_path)
        verbose && println("  Saved: $output_path")
    end

    return Dict(
        :run_dir => run_dir,
        :output_dir => output_dir,
        :selected_days => selected_days,
    )
end

function main()
    println()
    println("="^80)
    println("REPRESENTATIVE SEED-DAY ANALYSIS")
    println("="^80)
    result = run_representative_seed_day_analysis(RUN_SELECTORS; verbose = true)
    println("Selected days written to: $(joinpath(result[:output_root], "selected_days.csv"))")
    println("Text summary written to: $(result[:overview_path])")
    println("="^80)
    return result
end

function should_auto_run_when_included()
    return AUTO_RUN_WHEN_INCLUDED && isinteractive() && !isempty(RUN_SELECTORS)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
elseif should_auto_run_when_included()
    println("AUTO_RUN_WHEN_INCLUDED is enabled. Running representative seed-day analysis.")
    main()
end

using CSV
using DataFrames
using Dates
using Printf
using Serialization
using Statistics

include(joinpath(@__DIR__, "..", "src", "thesis_runner.jl"))

const PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))
const RUN_ROOT = joinpath(PROJECT_ROOT, "Results", "thesis_runs")
const RUN_SELECTORS = [
    "baseline_20260505_162324",
    "baseline_20260505_162603",
    "baseline_20260505_162837",
]

function resolve_run_dir(selector::AbstractString)
    candidates = [
        normpath(selector),
        normpath(joinpath(PROJECT_ROOT, selector)),
        normpath(joinpath(RUN_ROOT, selector)),
    ]
    for candidate in candidates
        isdir(candidate) && return candidate
    end
    error("Could not resolve run selector: $selector")
end

function simulation_start_datetime(cfg::Dict)
    rh = cfg["rolling_horizon"]
    sim_month = Int(get(rh, "simulation_month", 1))
    sim_start_hour = Int(get(rh, "simulation_start_hour", 0))
    return DateTime(2025, sim_month, 1, sim_start_hour)
end

function total_hours_for_cfg(cfg::Dict)
    rh = cfg["rolling_horizon"]
    delivery_hours = Int(get(rh, "comparable_delivery_hours_override", calculate_comparable_delivery_hours(cfg)))
    return delivery_hours + Int(rh["look_ahead_window"])
end

function load_case(run_dir::AbstractString, case_slug::AbstractString)
    case_dir = joinpath(run_dir, case_slug)
    return (
        all_results = deserialize(joinpath(case_dir, "all_results.jls")),
        cfg = deserialize(joinpath(case_dir, "cfg.jls")),
    )
end

function exogenous_timeseries(cfg::Dict)
    _, q_gen, _, q_dem = load_and_expand_timeseries(cfg, total_hours_for_cfg(cfg))
    return q_gen, q_dem
end

function total_demand(q_dem, abs_hour::Int)
    return sum(get(q_dem, (segment, abs_hour), 0.0) for segment in ("Base", "Flex"))
end

function renewable(q_gen, abs_hour::Int)
    return get(q_gen, ("Wind", abs_hour), 0.0) + get(q_gen, ("Solar", abs_hour), 0.0)
end

function residual_load(q_gen, q_dem, abs_hour::Int)
    return total_demand(q_dem, abs_hour) - renewable(q_gen, abs_hour)
end

function executed_hourly_rows(case_results::Dict, cfg::Dict)
    sim_start = simulation_start_datetime(cfg)
    rows = NamedTuple[]
    for clearing in sort(collect(keys(case_results[:clearing_details])))
        details = case_results[:clearing_details][clearing]
        current_hour = Int(details[:current_hour])
        for h in 1:Int(details[:executed_hours])
            abs_hour = current_hour + h - 1
            dt = sim_start + Hour(abs_hour - 1)
            push!(rows, (
                clearing = clearing,
                abs_hour = abs_hour,
                dt = dt,
                calendar_day = Date(dt),
                hour_of_day = hour(dt),
                price = Float64(details[:prices][h]),
                charge = Float64(details[:charging][h]),
                discharge = Float64(details[:discharging][h]),
                net_discharge = Float64(details[:discharging][h]) - Float64(details[:charging][h]),
                soc_end = Float64(details[:storage_soc_path][h]),
                mid_dispatch = Float64(details[:g_planned]["Mid", h]),
                peak_dispatch = Float64(details[:g_planned]["Peak", h]),
                mid_peak_dispatch = Float64(details[:g_planned]["Mid", h]) + Float64(details[:g_planned]["Peak", h]),
            ))
        end
    end
    return DataFrame(rows)
end

function sum_between(df::DataFrame, column::Symbol, start_abs::Int, end_abs::Int)
    end_abs < start_abs && return 0.0
    sub = df[(df.abs_hour .>= start_abs) .& (df.abs_hour .<= end_abs), :]
    nrow(sub) == 0 && return 0.0
    return sum(skipmissing(sub[!, column]))
end

function value_at_abs(df::DataFrame, column::Symbol, abs_hour::Int)
    sub = df[df.abs_hour .== abs_hour, :]
    nrow(sub) == 0 && return missing
    return sub[1, column]
end

function analyze_run(run_dir::AbstractString)
    fixed = load_case(run_dir, "fixed_36h")
    rolling = load_case(run_dir, "rolling_36h")
    q_gen, q_dem = exogenous_timeseries(fixed.cfg)
    fixed_hourly = executed_hourly_rows(fixed.all_results, fixed.cfg)
    rolling_hourly = executed_hourly_rows(rolling.all_results, rolling.cfg)
    sim_start = simulation_start_datetime(fixed.cfg)

    max_lookahead = Int(fixed.cfg["rolling_horizon"]["look_ahead_window"])
    min_lookahead = Int(get(fixed.cfg["rolling_horizon"], "fixed_horizon_min_window", 13))

    rows = NamedTuple[]
    fixed_details = fixed.all_results[:clearing_details]
    rolling_details = rolling.all_results[:clearing_details]

    for clearing in sort(collect(keys(fixed_details)))
        haskey(rolling_details, clearing) || continue
        f = fixed_details[clearing]
        r = rolling_details[clearing]
        current_hour = Int(f[:current_hour])
        fixed_lh = Int(f[:look_ahead])
        rolling_lh = Int(r[:look_ahead])
        fixed_lh < rolling_lh || continue

        hidden_start = current_hour + fixed_lh
        hidden_end = current_hour + rolling_lh - 1
        hidden_start <= hidden_end || continue

        hidden_hours = collect(hidden_start:hidden_end)
        visible_tail_hours = collect(max(current_hour, hidden_start - length(hidden_hours)):hidden_start-1)
        hidden_residual = [residual_load(q_gen, q_dem, h) for h in hidden_hours]
        hidden_renewable = [renewable(q_gen, h) for h in hidden_hours]
        visible_residual = isempty(visible_tail_hours) ? Float64[] : [residual_load(q_gen, q_dem, h) for h in visible_tail_hours]
        visible_renewable = isempty(visible_tail_hours) ? Float64[] : [renewable(q_gen, h) for h in visible_tail_hours]

        hours_until_reset = fixed_lh - min_lookahead + 1
        early_end = current_hour + max(hours_until_reset, 1) - 1

        dt = sim_start + Hour(current_hour - 1)
        hidden_start_dt = sim_start + Hour(hidden_start - 1)
        hidden_end_dt = sim_start + Hour(hidden_end - 1)

        fixed_msv = -Float64(f[:storage_initial_soc_dual])
        rolling_msv = -Float64(r[:storage_initial_soc_dual])
        fixed_soc_start = Float64(f[:storage_soc_start])
        rolling_soc_start = Float64(r[:storage_soc_start])

        fixed_net_early = sum_between(fixed_hourly, :net_discharge, current_hour, early_end)
        rolling_net_early = sum_between(rolling_hourly, :net_discharge, current_hour, early_end)
        fixed_mid_peak_early = sum_between(fixed_hourly, :mid_peak_dispatch, current_hour, early_end)
        rolling_mid_peak_early = sum_between(rolling_hourly, :mid_peak_dispatch, current_hour, early_end)
        fixed_soc_at_reset = value_at_abs(fixed_hourly, :soc_end, early_end)
        rolling_soc_at_reset = value_at_abs(rolling_hourly, :soc_end, early_end)

        push!(rows, (
            run_name = basename(run_dir),
            clearing = clearing,
            current_dt = dt,
            current_day = Date(dt),
            hour_of_day = hour(dt),
            fixed_lookahead = fixed_lh,
            rolling_lookahead = rolling_lh,
            hidden_start_dt = hidden_start_dt,
            hidden_end_dt = hidden_end_dt,
            hidden_hours = length(hidden_hours),
            hidden_avg_residual_load = mean(hidden_residual),
            hidden_max_residual_load = maximum(hidden_residual),
            hidden_min_renewable = minimum(hidden_renewable),
            hidden_avg_renewable = mean(hidden_renewable),
            visible_avg_residual_load = isempty(visible_residual) ? missing : mean(visible_residual),
            visible_avg_renewable = isempty(visible_renewable) ? missing : mean(visible_renewable),
            hidden_minus_visible_residual = isempty(visible_residual) ? missing : mean(hidden_residual) - mean(visible_residual),
            fixed_marginal_soc_value = fixed_msv,
            rolling_marginal_soc_value = rolling_msv,
            delta_marginal_soc_value = rolling_msv - fixed_msv,
            fixed_soc_start = fixed_soc_start,
            rolling_soc_start = rolling_soc_start,
            delta_soc_start = rolling_soc_start - fixed_soc_start,
            early_window_end_dt = sim_start + Hour(early_end - 1),
            fixed_net_discharge_until_reset = fixed_net_early,
            rolling_net_discharge_until_reset = rolling_net_early,
            delta_net_discharge_until_reset = rolling_net_early - fixed_net_early,
            fixed_soc_at_reset = fixed_soc_at_reset,
            rolling_soc_at_reset = rolling_soc_at_reset,
            delta_soc_at_reset = ismissing(fixed_soc_at_reset) || ismissing(rolling_soc_at_reset) ? missing : rolling_soc_at_reset - fixed_soc_at_reset,
            fixed_mid_peak_until_reset = fixed_mid_peak_early,
            rolling_mid_peak_until_reset = rolling_mid_peak_early,
            delta_mid_peak_until_reset = rolling_mid_peak_early - fixed_mid_peak_early,
        ))
    end

    return DataFrame(rows)
end

function print_candidate(row)
    @printf("\nCandidate hidden-event clearing: %s | %s\n", row.run_name, string(row.current_dt))
    @printf("  Fixed sees %dh; rolling sees %dh. Rolling-only tail: %s -> %s (%dh)\n",
            row.fixed_lookahead, row.rolling_lookahead, string(row.hidden_start_dt), string(row.hidden_end_dt), row.hidden_hours)
    @printf("  Hidden tail avg residual load: %.1f MWh/h; max residual: %.1f; min renewable: %.1f; avg renewable: %.1f\n",
            row.hidden_avg_residual_load, row.hidden_max_residual_load, row.hidden_min_renewable, row.hidden_avg_renewable)
    @printf("  Marginal SOC value: fixed %.1f vs rolling %.1f EUR/MWh (delta %.1f)\n",
            row.fixed_marginal_soc_value, row.rolling_marginal_soc_value, row.delta_marginal_soc_value)
    @printf("  Until fixed reset (%s): net discharge fixed %.1f vs rolling %.1f MWh (delta %.1f)\n",
            string(row.early_window_end_dt), row.fixed_net_discharge_until_reset, row.rolling_net_discharge_until_reset, row.delta_net_discharge_until_reset)
    @printf("  SOC at reset: fixed %s vs rolling %s MWh (delta %s)\n",
            string(round(row.fixed_soc_at_reset; digits=1)), string(round(row.rolling_soc_at_reset; digits=1)), string(round(row.delta_soc_at_reset; digits=1)))
    @printf("  Mid+Peak until reset: fixed %.1f vs rolling %.1f MWh (delta %.1f)\n",
            row.fixed_mid_peak_until_reset, row.rolling_mid_peak_until_reset, row.delta_mid_peak_until_reset)
end

function hourly_comparison_for_window(run_dir::AbstractString, start_dt::DateTime, end_dt::DateTime)
    fixed = load_case(run_dir, "fixed_36h")
    rolling = load_case(run_dir, "rolling_36h")
    sim_start = simulation_start_datetime(fixed.cfg)
    start_abs = Int(Dates.value(start_dt - sim_start) ÷ Dates.value(Hour(1))) + 1
    end_abs = Int(Dates.value(end_dt - sim_start) ÷ Dates.value(Hour(1))) + 1

    fixed_hourly = executed_hourly_rows(fixed.all_results, fixed.cfg)
    rolling_hourly = executed_hourly_rows(rolling.all_results, rolling.cfg)
    fixed_details = fixed.all_results[:clearing_details]
    rolling_details = rolling.all_results[:clearing_details]

    rows = NamedTuple[]
    for abs_hour in start_abs:end_abs
        f = fixed_hourly[fixed_hourly.abs_hour .== abs_hour, :]
        r = rolling_hourly[rolling_hourly.abs_hour .== abs_hour, :]
        if nrow(f) == 0 || nrow(r) == 0
            continue
        end
        f_clearing = Int(f[1, :clearing])
        r_clearing = Int(r[1, :clearing])
        push!(rows, (
            dt = f[1, :dt],
            hour_of_day = f[1, :hour_of_day],
            fixed_lookahead = Int(fixed_details[f_clearing][:look_ahead]),
            rolling_lookahead = Int(rolling_details[r_clearing][:look_ahead]),
            fixed_price = f[1, :price],
            rolling_price = r[1, :price],
            fixed_marginal_soc_value = -Float64(fixed_details[f_clearing][:storage_initial_soc_dual]),
            rolling_marginal_soc_value = -Float64(rolling_details[r_clearing][:storage_initial_soc_dual]),
            fixed_charge = f[1, :charge],
            rolling_charge = r[1, :charge],
            fixed_discharge = f[1, :discharge],
            rolling_discharge = r[1, :discharge],
            fixed_net_discharge = f[1, :net_discharge],
            rolling_net_discharge = r[1, :net_discharge],
            fixed_soc_end = f[1, :soc_end],
            rolling_soc_end = r[1, :soc_end],
            delta_soc_end = r[1, :soc_end] - f[1, :soc_end],
            fixed_mid_peak = f[1, :mid_peak_dispatch],
            rolling_mid_peak = r[1, :mid_peak_dispatch],
            delta_mid_peak = r[1, :mid_peak_dispatch] - f[1, :mid_peak_dispatch],
        ))
    end
    return DataFrame(rows)
end

function run_hidden_horizon_event_analysis(run_selectors::Vector{String}=RUN_SELECTORS)
    all_rows = DataFrame()
    for selector in run_selectors
        run_dir = resolve_run_dir(selector)
        df = analyze_run(run_dir)
        all_rows = isempty(all_rows) ? df : vcat(all_rows, df, cols=:union)
    end

    output_dir = joinpath(RUN_ROOT, "_hidden_horizon_events")
    isdir(output_dir) || mkpath(output_dir)
    CSV.write(joinpath(output_dir, "hidden_horizon_event_candidates.csv"), all_rows)

    morning = all_rows[(all_rows.fixed_lookahead .<= 18) .& (all_rows.fixed_lookahead .>= 13), :]
    morning.score = coalesce.(morning.hidden_minus_visible_residual, 0.0) .+
                    0.25 .* morning.hidden_max_residual_load .+
                    50.0 .* (morning.delta_marginal_soc_value .> 1.0)
    ranked = sort(morning, :score, rev=true)
    CSV.write(joinpath(output_dir, "ranked_morning_hidden_events.csv"), ranked)

    println("Hidden horizon event analysis")
    println("Rows written to: ", output_dir)
    println("Top morning candidates, where fixed is shortest and rolling has extra next-day visibility:")
    for row in eachrow(ranked[1:min(8, nrow(ranked)), :])
        print_candidate(row)
    end

    behavioral = ranked[(abs.(ranked.delta_soc_at_reset) .>= 1000.0) .| (abs.(ranked.delta_net_discharge_until_reset) .>= 1000.0), :]
    if nrow(behavioral) > 0
        chosen = behavioral[1, :]
        println("\nDetailed behavioural case study:")
        print_candidate(chosen)
        run_dir = resolve_run_dir(chosen.run_name)
        hourly = hourly_comparison_for_window(run_dir, DateTime(chosen.current_day) + Hour(6), DateTime(chosen.current_day) + Hour(11))
        hourly_path = joinpath(output_dir, "case_study_$(chosen.run_name)_$(replace(string(chosen.current_day), "-" => ""))_morning.csv")
        CSV.write(hourly_path, hourly)
        println("  Hourly comparison written to: ", hourly_path)
        println("  Morning hour-by-hour summary:")
        for row in eachrow(hourly)
            @printf("    %s | LH fixed %2d | MSV F/R %5.1f/%5.1f | netdis F/R %7.1f/%7.1f | SOC F/R %7.1f/%7.1f | price F/R %5.1f/%5.1f\n",
                    string(row.dt), row.fixed_lookahead, row.fixed_marginal_soc_value, row.rolling_marginal_soc_value,
                    row.fixed_net_discharge, row.rolling_net_discharge, row.fixed_soc_end, row.rolling_soc_end,
                    row.fixed_price, row.rolling_price)
        end
    end

    return ranked
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_hidden_horizon_event_analysis()
end

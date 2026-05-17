using CSV
using DataFrames
using JuMP
using Printf
using Serialization
using Statistics

const SCRIPT_DIR = @__DIR__
const PROJECT_ROOT = normpath(joinpath(SCRIPT_DIR, ".."))
const DEFAULT_RUN_DIR = joinpath(PROJECT_ROOT, "Results", "thesis_runs", "baseline_20260505_162324_seedA")
const OUTPUT_DIRNAME = "_fixed_horizon_evening_discharge"

function resolve_run_dir(args)
    if !isempty(args)
        raw = args[1]
        candidates = [
            normpath(raw),
            normpath(joinpath(PROJECT_ROOT, raw)),
            normpath(joinpath(PROJECT_ROOT, "Results", "thesis_runs", raw)),
        ]
        for candidate in candidates
            if isdir(candidate)
                return candidate
            end
        end
        error("Could not resolve run directory from selector: $raw")
    end
    return DEFAULT_RUN_DIR
end

function load_case(run_dir::AbstractString, case_slug::AbstractString)
    path = joinpath(run_dir, case_slug, "all_results.jls")
    isfile(path) || error("Missing results file: $path")
    return deserialize(path)
end

function load_cfg(run_dir::AbstractString, case_slug::AbstractString)
    path = joinpath(run_dir, case_slug, "cfg.jls")
    isfile(path) || error("Missing config file: $path")
    return deserialize(path)
end

clock_hour_1_24(global_hour::Integer, simulation_start_hour::Integer) =
    mod(simulation_start_hour + global_hour - 2, 24) + 1

function quantile_or_missing(values::Vector{Float64}, p::Real)
    isempty(values) ? missing : quantile(values, p)
end

function case_hourly_records(all_results::Dict, case_name::AbstractString, simulation_start_hour::Integer)
    rows = NamedTuple[]
    details_dict = all_results[:clearing_details]

    for clearing_num in sort(collect(keys(details_dict)))
        details = details_dict[clearing_num]
        current_hour = Int(details[:current_hour])
        look_ahead = Int(details[:look_ahead])
        executed_hours = Int(details[:executed_hours])
        horizon_end_hour = current_hour + look_ahead - 1
        hours_to_horizon_end = look_ahead .- collect(1:executed_hours)

        soc_path = get(details, :storage_soc_path, Float64[])
        soc_start = Float64(get(details, :storage_soc_start, NaN))

        for h in 1:executed_hours
            global_hour = current_hour + h - 1
            hour_of_day = clock_hour_1_24(global_hour, simulation_start_hour)
            day_index = div(global_hour - 1, 24) + 1
            net_discharge = Float64(details[:discharging][h]) - Float64(details[:charging][h])
            soc_end = h <= length(soc_path) ? Float64(soc_path[h]) : NaN
            soc_before = h == 1 ? soc_start : (h - 1 <= length(soc_path) ? Float64(soc_path[h - 1]) : NaN)

            push!(rows, (
                case_name = String(case_name),
                clearing_num = Int(clearing_num),
                current_hour = current_hour,
                look_ahead = look_ahead,
                executed_hours = executed_hours,
                h_in_clearing = h,
                global_hour = global_hour,
                day_index = day_index,
                hour_of_day = hour_of_day,
                horizon_end_hour = horizon_end_hour,
                horizon_end_hour_of_day = clock_hour_1_24(horizon_end_hour, simulation_start_hour),
                hours_to_horizon_end = Int(hours_to_horizon_end[h]),
                net_discharge_mwh = net_discharge,
                charge_mwh = Float64(details[:charging][h]),
                discharge_mwh = Float64(details[:discharging][h]),
                soc_before_mwh = soc_before,
                soc_end_mwh = soc_end,
                price_eur_per_mwh = Float64(details[:prices][h]),
            ))
        end
    end

    return DataFrame(rows)
end

function case_clearing_records(all_results::Dict, case_name::AbstractString, simulation_start_hour::Integer)
    rows = NamedTuple[]
    details_dict = all_results[:clearing_details]

    for clearing_num in sort(collect(keys(details_dict)))
        details = details_dict[clearing_num]
        current_hour = Int(details[:current_hour])
        look_ahead = Int(details[:look_ahead])
        horizon_end_hour = current_hour + look_ahead - 1
        soc_path = get(details, :storage_soc_path, Float64[])
        terminal_soc = Float64(get(details, :storage_soc_end_window, isempty(soc_path) ? NaN : soc_path[end]))
        executed_soc = Float64(get(details, :storage_soc_end_executed, NaN))

        push!(rows, (
            case_name = String(case_name),
            clearing_num = Int(clearing_num),
            current_hour = current_hour,
            clearing_start_hour_of_day = clock_hour_1_24(current_hour, simulation_start_hour),
            look_ahead = look_ahead,
            horizon_end_hour = horizon_end_hour,
            horizon_end_hour_of_day = clock_hour_1_24(horizon_end_hour, simulation_start_hour),
            storage_soc_start_mwh = Float64(get(details, :storage_soc_start, NaN)),
            storage_soc_end_executed_mwh = executed_soc,
            storage_soc_end_window_mwh = terminal_soc,
            planned_net_discharge_window_mwh = sum(Float64.(details[:discharging])) - sum(Float64.(details[:charging])),
            planned_evening_net_discharge_mwh = sum(
                Float64(details[:discharging][h]) - Float64(details[:charging][h])
                for h in 1:look_ahead
                if 17 <= clock_hour_1_24(current_hour + h - 1, simulation_start_hour) <= 19
                ; init=0.0
            ),
        ))
    end

    return DataFrame(rows)
end

function summarize_by_hour(df::DataFrame)
    grouped = groupby(df, [:case_name, :hour_of_day])
    return combine(grouped,
        :net_discharge_mwh => length => :n,
        :net_discharge_mwh => mean => :mean_net_discharge_mwh,
        :net_discharge_mwh => median => :median_net_discharge_mwh,
        :net_discharge_mwh => (x -> quantile(collect(Float64, x), 0.25)) => :q25_net_discharge_mwh,
        :net_discharge_mwh => (x -> quantile(collect(Float64, x), 0.75)) => :q75_net_discharge_mwh,
        :soc_before_mwh => median => :median_soc_before_mwh,
        :soc_end_mwh => median => :median_soc_end_mwh,
        :hours_to_horizon_end => median => :median_hours_to_horizon_end,
    )
end

function summarize_evening_pair(fixed::DataFrame, rolling::DataFrame)
    rows = NamedTuple[]
    for hour in 17:19
        f = fixed[fixed.hour_of_day .== hour, :]
        r = rolling[rolling.hour_of_day .== hour, :]
        push!(rows, (
            hour_of_day = hour,
            fixed_median_net_discharge_mwh = median(f.net_discharge_mwh),
            rolling_median_net_discharge_mwh = median(r.net_discharge_mwh),
            fixed_minus_rolling_median_mwh = median(f.net_discharge_mwh) - median(r.net_discharge_mwh),
            fixed_mean_net_discharge_mwh = mean(f.net_discharge_mwh),
            rolling_mean_net_discharge_mwh = mean(r.net_discharge_mwh),
            fixed_median_soc_before_mwh = median(f.soc_before_mwh),
            rolling_median_soc_before_mwh = median(r.soc_before_mwh),
            fixed_median_hours_to_horizon_end = median(f.hours_to_horizon_end),
            rolling_median_hours_to_horizon_end = median(r.hours_to_horizon_end),
            n_fixed = nrow(f),
            n_rolling = nrow(r),
        ))
    end
    return DataFrame(rows)
end

function daily_evening_records(fixed::DataFrame, rolling::DataFrame)
    f = combine(groupby(fixed[in.(fixed.hour_of_day, Ref(17:19)), :], :day_index),
        :net_discharge_mwh => sum => :fixed_evening_net_discharge_mwh,
        :soc_before_mwh => first => :fixed_soc_before_hour17_mwh,
        :hours_to_horizon_end => median => :fixed_median_hours_to_horizon_end,
    )
    r = combine(groupby(rolling[in.(rolling.hour_of_day, Ref(17:19)), :], :day_index),
        :net_discharge_mwh => sum => :rolling_evening_net_discharge_mwh,
        :soc_before_mwh => first => :rolling_soc_before_hour17_mwh,
        :hours_to_horizon_end => median => :rolling_median_hours_to_horizon_end,
    )
    joined = innerjoin(f, r, on=:day_index)
    joined[!, :fixed_minus_rolling_evening_net_discharge_mwh] =
        joined.fixed_evening_net_discharge_mwh .- joined.rolling_evening_net_discharge_mwh
    joined[!, :fixed_minus_rolling_soc_before_hour17_mwh] =
        joined.fixed_soc_before_hour17_mwh .- joined.rolling_soc_before_hour17_mwh
    return joined
end

function pair_hourly(fixed::DataFrame, rolling::DataFrame)
    f = select(fixed,
        :day_index,
        :hour_of_day,
        :global_hour,
        :net_discharge_mwh => :fixed_net_discharge_mwh,
        :charge_mwh => :fixed_charge_mwh,
        :discharge_mwh => :fixed_discharge_mwh,
        :soc_before_mwh => :fixed_soc_before_mwh,
        :soc_end_mwh => :fixed_soc_end_mwh,
        :price_eur_per_mwh => :fixed_price_eur_per_mwh,
        :hours_to_horizon_end => :fixed_hours_to_horizon_end,
    )
    r = select(rolling,
        :day_index,
        :hour_of_day,
        :net_discharge_mwh => :rolling_net_discharge_mwh,
        :charge_mwh => :rolling_charge_mwh,
        :discharge_mwh => :rolling_discharge_mwh,
        :soc_before_mwh => :rolling_soc_before_mwh,
        :soc_end_mwh => :rolling_soc_end_mwh,
        :price_eur_per_mwh => :rolling_price_eur_per_mwh,
        :hours_to_horizon_end => :rolling_hours_to_horizon_end,
    )
    paired = innerjoin(f, r, on=[:day_index, :hour_of_day])
    paired[!, :delta_net_discharge_mwh] = paired.fixed_net_discharge_mwh .- paired.rolling_net_discharge_mwh
    paired[!, :delta_charge_mwh] = paired.fixed_charge_mwh .- paired.rolling_charge_mwh
    paired[!, :delta_discharge_mwh] = paired.fixed_discharge_mwh .- paired.rolling_discharge_mwh
    paired[!, :delta_soc_before_mwh] = paired.fixed_soc_before_mwh .- paired.rolling_soc_before_mwh
    paired[!, :delta_soc_end_mwh] = paired.fixed_soc_end_mwh .- paired.rolling_soc_end_mwh
    paired[!, :delta_price_eur_per_mwh] = paired.fixed_price_eur_per_mwh .- paired.rolling_price_eur_per_mwh
    paired[!, :delta_hours_to_horizon_end] = paired.fixed_hours_to_horizon_end .- paired.rolling_hours_to_horizon_end
    return paired
end

function daily_prepeak_decomposition(paired::DataFrame; target_hour::Int=17)
    rows = NamedTuple[]
    for day in sort(unique(paired.day_index))
        day_df = paired[paired.day_index .== day, :]
        target = day_df[day_df.hour_of_day .== target_hour, :]
        nrow(target) == 1 || continue
        before = day_df[day_df.hour_of_day .< target_hour, :]
        morning = before[(6 .<= before.hour_of_day .<= 10), :]
        midday = before[(11 .<= before.hour_of_day .<= 16), :]

        push!(rows, (
            day_index = day,
            delta_soc_before_target_mwh = only(target.delta_soc_before_mwh),
            fixed_soc_before_target_mwh = only(target.fixed_soc_before_mwh),
            rolling_soc_before_target_mwh = only(target.rolling_soc_before_mwh),
            pre_target_delta_charge_mwh = sum(before.delta_charge_mwh),
            pre_target_delta_discharge_mwh = sum(before.delta_discharge_mwh),
            pre_target_delta_net_discharge_mwh = sum(before.delta_net_discharge_mwh),
            morning_6_10_delta_discharge_mwh = sum(morning.delta_discharge_mwh),
            morning_6_10_delta_net_discharge_mwh = sum(morning.delta_net_discharge_mwh),
            midday_11_16_delta_charge_mwh = sum(midday.delta_charge_mwh),
            midday_11_16_delta_net_discharge_mwh = sum(midday.delta_net_discharge_mwh),
            evening_17_19_delta_net_discharge_mwh = sum(day_df[(17 .<= day_df.hour_of_day .<= 19), :delta_net_discharge_mwh]),
            target_fixed_hours_to_horizon_end = only(target.fixed_hours_to_horizon_end),
            target_rolling_hours_to_horizon_end = only(target.rolling_hours_to_horizon_end),
        ))
    end
    return DataFrame(rows)
end

function hourly_delta_summary(paired::DataFrame)
    return combine(groupby(paired, :hour_of_day),
        :delta_soc_before_mwh => median => :median_delta_soc_before_mwh,
        :delta_soc_end_mwh => median => :median_delta_soc_end_mwh,
        :delta_charge_mwh => median => :median_delta_charge_mwh,
        :delta_discharge_mwh => median => :median_delta_discharge_mwh,
        :delta_net_discharge_mwh => median => :median_delta_net_discharge_mwh,
        :delta_price_eur_per_mwh => median => :median_delta_price_eur_per_mwh,
        :delta_hours_to_horizon_end => median => :median_delta_hours_to_horizon_end,
        nrow => :n,
    )
end

function print_hour_summary(hourly::DataFrame)
    println("\nHourly median net discharge (MWh), fixed minus rolling:")
    for hour in 1:24
        f = hourly[(hourly.case_name .== "fixed") .& (hourly.hour_of_day .== hour), :]
        r = hourly[(hourly.case_name .== "rolling") .& (hourly.hour_of_day .== hour), :]
        if nrow(f) == 1 && nrow(r) == 1
            delta = only(f.median_net_discharge_mwh) - only(r.median_net_discharge_mwh)
            @printf("  hour %02d: fixed %8.1f | rolling %8.1f | delta %+8.1f\n",
                hour, only(f.median_net_discharge_mwh), only(r.median_net_discharge_mwh), delta)
        end
    end
end

function main(args=ARGS)
    run_dir = resolve_run_dir(args)
    output_dir = joinpath(run_dir, OUTPUT_DIRNAME)
    isdir(output_dir) || mkpath(output_dir)

    fixed_cfg = load_cfg(run_dir, "fixed_36h")
    simulation_start_hour = Int(fixed_cfg["rolling_horizon"]["simulation_start_hour"])

    fixed_all = load_case(run_dir, "fixed_36h")
    rolling_all = load_case(run_dir, "rolling_36h")
    fixed = case_hourly_records(fixed_all, "fixed", simulation_start_hour)
    rolling = case_hourly_records(rolling_all, "rolling", simulation_start_hour)
    fixed_clearings = case_clearing_records(fixed_all, "fixed", simulation_start_hour)
    rolling_clearings = case_clearing_records(rolling_all, "rolling", simulation_start_hour)
    all_hours = vcat(fixed, rolling)
    all_clearings = vcat(fixed_clearings, rolling_clearings)
    paired = pair_hourly(fixed, rolling)

    hourly = summarize_by_hour(all_hours)
    evening = summarize_evening_pair(fixed, rolling)
    daily_evening = daily_evening_records(fixed, rolling)
    deltas_by_hour = hourly_delta_summary(paired)
    prepeak = daily_prepeak_decomposition(paired; target_hour=17)
    clearing_hour_summary = combine(groupby(all_clearings, [:case_name, :clearing_start_hour_of_day]),
        :look_ahead => median => :median_look_ahead,
        :horizon_end_hour_of_day => median => :median_horizon_end_hour_of_day,
        :storage_soc_start_mwh => median => :median_soc_start_mwh,
        :storage_soc_end_window_mwh => median => :median_soc_end_window_mwh,
        :planned_evening_net_discharge_mwh => median => :median_planned_evening_net_discharge_mwh,
        :planned_net_discharge_window_mwh => median => :median_planned_window_net_discharge_mwh,
        nrow => :n,
    )

    CSV.write(joinpath(output_dir, "hourly_net_discharge_and_soc_summary.csv"), hourly)
    CSV.write(joinpath(output_dir, "evening_peak_summary.csv"), evening)
    CSV.write(joinpath(output_dir, "daily_evening_peak_fixed_vs_rolling.csv"), daily_evening)
    CSV.write(joinpath(output_dir, "executed_battery_hour_records.csv"), all_hours)
    CSV.write(joinpath(output_dir, "clearing_start_hour_terminal_soc_summary.csv"), clearing_hour_summary)
    CSV.write(joinpath(output_dir, "clearing_records.csv"), all_clearings)
    CSV.write(joinpath(output_dir, "paired_hourly_fixed_minus_rolling.csv"), paired)
    CSV.write(joinpath(output_dir, "hourly_fixed_minus_rolling_delta_summary.csv"), deltas_by_hour)
    CSV.write(joinpath(output_dir, "daily_pre_hour17_soc_decomposition.csv"), prepeak)

    println("Run directory: $run_dir")
    println("Output directory: $output_dir")
    println("Clock-hour mapping uses simulation_start_hour=$simulation_start_hour")
    print_hour_summary(hourly)

    println("\nEvening peak detail:")
    show(evening, allcols=true, allrows=true)
    println()

    println("\nDaily evening fixed-minus-rolling net discharge:")
    delta = daily_evening.fixed_minus_rolling_evening_net_discharge_mwh
    @printf("  days compared: %d\n", nrow(daily_evening))
    @printf("  mean delta:    %+8.1f MWh\n", mean(delta))
    @printf("  median delta:  %+8.1f MWh\n", median(delta))
    @printf("  positive days: %d / %d\n", count(>(0), delta), length(delta))
    @printf("  corr(delta evening discharge, fixed SOC before h17): %.3f\n",
        cor(delta, daily_evening.fixed_soc_before_hour17_mwh))
    @printf("  corr(delta evening discharge, fixed-minus-rolling SOC before h17): %.3f\n",
        cor(delta, daily_evening.fixed_minus_rolling_soc_before_hour17_mwh))

    println("\nTop fixed-over-rolling evening discharge days:")
    sorted = sort(daily_evening, :fixed_minus_rolling_evening_net_discharge_mwh, rev=true)
    show(first(sorted, min(10, nrow(sorted))), allcols=true, allrows=true)
    println()

    println("\nClearing-cycle terminal SOC summary:")
    fixed_cycle = clearing_hour_summary[clearing_hour_summary.case_name .== "fixed", :]
    show(sort(fixed_cycle, :clearing_start_hour_of_day), allcols=true, allrows=true)
    println()

    println("\nFixed-minus-rolling hourly deltas:")
    show(sort(deltas_by_hour, :hour_of_day), allcols=true, allrows=true)
    println()

    println("\nPre-hour-17 SOC decomposition:")
    show(describe(prepeak[:, Not(:day_index)]), allcols=true, allrows=true)
    println()
    @printf("  corr(delta SOC before h17, midday 11-16 delta charge): %.3f\n",
        cor(prepeak.delta_soc_before_target_mwh, prepeak.midday_11_16_delta_charge_mwh))
    @printf("  corr(delta SOC before h17, morning 6-10 delta discharge): %.3f\n",
        cor(prepeak.delta_soc_before_target_mwh, prepeak.morning_6_10_delta_discharge_mwh))
    @printf("  corr(delta SOC before h17, pre-h17 delta net discharge): %.3f\n",
        cor(prepeak.delta_soc_before_target_mwh, prepeak.pre_target_delta_net_discharge_mwh))
    @printf("  corr(evening delta discharge, delta SOC before h17): %.3f\n",
        cor(prepeak.evening_17_19_delta_net_discharge_mwh, prepeak.delta_soc_before_target_mwh))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

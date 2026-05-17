using CSV
using DataFrames
using Dates
using JuMP
using Printf
using Serialization
using Statistics

const RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260505_162324_seedA")
const OUTPUT_DIR = joinpath(RUN_DIR, "_morning_discharge_reason")

function load_case(case_slug::AbstractString)
    all_results = deserialize(joinpath(RUN_DIR, case_slug, "all_results.jls"))
    cfg = deserialize(joinpath(RUN_DIR, case_slug, "cfg.jls"))
    return all_results, cfg
end

simulation_start(cfg::Dict) = begin
    rh = cfg["rolling_horizon"]
    DateTime(2025, Int(rh["simulation_month"]), 1, Int(get(rh, "simulation_start_hour", 0)))
end

clock_hour(dt::DateTime) = Dates.hour(dt)

function executed_hour_records(all_results::Dict, cfg::Dict, case_name::AbstractString)
    sim_start = simulation_start(cfg)
    rows = NamedTuple[]
    details_dict = all_results[:clearing_details]
    dispatch_dict = all_results[:dispatch]

    for clearing_num in sort(collect(keys(details_dict)))
        details = details_dict[clearing_num]
        dispatch = dispatch_dict[clearing_num]
        current_hour = Int(details[:current_hour])
        executed_hours = Int(details[:executed_hours])
        look_ahead = Int(details[:look_ahead])
        soc_path = get(details, :storage_soc_path, Float64[])
        soc_start = Float64(details[:storage_soc_start])

        for h in 1:executed_hours
            global_hour = current_hour + h - 1
            ts = sim_start + Hour(global_hour - 1)
            charge = Float64(details[:charging][h])
            discharge = Float64(details[:discharging][h])
            demand = Float64(details[:demand_base][h] + details[:demand_flex][h])
            solar = haskey(dispatch, "Solar") ? Float64(dispatch["Solar"][h]) : 0.0
            wind = haskey(dispatch, "Wind") ? Float64(dispatch["Wind"][h]) : 0.0
            mid = haskey(dispatch, "Mid") ? Float64(dispatch["Mid"][h]) : 0.0
            peak = haskey(dispatch, "Peak") ? Float64(dispatch["Peak"][h]) : 0.0
            base = haskey(dispatch, "Base") ? Float64(dispatch["Base"][h]) : 0.0

            push!(rows, (
                case_name = String(case_name),
                global_hour = global_hour,
                timestamp = ts,
                calendar_date = Date(ts),
                clock_hour = clock_hour(ts),
                clearing_num = Int(clearing_num),
                current_hour = current_hour,
                look_ahead = look_ahead,
                horizon_end_timestamp = sim_start + Hour(current_hour + look_ahead - 2),
                horizon_end_clock_hour = clock_hour(sim_start + Hour(current_hour + look_ahead - 2)),
                hours_to_horizon_end = look_ahead - h,
                price = Float64(details[:prices][h]),
                demand = demand,
                solar = solar,
                wind = wind,
                base = base,
                mid = mid,
                peak = peak,
                mid_peak = mid + peak,
                residual_load_before_storage = demand - solar - wind,
                charge = charge,
                discharge = discharge,
                net_discharge = discharge - charge,
                soc_before = h == 1 ? soc_start : Float64(soc_path[h - 1]),
                soc_end = Float64(soc_path[h]),
            ))
        end
    end

    return DataFrame(rows)
end

function planned_clock_profile(all_results::Dict, cfg::Dict, case_name::AbstractString)
    sim_start = simulation_start(cfg)
    rows = NamedTuple[]
    details_dict = all_results[:clearing_details]

    for clearing_num in sort(collect(keys(details_dict)))
        details = details_dict[clearing_num]
        current_hour = Int(details[:current_hour])
        look_ahead = Int(details[:look_ahead])
        start_ts = sim_start + Hour(current_hour - 1)
        start_clock = clock_hour(start_ts)
        start_date = Date(start_ts)

        for h in 1:look_ahead
            ts = sim_start + Hour(current_hour + h - 2)
            push!(rows, (
                case_name = String(case_name),
                clearing_num = Int(clearing_num),
                clearing_start_timestamp = start_ts,
                clearing_start_date = start_date,
                clearing_start_clock_hour = start_clock,
                local_h = h,
                planned_timestamp = ts,
                planned_clock_hour = clock_hour(ts),
                planned_net_discharge = Float64(details[:discharging][h]) - Float64(details[:charging][h]),
                planned_charge = Float64(details[:charging][h]),
                planned_discharge = Float64(details[:discharging][h]),
                planned_price = Float64(details[:prices][h]),
                planned_soc_end = Float64(details[:storage_soc_path][h]),
            ))
        end
    end

    return DataFrame(rows)
end

function pair_executed(fixed::DataFrame, rolling::DataFrame)
    f = select(fixed,
        :global_hour, :timestamp, :calendar_date, :clock_hour,
        :net_discharge => :fixed_net_discharge,
        :charge => :fixed_charge,
        :discharge => :fixed_discharge,
        :soc_before => :fixed_soc_before,
        :soc_end => :fixed_soc_end,
        :price => :fixed_price,
        :demand => :fixed_demand,
        :solar => :fixed_solar,
        :wind => :fixed_wind,
        :mid_peak => :fixed_mid_peak,
        :residual_load_before_storage => :fixed_residual_load_before_storage,
        :hours_to_horizon_end => :fixed_hours_to_horizon_end,
        :horizon_end_clock_hour => :fixed_horizon_end_clock_hour,
    )
    r = select(rolling,
        :global_hour,
        :net_discharge => :rolling_net_discharge,
        :charge => :rolling_charge,
        :discharge => :rolling_discharge,
        :soc_before => :rolling_soc_before,
        :soc_end => :rolling_soc_end,
        :price => :rolling_price,
        :demand => :rolling_demand,
        :solar => :rolling_solar,
        :wind => :rolling_wind,
        :mid_peak => :rolling_mid_peak,
        :residual_load_before_storage => :rolling_residual_load_before_storage,
        :hours_to_horizon_end => :rolling_hours_to_horizon_end,
        :horizon_end_clock_hour => :rolling_horizon_end_clock_hour,
    )
    paired = innerjoin(f, r, on=:global_hour)
    for name in (:net_discharge, :charge, :discharge, :soc_before, :soc_end, :price,
                 :mid_peak, :residual_load_before_storage)
        paired[!, Symbol("delta_", name)] = paired[!, Symbol("fixed_", name)] .- paired[!, Symbol("rolling_", name)]
    end
    paired[!, :delta_hours_to_horizon_end] =
        paired.fixed_hours_to_horizon_end .- paired.rolling_hours_to_horizon_end
    return paired
end

function summarize_morning(paired::DataFrame)
    morning = paired[in.(paired.clock_hour, Ref(4:6)), :]
    by_hour = combine(groupby(morning, :clock_hour),
        :fixed_net_discharge => median => :fixed_median_net_discharge,
        :rolling_net_discharge => median => :rolling_median_net_discharge,
        :delta_net_discharge => median => :median_delta_net_discharge,
        :fixed_discharge => median => :fixed_median_discharge,
        :rolling_discharge => median => :rolling_median_discharge,
        :delta_discharge => median => :median_delta_discharge,
        :fixed_charge => median => :fixed_median_charge,
        :rolling_charge => median => :rolling_median_charge,
        :fixed_soc_before => median => :fixed_median_soc_before,
        :rolling_soc_before => median => :rolling_median_soc_before,
        :delta_soc_before => median => :median_delta_soc_before,
        :fixed_price => median => :fixed_median_price,
        :rolling_price => median => :rolling_median_price,
        :delta_price => median => :median_delta_price,
        :fixed_mid_peak => median => :fixed_median_mid_peak,
        :rolling_mid_peak => median => :rolling_median_mid_peak,
        :delta_mid_peak => median => :median_delta_mid_peak,
        :fixed_hours_to_horizon_end => median => :fixed_median_hours_to_end,
        :rolling_hours_to_horizon_end => median => :rolling_median_hours_to_end,
        nrow => :n,
    )
    return morning, by_hour
end

function previous_window_sum(paired::DataFrame, target_global_hour::Int, start_offset::Int, end_offset::Int, column::Symbol)
    first_hour = target_global_hour + start_offset
    last_hour = target_global_hour + end_offset
    rows = paired[(first_hour .<= paired.global_hour .<= last_hour), :]
    isempty(rows) && return 0.0
    return sum(rows[!, column])
end

function morning_carryover_decomposition(paired::DataFrame)
    targets = paired[in.(paired.clock_hour, Ref(4:6)), :]
    rows = NamedTuple[]
    for row in eachrow(targets)
        gh = Int(row.global_hour)
        push!(rows, (
            timestamp = row.timestamp,
            calendar_date = row.calendar_date,
            clock_hour = row.clock_hour,
            delta_net_discharge = row.delta_net_discharge,
            delta_soc_before = row.delta_soc_before,
            fixed_soc_before = row.fixed_soc_before,
            rolling_soc_before = row.rolling_soc_before,
            previous_12h_delta_net_discharge = previous_window_sum(paired, gh, -12, -1, :delta_net_discharge),
            previous_12h_delta_charge = previous_window_sum(paired, gh, -12, -1, :delta_charge),
            previous_12h_delta_discharge = previous_window_sum(paired, gh, -12, -1, :delta_discharge),
            previous_evening_17_23_delta_net_discharge = sum(
                r.delta_net_discharge for r in eachrow(paired)
                if Date(r.timestamp) == Date(row.timestamp) - Day(1) && 17 <= Int(r.clock_hour) <= 23
            ),
            previous_night_00_03_delta_net_discharge = sum(
                r.delta_net_discharge for r in eachrow(paired)
                if Date(r.timestamp) == Date(row.timestamp) && 0 <= Int(r.clock_hour) <= 3
            ),
        ))
    end
    return DataFrame(rows)
end

function summarize_plans(plans::DataFrame)
    morning_starts = plans[in.(plans.clearing_start_clock_hour, Ref(4:6)), :]
    profile = combine(groupby(morning_starts, [:case_name, :clearing_start_clock_hour, :local_h]),
        :planned_net_discharge => median => :median_planned_net_discharge,
        :planned_charge => median => :median_planned_charge,
        :planned_discharge => median => :median_planned_discharge,
        :planned_soc_end => median => :median_planned_soc_end,
        :planned_price => median => :median_planned_price,
        nrow => :n,
    )
    window_summary = combine(groupby(morning_starts, [:case_name, :clearing_start_clock_hour]),
        :planned_net_discharge => sum => :sum_planned_net_discharge_all_rows,
        :planned_charge => sum => :sum_planned_charge_all_rows,
        :planned_discharge => sum => :sum_planned_discharge_all_rows,
        :planned_soc_end => last => :last_planned_soc_end_seen,
        nrow => :row_count,
    )
    return profile, window_summary
end

function main()
    mkpath(OUTPUT_DIR)
    fixed_all, fixed_cfg = load_case("fixed_36h")
    rolling_all, rolling_cfg = load_case("rolling_36h")

    fixed = executed_hour_records(fixed_all, fixed_cfg, "fixed")
    rolling = executed_hour_records(rolling_all, rolling_cfg, "rolling")
    paired = pair_executed(fixed, rolling)
    morning, morning_by_hour = summarize_morning(paired)
    carryover = morning_carryover_decomposition(paired)

    plans = vcat(
        planned_clock_profile(fixed_all, fixed_cfg, "fixed"),
        planned_clock_profile(rolling_all, rolling_cfg, "rolling"),
    )
    plan_profile, plan_window_summary = summarize_plans(plans)

    CSV.write(joinpath(OUTPUT_DIR, "paired_executed_hourly.csv"), paired)
    CSV.write(joinpath(OUTPUT_DIR, "morning_04_06_paired_hours.csv"), morning)
    CSV.write(joinpath(OUTPUT_DIR, "morning_04_06_summary_by_hour.csv"), morning_by_hour)
    CSV.write(joinpath(OUTPUT_DIR, "morning_carryover_decomposition.csv"), carryover)
    CSV.write(joinpath(OUTPUT_DIR, "morning_start_planned_profile_by_local_hour.csv"), plan_profile)
    CSV.write(joinpath(OUTPUT_DIR, "morning_start_planned_window_summary.csv"), plan_window_summary)

    println("Morning 04-06 fixed vs rolling executed summary:")
    show(morning_by_hour, allcols=true, allrows=true)
    println("\n")

    delta = morning.delta_net_discharge
    @printf("Across clock 04-06 paired hours: mean delta net discharge = %.1f MWh, median = %.1f MWh\n",
        mean(delta), median(delta))
    @printf("corr(delta net discharge, delta SOC before) = %.3f\n",
        cor(morning.delta_net_discharge, morning.delta_soc_before))
    @printf("corr(delta net discharge, delta price) = %.3f\n",
        cor(morning.delta_net_discharge, morning.delta_price))
    @printf("corr(delta net discharge, delta mid+peak dispatch) = %.3f\n",
        cor(morning.delta_net_discharge, morning.delta_mid_peak))
    @printf("corr(delta net discharge, fixed SOC before) = %.3f\n",
        cor(morning.delta_net_discharge, morning.fixed_soc_before))

    println("\nCarry-over correlations:")
    @printf("corr(morning delta net discharge, delta SOC before) = %.3f\n",
        cor(carryover.delta_net_discharge, carryover.delta_soc_before))
    @printf("corr(delta SOC before, previous 12h delta net discharge) = %.3f\n",
        cor(carryover.delta_soc_before, carryover.previous_12h_delta_net_discharge))
    @printf("corr(delta SOC before, previous evening 17-23 delta net discharge) = %.3f\n",
        cor(carryover.delta_soc_before, carryover.previous_evening_17_23_delta_net_discharge))
    @printf("corr(delta SOC before, previous night 00-03 delta net discharge) = %.3f\n",
        cor(carryover.delta_soc_before, carryover.previous_night_00_03_delta_net_discharge))

    println("\nOutputs saved in: $OUTPUT_DIR")
end

main()

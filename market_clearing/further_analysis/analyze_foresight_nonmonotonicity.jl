using Serialization
using Statistics
using DataFrames
using CSV
using Printf
using JuMP

const DEFAULT_RUN_DIR = joinpath("Results", "thesis_runs", "foresight_20260509_145432")

case_dirs(run_dir::AbstractString) = Dict(
    "Rolling 36h" => joinpath(run_dir, "rolling_36h"),
    "Rolling 48h" => joinpath(run_dir, "rolling_48h"),
    "Rolling 72h" => joinpath(run_dir, "rolling_72h"),
)

function load_case(case_name::AbstractString, path::AbstractString)
    all_results = deserialize(joinpath(path, "all_results.jls"))
    cfg = deserialize(joinpath(path, "cfg.jls"))
    return (name=String(case_name), all_results=all_results, cfg=cfg)
end

function gen_prices(cfg::Dict)
    prices = Dict{String, Float64}()
    for (g, data) in cfg["dispatchableGenerators"]
        prices[String(g)] = float(data["bidPrice"])
    end
    for (g, data) in cfg["variableGenerators"]
        prices[String(g)] = float(data["bidPrice"])
    end
    return prices
end

function demand_prices(cfg::Dict)
    prices = Dict{String, Float64}()
    for (d, data) in cfg["demand"]["segments"]
        prices[String(d)] = float(data["bidPrice"])
    end
    return prices
end

function executed_hour_rows(case)
    prices = gen_prices(case.cfg)
    dprices = demand_prices(case.cfg)
    rows = NamedTuple[]
    details = case.all_results[:clearing_details]
    for c in sort(collect(keys(details)))
        d = details[c]
        for h in 1:d[:executed_hours]
            global_hour = d[:current_hour] + h - 1
            gen = Dict(g => d[:g_planned][g, h] for g in keys(prices))
            base_demand = d[:demand_base][h]
            flex_demand = d[:demand_flex][h]
            cost_by_gen = Dict(g => get(gen, g, 0.0) * prices[g] for g in keys(prices))
            thermal_cost = get(cost_by_gen, "Base", 0.0) + get(cost_by_gen, "Mid", 0.0) + get(cost_by_gen, "Peak", 0.0)
            demand_value = base_demand * dprices["Base"] + flex_demand * dprices["Flex"]
            push!(rows, (
                case_name=case.name,
                clearing=c,
                global_hour=global_hour,
                simulation_day=cld(global_hour, 24),
                hour_of_day=mod(global_hour - 1, 24) + 1,
                price=d[:prices][h],
                base=get(gen, "Base", 0.0),
                mid=get(gen, "Mid", 0.0),
                peak=get(gen, "Peak", 0.0),
                wind=get(gen, "Wind", 0.0),
                solar=get(gen, "Solar", 0.0),
                charge=d[:charging][h],
                discharge=d[:discharging][h],
                net_discharge=d[:discharging][h] - d[:charging][h],
                soc_end=d[:storage_soc_path][h],
                base_demand=base_demand,
                flex_demand=flex_demand,
                total_demand=base_demand + flex_demand,
                base_cost=get(cost_by_gen, "Base", 0.0),
                mid_cost=get(cost_by_gen, "Mid", 0.0),
                peak_cost=get(cost_by_gen, "Peak", 0.0),
                thermal_cost=thermal_cost,
                demand_value=demand_value,
                social_welfare=demand_value - sum(values(cost_by_gen)),
                h1_imbalance=get(d, :imbalance_h1, 0.0),
            ))
        end
    end
    return DataFrame(rows)
end

function clearing_rows(case)
    rows = NamedTuple[]
    details = case.all_results[:clearing_details]
    for c in sort(collect(keys(details)))
        d = details[c]
        look_ahead = d[:look_ahead]
        tail_start = max(1, look_ahead - 5)
        push!(rows, (
            case_name=case.name,
            clearing=c,
            current_hour=d[:current_hour],
            look_ahead=look_ahead,
            soc_start=d[:storage_soc_start],
            soc_end_executed=d[:storage_soc_end_executed],
            soc_end_window=d[:storage_soc_end_window],
            initial_soc_value=-d[:storage_initial_soc_dual],
            charge_last6=sum(d[:charging][tail_start:look_ahead]),
            discharge_last6=sum(d[:discharging][tail_start:look_ahead]),
            discharge_all=sum(d[:discharging]),
            charge_all=sum(d[:charging]),
            share_discharge_last6=sum(d[:discharging]) > 1e-9 ? sum(d[:discharging][tail_start:look_ahead]) / sum(d[:discharging]) : 0.0,
        ))
    end
    return DataFrame(rows)
end

function paired_hour_delta(df::DataFrame, left::AbstractString, right::AbstractString)
    l = filter(:case_name => ==(left), df)
    r = filter(:case_name => ==(right), df)
    joined = innerjoin(l, r, on=:global_hour, makeunique=true, renamecols="_left" => "_right")
    rows = NamedTuple[]
    for row in eachrow(joined)
        push!(rows, (
            comparison="$(right) - $(left)",
            global_hour=row.global_hour,
            simulation_day=row.simulation_day_left,
            hour_of_day=row.hour_of_day_left,
            delta_social_welfare=row.social_welfare_right - row.social_welfare_left,
            delta_demand_value=row.demand_value_right - row.demand_value_left,
            delta_thermal_cost=row.thermal_cost_right - row.thermal_cost_left,
            delta_base_cost=row.base_cost_right - row.base_cost_left,
            delta_mid_cost=row.mid_cost_right - row.mid_cost_left,
            delta_peak_cost=row.peak_cost_right - row.peak_cost_left,
            delta_mid_peak_cost=(row.mid_cost_right + row.peak_cost_right) - (row.mid_cost_left + row.peak_cost_left),
            delta_mid_peak_mwh=(row.mid_right + row.peak_right) - (row.mid_left + row.peak_left),
            delta_net_discharge=row.net_discharge_right - row.net_discharge_left,
            delta_flex_demand=row.flex_demand_right - row.flex_demand_left,
            left_price=row.price_left,
            right_price=row.price_right,
        ))
    end
    return DataFrame(rows)
end

function daily_from_hourly(dh::DataFrame)
    combine(groupby(dh, [:comparison, :simulation_day]),
        :delta_social_welfare => sum => :delta_social_welfare,
        :delta_demand_value => sum => :delta_demand_value,
        :delta_thermal_cost => sum => :delta_thermal_cost,
        :delta_mid_peak_cost => sum => :delta_mid_peak_cost,
        :delta_mid_peak_mwh => sum => :delta_mid_peak_mwh,
        :delta_net_discharge => sum => :delta_net_discharge,
        :delta_flex_demand => sum => :delta_flex_demand)
end

safe_cor(x, y) = length(x) > 1 && std(skipmissing(x)) > 0 && std(skipmissing(y)) > 0 ? cor(x, y) : NaN

function summarize_pair(daily::DataFrame, comparison::AbstractString)
    sub = filter(:comparison => ==(comparison), daily)
    return (
        comparison=comparison,
        days=nrow(sub),
        mean_delta_swf=mean(sub.delta_social_welfare),
        median_delta_swf=median(sub.delta_social_welfare),
        positive_days=sum(sub.delta_social_welfare .> 0),
        mean_delta_demand_value=mean(sub.delta_demand_value),
        mean_delta_thermal_cost=mean(sub.delta_thermal_cost),
        corr_swf_mid_peak_cost=safe_cor(sub.delta_social_welfare, sub.delta_mid_peak_cost),
        corr_swf_net_discharge=safe_cor(sub.delta_social_welfare, sub.delta_net_discharge),
        worst_day=sub[argmin(sub.delta_social_welfare), :simulation_day],
        worst_day_delta=minimum(sub.delta_social_welfare),
        best_day=sub[argmax(sub.delta_social_welfare), :simulation_day],
        best_day_delta=maximum(sub.delta_social_welfare),
    )
end

function terminal_summary(clearings::DataFrame)
    combine(groupby(clearings, :case_name),
        :soc_end_window => (x -> mean(abs.(x) .<= 1e-6)) => :share_window_ends_empty,
        :soc_end_window => mean => :mean_soc_end_window,
        :share_discharge_last6 => mean => :mean_share_discharge_last6,
        :initial_soc_value => mean => :mean_initial_soc_value,
        :soc_end_executed => last => :final_executed_soc)
end

function write_report(path::AbstractString, pair_summary::DataFrame, term::DataFrame, daily::DataFrame)
    function write_df(io, df::DataFrame)
        println(io, join(names(df), " | "))
        println(io, join(fill("---", ncol(df)), " | "))
        for row in eachrow(df)
            vals = [v isa AbstractFloat ? @sprintf("%.3f", v) : string(v) for v in row]
            println(io, join(vals, " | "))
        end
    end

    open(path, "w") do io
        println(io, "# Foresight non-monotonicity diagnostic")
        println(io)
        println(io, "## Tested hypotheses")
        println(io, "1. Longer look-ahead is not nested in realized operation because each delivery hour first enters the market earlier under noisier wind forecasts.")
        println(io, "2. Storage has no terminal value, so every rolling solve can drain the battery at the end of the visible window; the moving terminal condition changes near-term storage choices.")
        println(io, "3. Welfare deltas are dominated by thermal dispatch/storage substitution, not by demand-value gains.")
        println(io)
        println(io, "## Pair summary")
        write_df(io, pair_summary); println(io)
        println(io, "## Terminal/storage summary")
        write_df(io, term); println(io)
        println(io, "## Worst daily deltas")
        for comp in unique(daily.comparison)
            sub = sort(filter(:comparison => ==(comp), daily), :delta_social_welfare)
            println(io)
            println(io, "### $comp")
            write_df(io, first(sub, min(5, nrow(sub))))
        end
    end
end

function main(run_dir::AbstractString=DEFAULT_RUN_DIR)
    out_dir = joinpath(run_dir, "_nonmonotonicity_analysis")
    mkpath(out_dir)
    cases = [load_case(name, path) for (name, path) in sort(collect(case_dirs(run_dir)))]
    hourly = vcat([executed_hour_rows(c) for c in cases]...)
    clearings = vcat([clearing_rows(c) for c in cases]...)
    dh = vcat(
        paired_hour_delta(hourly, "Rolling 36h", "Rolling 48h"),
        paired_hour_delta(hourly, "Rolling 48h", "Rolling 72h"),
    )
    daily = daily_from_hourly(dh)
    pair_summary = DataFrame([summarize_pair(daily, c) for c in unique(daily.comparison)])
    term = terminal_summary(clearings)

    CSV.write(joinpath(out_dir, "executed_hourly_cases.csv"), hourly)
    CSV.write(joinpath(out_dir, "paired_hourly_deltas.csv"), dh)
    CSV.write(joinpath(out_dir, "paired_daily_deltas.csv"), daily)
    CSV.write(joinpath(out_dir, "pair_summary.csv"), pair_summary)
    CSV.write(joinpath(out_dir, "terminal_storage_summary.csv"), term)
    write_report(joinpath(out_dir, "foresight_nonmonotonicity_report.md"), pair_summary, term, daily)

    println("Wrote diagnostic outputs to: $out_dir")
    show(stdout, MIME("text/plain"), pair_summary)
    println()
    show(stdout, MIME("text/plain"), term)
    println()
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_dir = length(ARGS) >= 1 ? ARGS[1] : DEFAULT_RUN_DIR
    main(run_dir)
end

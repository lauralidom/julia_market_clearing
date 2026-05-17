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

safe_cor(x, y) = length(x) > 1 && std(skipmissing(x)) > 0 && std(skipmissing(y)) > 0 ? cor(x, y) : NaN

function load_case(case_name::AbstractString, path::AbstractString)
    all_results = deserialize(joinpath(path, "all_results.jls"))
    cfg = deserialize(joinpath(path, "cfg.jls"))
    return (name=String(case_name), all_results=all_results, cfg=cfg)
end

function load_forecast_errors(cfg::Dict)
    path = String(cfg["rolling_horizon"]["wind_noise_scenario_path"])
    df = CSV.read(path, DataFrame)
    by_key = Dict{Tuple{Int, Int}, NamedTuple}()
    for row in eachrow(df)
        by_key[(Int(row.window_start_hour), Int(row.abs_hour))] = (
            lead_time=Int(row.lead_time),
            std_dev=Float64(row.std_dev),
            forecast_error=Float64(row.forecast_error),
        )
    end
    return by_key
end

function dispatchable_names(cfg::Dict)
    return Set(String(g) for g in keys(cfg["dispatchableGenerators"]))
end

function trade_rows(case)
    rows = NamedTuple[]
    details = case.all_results[:clearing_details]
    for c in sort(collect(keys(details)))
        d = details[c]
        start = d[:current_hour]
        look_ahead = d[:look_ahead]
        for h in 1:look_ahead
            global_hour = start + h - 1
            price = d[:prices][h]
            for gen in keys(case.all_results[:dispatch][c])
                q = Float64(d[:q][gen, h])
                push!(rows, (
                    case_name=case.name,
                    clearing=c,
                    window_start_hour=start,
                    global_hour=global_hour,
                    lead_time=h,
                    generator=String(gen),
                    q=q,
                    abs_q=abs(q),
                    sell_qty=max(q, 0.0),
                    buyback_qty=max(-q, 0.0),
                    cashflow=q * price,
                    price=price,
                    is_delivery_hour=h <= d[:executed_hours],
                ))
            end
        end
    end
    return DataFrame(rows)
end

function executed_rows(case)
    rows = NamedTuple[]
    details = case.all_results[:clearing_details]
    disp = dispatchable_names(case.cfg)
    for c in sort(collect(keys(details)))
        d = details[c]
        start = d[:current_hour]
        for h in 1:d[:executed_hours]
            global_hour = start + h - 1
            gens = keys(case.all_results[:dispatch][c])
            for gen in gens
                g = String(gen)
                executed = Float64(d[:g_planned][g, h])
                push!(rows, (
                    case_name=case.name,
                    global_hour=global_hour,
                    generator=g,
                    executed_mwh=executed,
                    thermal_executed_mwh=g in disp ? executed : 0.0,
                    price=Float64(d[:prices][h]),
                ))
            end
        end
    end
    return DataFrame(rows)
end

function gen_price_map(cfg::Dict)
    prices = Dict{String, Float64}()
    for (g, data) in cfg["dispatchableGenerators"]
        prices[String(g)] = float(data["bidPrice"])
    end
    for (g, data) in cfg["variableGenerators"]
        prices[String(g)] = float(data["bidPrice"])
    end
    return prices
end

function demand_price_map(cfg::Dict)
    prices = Dict{String, Float64}()
    for (d, data) in cfg["demand"]["segments"]
        prices[String(d)] = float(data["bidPrice"])
    end
    return prices
end

function daily_welfare_storage_rows(case)
    gprices = gen_price_map(case.cfg)
    dprices = demand_price_map(case.cfg)
    rows = NamedTuple[]
    details = case.all_results[:clearing_details]
    for c in sort(collect(keys(details)))
        d = details[c]
        for h in 1:d[:executed_hours]
            global_hour = d[:current_hour] + h - 1
            demand_value = d[:demand_base][h] * dprices["Base"] + d[:demand_flex][h] * dprices["Flex"]
            generation_cost = sum(Float64(d[:g_planned][g, h]) * gprices[g] for g in keys(gprices))
            storage_financial_revenue = (d[:discharging][h] - d[:charging][h]) * d[:prices][h]
            push!(rows, (
                case_name=case.name,
                simulation_day=cld(global_hour, 24),
                global_hour=global_hour,
                social_welfare=demand_value - generation_cost,
                demand_value=demand_value,
                generation_cost=generation_cost,
                storage_financial_revenue=storage_financial_revenue,
            ))
        end
    end
    return combine(groupby(DataFrame(rows), [:case_name, :simulation_day]),
        :social_welfare => sum => :daily_social_welfare,
        :demand_value => sum => :daily_demand_value,
        :generation_cost => sum => :daily_generation_cost,
        :storage_financial_revenue => sum => :storage_financial_revenue)
end

function first_commitment_rows(case, forecast_by_key)
    rows = NamedTuple[]
    details = case.all_results[:clearing_details]
    look_ahead = Int(case.cfg["rolling_horizon"]["look_ahead_window"])
    executed_hours = sort(unique([d[:current_hour] for (_, d) in details if d[:executed_hours] >= 1]))
    for global_hour in executed_hours
        first_start = max(1, global_hour - look_ahead + 1)
        if !haskey(details, first_start)
            first_start = minimum(collect(keys(details)))
        end
        d_first = details[first_start]
        lead = global_hour - d_first[:current_hour] + 1
        if lead < 1 || lead > d_first[:look_ahead]
            continue
        end
        d_exec = details[global_hour]
        ferr = get(forecast_by_key, (d_first[:current_hour], global_hour), (lead_time=lead, std_dev=NaN, forecast_error=NaN))
        initial_wind = Float64(d_first[:g_planned]["Wind", lead])
        final_wind = Float64(d_exec[:g_planned]["Wind", 1])
        initial_peak = Float64(d_first[:g_planned]["Peak", lead])
        final_peak = Float64(d_exec[:g_planned]["Peak", 1])
        push!(rows, (
            case_name=case.name,
            global_hour=global_hour,
            simulation_day=cld(global_hour, 24),
            first_window_start=d_first[:current_hour],
            first_lead_time=lead,
            first_forecast_std=ferr.std_dev,
            first_forecast_error=ferr.forecast_error,
            abs_first_forecast_error=abs(ferr.forecast_error),
            initial_wind_position=initial_wind,
            final_wind_delivery=final_wind,
            wind_position_error=initial_wind - final_wind,
            abs_wind_position_error=abs(initial_wind - final_wind),
            initial_peak_position=initial_peak,
            final_peak_delivery=final_peak,
            peak_correction=final_peak - initial_peak,
            abs_peak_correction=abs(final_peak - initial_peak),
        ))
    end
    return DataFrame(rows)
end

function delivery_churn_summary(trades::DataFrame, executed::DataFrame)
    trade_summary = combine(groupby(trades, [:case_name, :generator, :global_hour]),
        :q => sum => :net_traded_mwh,
        :abs_q => sum => :gross_traded_mwh,
        :sell_qty => sum => :sold_mwh,
        :buyback_qty => sum => :bought_back_mwh,
        :cashflow => sum => :net_cashflow_eur,
        [:q, :price] => ((q, p) -> sum(max.(-q, 0.0) .* p)) => :buyback_cash_eur,
        :lead_time => maximum => :max_lead_seen)
    joined = innerjoin(trade_summary, executed, on=[:case_name, :generator, :global_hour])
    joined.churn_mwh = joined.gross_traded_mwh .- abs.(joined.net_traded_mwh)
    joined.gross_to_executed_ratio = [r.executed_mwh > 1e-9 ? r.gross_traded_mwh / r.executed_mwh : NaN for r in eachrow(joined)]
    joined.buyback_share_of_gross = [r.gross_traded_mwh > 1e-9 ? r.bought_back_mwh / r.gross_traded_mwh : 0.0 for r in eachrow(joined)]
    joined.adjustment_loss_eur = joined.net_traded_mwh .* joined.price .- joined.net_cashflow_eur
    return joined
end

function case_churn_summary(delivery::DataFrame)
    combine(groupby(delivery, :case_name),
        :gross_traded_mwh => sum => :gross_traded_mwh,
        :churn_mwh => sum => :churn_mwh,
        :sold_mwh => sum => :sold_mwh,
        :bought_back_mwh => sum => :bought_back_mwh,
        :executed_mwh => sum => :executed_mwh,
        :thermal_executed_mwh => sum => :thermal_executed_mwh,
        [:gross_traded_mwh, :executed_mwh] => ((g, e) -> sum(g) / sum(e)) => :gross_to_executed_ratio,
        [:churn_mwh, :executed_mwh] => ((c, e) -> sum(c) / sum(e)) => :churn_to_executed_ratio,
        [:bought_back_mwh, :gross_traded_mwh] => ((b, g) -> sum(b) / sum(g)) => :buyback_share_of_gross)
end

function generator_churn_summary(delivery::DataFrame)
    combine(groupby(delivery, [:case_name, :generator]),
        :gross_traded_mwh => sum => :gross_traded_mwh,
        :executed_mwh => sum => :net_delivered_mwh,
        :churn_mwh => sum => :churn_mwh,
        :bought_back_mwh => sum => :bought_back_mwh,
        :buyback_cash_eur => sum => :buyback_cash_eur,
        :adjustment_loss_eur => sum => :adjustment_loss_eur,
        :executed_mwh => sum => :executed_mwh,
        [:gross_traded_mwh, :executed_mwh] => ((g, e) -> sum(e) > 1e-9 ? sum(g) / sum(e) : NaN) => :gross_to_executed_ratio,
        [:bought_back_mwh, :gross_traded_mwh] => ((b, g) -> sum(g) > 1e-9 ? sum(b) / sum(g) : 0.0) => :buyback_share_of_gross)
end

function forecast_correction_summary(firsts::DataFrame, delivery::DataFrame)
    wind_delivery = filter(:generator => ==("Wind"), delivery)
    wind_cols = select(wind_delivery, [:case_name, :global_hour, :gross_traded_mwh, :churn_mwh, :bought_back_mwh])
    rename!(wind_cols, Dict(
        :gross_traded_mwh => :wind_gross_traded_mwh,
        :churn_mwh => :wind_churn_mwh,
        :bought_back_mwh => :wind_bought_back_mwh,
    ))
    joined = leftjoin(firsts, wind_cols, on=[:case_name, :global_hour])
    return combine(groupby(joined, :case_name),
        :first_lead_time => mean => :mean_first_lead_time,
        :first_forecast_std => mean => :mean_first_forecast_std,
        :abs_first_forecast_error => mean => :mean_abs_first_forecast_error,
        :abs_wind_position_error => mean => :mean_abs_initial_wind_position_error,
        :wind_churn_mwh => mean => :mean_wind_churn_per_delivery_hour,
        :wind_bought_back_mwh => mean => :mean_wind_buyback_per_delivery_hour,
        [:abs_first_forecast_error, :abs_wind_position_error] => ((x, y) -> safe_cor(x, y)) => :corr_forecast_error_initial_wind_error,
        [:abs_first_forecast_error, :wind_churn_mwh] => ((x, y) -> safe_cor(x, y)) => :corr_forecast_error_wind_churn,
        [:abs_first_forecast_error, :wind_bought_back_mwh] => ((x, y) -> safe_cor(x, y)) => :corr_forecast_error_wind_buyback)
end

function daily_case_churn(delivery::DataFrame)
    delivery.simulation_day = cld.(delivery.global_hour, 24)
    combine(groupby(delivery, [:case_name, :simulation_day]),
        :gross_traded_mwh => sum => :gross_traded_mwh,
        :churn_mwh => sum => :churn_mwh,
        :bought_back_mwh => sum => :bought_back_mwh,
        :buyback_cash_eur => sum => :buyback_cash_eur,
        :adjustment_loss_eur => sum => :adjustment_loss_eur,
        :executed_mwh => sum => :executed_mwh,
        [:gross_traded_mwh, :executed_mwh] => ((g, e) -> sum(g) / sum(e)) => :gross_to_executed_ratio,
        [:churn_mwh, :executed_mwh] => ((c, e) -> sum(c) / sum(e)) => :churn_to_executed_ratio)
end

function daily_generator_churn(delivery::DataFrame)
    delivery.simulation_day = cld.(delivery.global_hour, 24)
    combine(groupby(delivery, [:case_name, :simulation_day, :generator]),
        :gross_traded_mwh => sum => :gross_traded_mwh,
        :executed_mwh => sum => :net_delivered_mwh,
        :bought_back_mwh => sum => :buyback_volume_mwh,
        :adjustment_loss_eur => sum => :adjustment_loss_eur,
        [:gross_traded_mwh, :executed_mwh] => ((g, e) -> sum(e) > 1e-9 ? sum(g) / sum(e) : NaN) => :gross_traded_to_net_delivered_ratio)
end

function daily_wind_buyback(delivery::DataFrame)
    wind = filter(:generator => ==("Wind"), delivery)
    wind.simulation_day = cld.(wind.global_hour, 24)
    combine(groupby(wind, [:case_name, :simulation_day]),
        :bought_back_mwh => sum => :wind_buyback_volume_mwh,
        :adjustment_loss_eur => sum => :wind_adjustment_loss_eur)
end

function daily_market_hypothesis_metrics(delivery::DataFrame, daily_welfare_storage::DataFrame)
    daily_churn = daily_case_churn(delivery)
    wind = daily_wind_buyback(delivery)
    joined = leftjoin(daily_churn, daily_welfare_storage, on=[:case_name, :simulation_day])
    joined = leftjoin(joined, wind, on=[:case_name, :simulation_day])
    joined.wind_buyback_volume_mwh = coalesce.(joined.wind_buyback_volume_mwh, 0.0)
    joined.wind_adjustment_loss_eur = coalesce.(joined.wind_adjustment_loss_eur, 0.0)
    return joined
end

function market_metric_welfare_correlations(daily_metrics::DataFrame)
    metric_cols = [
        :gross_traded_mwh,
        :churn_mwh,
        :bought_back_mwh,
        :buyback_cash_eur,
        :adjustment_loss_eur,
        :gross_to_executed_ratio,
        :wind_buyback_volume_mwh,
        :wind_adjustment_loss_eur,
        :storage_financial_revenue,
    ]
    rows = NamedTuple[]
    for case_name in unique(daily_metrics.case_name)
        sub = filter(:case_name => ==(case_name), daily_metrics)
        for metric in metric_cols
            push!(rows, (
                case_name=case_name,
                metric=String(metric),
                correlation_with_daily_swf=safe_cor(sub[!, metric], sub.daily_social_welfare),
                mean_value=mean(sub[!, metric]),
            ))
        end
    end
    return DataFrame(rows)
end

function pair_daily_churn_deltas(daily::DataFrame)
    pairs = [("Rolling 36h", "Rolling 48h"), ("Rolling 48h", "Rolling 72h")]
    rows = NamedTuple[]
    for (left, right) in pairs
        l = filter(:case_name => ==(left), daily)
        r = filter(:case_name => ==(right), daily)
        joined = innerjoin(l, r, on=:simulation_day, makeunique=true, renamecols="_left" => "_right")
        for row in eachrow(joined)
            push!(rows, (
                comparison="$(right) - $(left)",
                simulation_day=row.simulation_day,
                delta_gross_traded_mwh=row.gross_traded_mwh_right - row.gross_traded_mwh_left,
                delta_churn_mwh=row.churn_mwh_right - row.churn_mwh_left,
                delta_buyback_mwh=row.bought_back_mwh_right - row.bought_back_mwh_left,
                delta_buyback_cash_eur=row.buyback_cash_eur_right - row.buyback_cash_eur_left,
                delta_adjustment_loss_eur=row.adjustment_loss_eur_right - row.adjustment_loss_eur_left,
                delta_gross_to_executed_ratio=row.gross_to_executed_ratio_right - row.gross_to_executed_ratio_left,
                delta_churn_to_executed_ratio=row.churn_to_executed_ratio_right - row.churn_to_executed_ratio_left,
                delta_wind_buyback_volume_mwh=row.wind_buyback_volume_mwh_right - row.wind_buyback_volume_mwh_left,
                delta_wind_adjustment_loss_eur=row.wind_adjustment_loss_eur_right - row.wind_adjustment_loss_eur_left,
                delta_storage_financial_revenue=row.storage_financial_revenue_right - row.storage_financial_revenue_left,
            ))
        end
    end
    return DataFrame(rows)
end

function pair_churn_welfare_summary(pair_churn::DataFrame, run_dir::AbstractString)
    welfare_path = joinpath(run_dir, "_nonmonotonicity_analysis", "paired_daily_deltas.csv")
    if !isfile(welfare_path)
        return DataFrame()
    end
    welfare = CSV.read(welfare_path, DataFrame)
    joined = innerjoin(pair_churn, welfare, on=[:comparison, :simulation_day])
    return combine(groupby(joined, :comparison),
        :delta_churn_mwh => mean => :mean_delta_churn_mwh,
        :delta_gross_traded_mwh => mean => :mean_delta_gross_traded_mwh,
        :delta_buyback_mwh => mean => :mean_delta_buyback_mwh,
        :delta_adjustment_loss_eur => mean => :mean_delta_adjustment_loss_eur,
        :delta_wind_buyback_volume_mwh => mean => :mean_delta_wind_buyback_mwh,
        :delta_storage_financial_revenue => mean => :mean_delta_storage_financial_revenue,
        [:delta_churn_mwh, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_churn_vs_delta_welfare,
        [:delta_gross_traded_mwh, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_gross_vs_delta_welfare,
        [:delta_buyback_mwh, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_buyback_vs_delta_welfare,
        [:delta_adjustment_loss_eur, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_adjustment_loss_vs_delta_welfare,
        [:delta_wind_buyback_volume_mwh, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_wind_buyback_vs_delta_welfare,
        [:delta_storage_financial_revenue, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_storage_revenue_vs_delta_welfare)
end

function daily_forecast_exposure_rows(cases, forecast_by_key)
    rows = NamedTuple[]
    for case in cases
        details = case.all_results[:clearing_details]
        for c in sort(collect(keys(details)))
            d = details[c]
            start = d[:current_hour]
            day = cld(start, 24)
            vals_37_48 = Float64[]
            vals_49_72 = Float64[]
            for h in 37:min(48, d[:look_ahead])
                rec = get(forecast_by_key, (start, start + h - 1), nothing)
                rec !== nothing && push!(vals_37_48, abs(rec.forecast_error))
            end
            for h in 49:min(72, d[:look_ahead])
                rec = get(forecast_by_key, (start, start + h - 1), nothing)
                rec !== nothing && push!(vals_49_72, abs(rec.forecast_error))
            end
            push!(rows, (
                case_name=case.name,
                simulation_day=day,
                abs_forecast_error_37_48=isempty(vals_37_48) ? missing : mean(vals_37_48),
                abs_forecast_error_49_72=isempty(vals_49_72) ? missing : mean(vals_49_72),
            ))
        end
    end
    raw = DataFrame(rows)
    return combine(groupby(raw, [:case_name, :simulation_day]),
        :abs_forecast_error_37_48 => (x -> all(ismissing, x) ? missing : mean(skipmissing(x))) => :avg_abs_forecast_error_37_48,
        :abs_forecast_error_49_72 => (x -> all(ismissing, x) ? missing : mean(skipmissing(x))) => :avg_abs_forecast_error_49_72)
end

function daily_forecast_revision_rows(firsts::DataFrame)
    combine(groupby(firsts, [:case_name, :simulation_day]),
        :abs_first_forecast_error => mean => :avg_abs_first_seen_to_delivery_forecast_revision,
        :abs_wind_position_error => mean => :avg_abs_first_seen_to_delivery_wind_position_error)
end

function pair_daily_forecast_delta_rows(daily_welfare_storage::DataFrame, exposure::DataFrame, revisions::DataFrame)
    daily = leftjoin(daily_welfare_storage, exposure, on=[:case_name, :simulation_day])
    daily = leftjoin(daily, revisions, on=[:case_name, :simulation_day])
    pairs = [("Rolling 36h", "Rolling 48h"), ("Rolling 48h", "Rolling 72h"), ("Rolling 36h", "Rolling 72h")]
    rows = NamedTuple[]
    for (left, right) in pairs
        l = filter(:case_name => ==(left), daily)
        r = filter(:case_name => ==(right), daily)
        joined = innerjoin(l, r, on=:simulation_day, makeunique=true, renamecols="_left" => "_right")
        for row in eachrow(joined)
            push!(rows, (
                comparison="$(right) - $(left)",
                simulation_day=row.simulation_day,
                delta_social_welfare=row.daily_social_welfare_right - row.daily_social_welfare_left,
                right_avg_abs_forecast_error_37_48=row.avg_abs_forecast_error_37_48_right,
                right_avg_abs_forecast_error_49_72=row.avg_abs_forecast_error_49_72_right,
                right_avg_abs_first_seen_to_delivery_forecast_revision=row.avg_abs_first_seen_to_delivery_forecast_revision_right,
                delta_avg_abs_first_seen_to_delivery_forecast_revision=row.avg_abs_first_seen_to_delivery_forecast_revision_right - row.avg_abs_first_seen_to_delivery_forecast_revision_left,
                right_avg_abs_first_seen_to_delivery_wind_position_error=row.avg_abs_first_seen_to_delivery_wind_position_error_right,
                delta_avg_abs_first_seen_to_delivery_wind_position_error=row.avg_abs_first_seen_to_delivery_wind_position_error_right - row.avg_abs_first_seen_to_delivery_wind_position_error_left,
            ))
        end
    end
    return DataFrame(rows)
end

function forecast_delta_welfare_summary(pair_forecast::DataFrame)
    combine(groupby(pair_forecast, :comparison),
        [:right_avg_abs_forecast_error_37_48, :delta_social_welfare] => ((x, y) -> safe_cor(collect(skipmissing(x)), y[.!ismissing.(x)])) => :corr_delta_swf_vs_error_37_48,
        [:right_avg_abs_forecast_error_49_72, :delta_social_welfare] => ((x, y) -> safe_cor(collect(skipmissing(x)), y[.!ismissing.(x)])) => :corr_delta_swf_vs_error_49_72,
        [:right_avg_abs_first_seen_to_delivery_forecast_revision, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_swf_vs_abs_forecast_revision,
        [:delta_avg_abs_first_seen_to_delivery_forecast_revision, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_swf_vs_delta_abs_forecast_revision,
        [:right_avg_abs_first_seen_to_delivery_wind_position_error, :delta_social_welfare] => ((x, y) -> safe_cor(x, y)) => :corr_delta_swf_vs_wind_position_error)
end

function write_df(io, df::DataFrame)
    println(io, join(names(df), " | "))
    println(io, join(fill("---", ncol(df)), " | "))
    for row in eachrow(df)
        vals = [v isa AbstractFloat ? @sprintf("%.4f", v) : string(v) for v in row]
        println(io, join(vals, " | "))
    end
end

function write_report(path::AbstractString,
                      case_churn::DataFrame,
                      gen_churn::DataFrame,
                      forecast_summary::DataFrame,
                      market_corr::DataFrame,
                      pair_welfare::DataFrame,
                      forecast_delta_summary::DataFrame)
    open(path, "w") do io
        println(io, "# Foresight churn and forecast-error hypotheses")
        println(io)
        println(io, "## Hypothesis 1: longer look-ahead increases gross trading and churn")
        println(io, "Churn is measured per generator and delivery hour as `sum(abs(q)) - abs(sum(q))`; this removes the final net position and focuses on offsetting re-trades.")
        println(io, "`adjustment_loss_eur` is `net_traded_mwh * delivery_price - sum(q * trade_price)`, so positive values mean the re-trading path performed worse than valuing the final net delivered position at the delivery-hour price.")
        println(io)
        write_df(io, case_churn)
        println(io)
        println(io, "## Generator-level churn")
        write_df(io, sort(gen_churn, [:generator, :case_name]))
        println(io)
        println(io, "## Hypothesis 2: longer look-ahead enters positions under larger forecast errors")
        println(io, "First forecast error is measured when each delivered hour first appears in the case horizon. Correction metrics compare that first wind position with final delivery and later wind re-trading.")
        println(io)
        write_df(io, forecast_summary)
        println(io)
        println(io, "## Daily market metrics versus daily welfare")
        write_df(io, market_corr)
        if nrow(pair_welfare) > 0
            println(io)
            println(io, "## Daily churn deltas versus daily welfare deltas")
            write_df(io, pair_welfare)
        end
        println(io)
        println(io, "## Daily forecast-error exposure versus daily welfare deltas")
        write_df(io, forecast_delta_summary)
    end
end

function main(run_dir::AbstractString=DEFAULT_RUN_DIR)
    out_dir = joinpath(run_dir, "_churn_forecast_analysis")
    mkpath(out_dir)
    cases = [load_case(name, path) for (name, path) in sort(collect(case_dirs(run_dir)))]
    forecast_by_key = load_forecast_errors(cases[1].cfg)

    trades = vcat([trade_rows(c) for c in cases]...)
    executed = vcat([executed_rows(c) for c in cases]...)
    daily_welfare_storage = vcat([daily_welfare_storage_rows(c) for c in cases]...)
    firsts = vcat([first_commitment_rows(c, forecast_by_key) for c in cases]...)
    delivery = delivery_churn_summary(trades, executed)

    case_churn = case_churn_summary(delivery)
    gen_churn = generator_churn_summary(delivery)
    forecast_summary = forecast_correction_summary(firsts, delivery)
    daily_market = daily_market_hypothesis_metrics(delivery, daily_welfare_storage)
    market_corr = market_metric_welfare_correlations(daily_market)
    pair_churn = pair_daily_churn_deltas(daily_market)
    pair_welfare = pair_churn_welfare_summary(pair_churn, run_dir)
    forecast_exposure = daily_forecast_exposure_rows(cases, forecast_by_key)
    forecast_revisions = daily_forecast_revision_rows(firsts)
    pair_forecast = pair_daily_forecast_delta_rows(daily_welfare_storage, forecast_exposure, forecast_revisions)
    forecast_delta_summary = forecast_delta_welfare_summary(pair_forecast)

    CSV.write(joinpath(out_dir, "trade_rows.csv"), trades)
    CSV.write(joinpath(out_dir, "delivery_hour_churn.csv"), delivery)
    CSV.write(joinpath(out_dir, "case_churn_summary.csv"), case_churn)
    CSV.write(joinpath(out_dir, "generator_churn_summary.csv"), gen_churn)
    CSV.write(joinpath(out_dir, "daily_generator_churn.csv"), daily_generator_churn(delivery))
    CSV.write(joinpath(out_dir, "first_commitment_forecast_errors.csv"), firsts)
    CSV.write(joinpath(out_dir, "forecast_correction_summary.csv"), forecast_summary)
    CSV.write(joinpath(out_dir, "daily_market_hypothesis_metrics.csv"), daily_market)
    CSV.write(joinpath(out_dir, "market_metric_welfare_correlations.csv"), market_corr)
    CSV.write(joinpath(out_dir, "pair_daily_churn_deltas.csv"), pair_churn)
    nrow(pair_welfare) > 0 && CSV.write(joinpath(out_dir, "pair_churn_welfare_summary.csv"), pair_welfare)
    CSV.write(joinpath(out_dir, "daily_forecast_error_exposure.csv"), forecast_exposure)
    CSV.write(joinpath(out_dir, "daily_forecast_revisions.csv"), forecast_revisions)
    CSV.write(joinpath(out_dir, "pair_daily_forecast_delta_rows.csv"), pair_forecast)
    CSV.write(joinpath(out_dir, "forecast_delta_welfare_summary.csv"), forecast_delta_summary)
    write_report(
        joinpath(out_dir, "churn_forecast_hypothesis_report.md"),
        case_churn,
        gen_churn,
        forecast_summary,
        market_corr,
        pair_welfare,
        forecast_delta_summary,
    )

    println("Wrote churn/forecast diagnostics to: $out_dir")
    show(stdout, MIME("text/plain"), case_churn); println()
    show(stdout, MIME("text/plain"), forecast_summary); println()
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_dir = length(ARGS) >= 1 ? ARGS[1] : DEFAULT_RUN_DIR
    main(run_dir)
end

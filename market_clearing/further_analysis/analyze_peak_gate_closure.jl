using Serialization
using JuMP
using HiGHS
using Printf

const RUN_DIR = get(ARGS, 1, joinpath("Results", "thesis_runs", "all_20260512_101146"))
const CASES = Dict(
    "Fixed 36h" => joinpath(RUN_DIR, "fixed_36h", "all_results.jls"),
    "Rolling 36h" => joinpath(RUN_DIR, "rolling_36h", "all_results.jls"),
)

function value_at(a, g::String, h::Int)
    return float(a[g, h])
end

function summarize_case(case_name::String, path::String)
    r = deserialize(path)
    rows = []
    totals = Dict(
        :executed_hours => 0.0,
        :peak_executed => 0.0,
        :peak_q_h1_pos => 0.0,
        :peak_q_h1_neg => 0.0,
        :peak_q_h1_net => 0.0,
        :peak_q_all_gross => 0.0,
        :peak_q_future_gross => 0.0,
        :wind_q_h1_net => 0.0,
        :wind_q_h1_pos => 0.0,
        :wind_q_h1_neg => 0.0,
        :base_mid_solar_q_h1_abs => 0.0,
        :base_mid_solar_q_h1_abs_after_first => 0.0,
        :locked_commitment_peak_h1 => 0.0,
        :locked_commitment_nonflex_h1 => 0.0,
        :demand_h1 => 0.0,
        :storage_net_h1 => 0.0,
        :imbalance_abs => 0.0,
        :scarcity_peak_hours => 0.0,
    )

    for clearing in sort(collect(keys(r[:clearing_details])))
        d = r[:clearing_details][clearing]
        q = d[:q]
        g = d[:g_planned]
        q_prev = d[:Q_prev]
        executed_hours = Int(d[:executed_hours])
        prices = d[:prices]

        h1_peak_q = value_at(q, "Peak", 1)
        h1_wind_q = value_at(q, "Wind", 1)
        h1_peak = value_at(g, "Peak", 1)
        h1_wind = value_at(g, "Wind", 1)
        h1_q_nonflex_abs = sum(abs(value_at(q, gen, 1)) for gen in ("Base", "Mid", "Solar"))
        h1_nonflex_prev = sum(q_prev[(gen, 1)] for gen in ("Base", "Mid", "Solar"))
        h1_demand = sum(float(d[:demand_base][1]) + float(d[:demand_flex][1]))
        h1_storage_net = float(d[:discharging][1]) - float(d[:charging][1])
        imbalance = get(d, :imbalance_h1, 0.0)

        totals[:peak_q_h1_pos] += max(h1_peak_q, 0.0)
        totals[:peak_q_h1_neg] += max(-h1_peak_q, 0.0)
        totals[:peak_q_h1_net] += h1_peak_q
        totals[:wind_q_h1_pos] += max(h1_wind_q, 0.0)
        totals[:wind_q_h1_neg] += max(-h1_wind_q, 0.0)
        totals[:wind_q_h1_net] += h1_wind_q
        totals[:base_mid_solar_q_h1_abs] += h1_q_nonflex_abs
        if clearing > 1
            totals[:base_mid_solar_q_h1_abs_after_first] += h1_q_nonflex_abs
        end
        totals[:locked_commitment_peak_h1] += q_prev[("Peak", 1)]
        totals[:locked_commitment_nonflex_h1] += h1_nonflex_prev
        totals[:demand_h1] += h1_demand
        totals[:storage_net_h1] += h1_storage_net
        totals[:imbalance_abs] += abs(imbalance)
        totals[:scarcity_peak_hours] += prices[1] >= 149.999 ? 1.0 : 0.0

        for h in 1:length(prices)
            q_peak = value_at(q, "Peak", h)
            totals[:peak_q_all_gross] += abs(q_peak)
            if h > 1
                totals[:peak_q_future_gross] += abs(q_peak)
            end
        end

        for h in 1:executed_hours
            totals[:executed_hours] += 1.0
            totals[:peak_executed] += value_at(g, "Peak", h)
        end

        push!(rows, (
            clearing=clearing,
            global_hour=Int(d[:current_hour]),
            peak_executed=h1_peak,
            peak_q=h1_peak_q,
            peak_prev=q_prev[("Peak", 1)],
            wind_executed=h1_wind,
            wind_q=h1_wind_q,
            wind_prev=q_prev[("Wind", 1)],
            nonflex_prev=h1_nonflex_prev,
            storage_net=h1_storage_net,
            demand=h1_demand,
            price=prices[1],
            imbalance=imbalance,
        ))
    end
    return totals, rows
end

summaries = Dict()
hourly = Dict()

for (case_name, path) in sort(collect(CASES))
    totals, rows = summarize_case(case_name, path)
    summaries[case_name] = totals
    hourly[case_name] = rows
end

println("Peak/gate-closure decomposition for baseline 36h cases")
println("All energy values are MWh over the executed sample unless labelled gross.")
println()
@printf("%-28s %14s %14s %14s\n", "Metric", "Fixed 36h", "Rolling 36h", "Fixed-Roll")
for key in (
    :executed_hours,
    :peak_executed,
    :locked_commitment_peak_h1,
    :peak_q_h1_net,
    :peak_q_h1_pos,
    :peak_q_h1_neg,
    :peak_q_all_gross,
    :peak_q_future_gross,
    :wind_q_h1_net,
    :wind_q_h1_pos,
    :wind_q_h1_neg,
    :base_mid_solar_q_h1_abs,
    :base_mid_solar_q_h1_abs_after_first,
    :locked_commitment_nonflex_h1,
    :demand_h1,
    :storage_net_h1,
    :imbalance_abs,
    :scarcity_peak_hours,
)
    f = summaries["Fixed 36h"][key]
    rr = summaries["Rolling 36h"][key]
    @printf("%-28s %14.3f %14.3f %14.3f\n", String(key), f, rr, f - rr)
end

fixed_by_hour = Dict(row.global_hour => row for row in hourly["Fixed 36h"])
rolling_by_hour = Dict(row.global_hour => row for row in hourly["Rolling 36h"])
paired = []
for h in sort(collect(intersect(keys(fixed_by_hour), keys(rolling_by_hour))))
    f = fixed_by_hour[h]
    rr = rolling_by_hour[h]
    push!(paired, (
        global_hour=h,
        delta_peak=f.peak_executed - rr.peak_executed,
        fixed_peak=f.peak_executed,
        rolling_peak=rr.peak_executed,
        delta_peak_q=f.peak_q - rr.peak_q,
        fixed_peak_q=f.peak_q,
        rolling_peak_q=rr.peak_q,
        delta_wind_q=f.wind_q - rr.wind_q,
        fixed_price=f.price,
        rolling_price=rr.price,
        fixed_nonflex_prev=f.nonflex_prev,
        rolling_nonflex_prev=rr.nonflex_prev,
        fixed_storage_net=f.storage_net,
        rolling_storage_net=rr.storage_net,
    ))
end

sort!(paired, by = x -> abs(x.delta_peak), rev=true)
println()
println("Top executed hours by |Fixed - Rolling peak output|:")
@printf("%8s %12s %12s %12s %12s %12s %12s %12s\n", "hour", "delta_peak", "fix_peak", "roll_peak", "delta_q", "fix_q", "roll_q", "d_wind_q")
for row in paired[1:min(15, length(paired))]
    @printf("%8d %12.3f %12.3f %12.3f %12.3f %12.3f %12.3f %12.3f\n",
        row.global_hour, row.delta_peak, row.fixed_peak, row.rolling_peak,
        row.delta_peak_q, row.fixed_peak_q, row.rolling_peak_q, row.delta_wind_q)
end

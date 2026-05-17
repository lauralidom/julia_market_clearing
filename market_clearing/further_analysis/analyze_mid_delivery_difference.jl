using Serialization
using JuMP
using HiGHS
using Printf

const RUN_DIR = get(ARGS, 1, joinpath("Results", "thesis_runs", "all_20260512_101146"))
const CASES = Dict(
    "Fixed 36h" => joinpath(RUN_DIR, "fixed_36h", "all_results.jls"),
    "Rolling 36h" => joinpath(RUN_DIR, "rolling_36h", "all_results.jls"),
)

const GENS = ("Base", "Mid", "Peak", "Solar", "Wind")

value_at(a, g::String, h::Int) = float(a[g, h])

function executed_rows(path::String)
    r = deserialize(path)
    rows = []
    for clearing in sort(collect(keys(r[:clearing_details])))
        d = r[:clearing_details][clearing]
        executed_hours = Int(d[:executed_hours])
        g = d[:g_planned]
        q = d[:q]
        for h in 1:executed_hours
            global_hour = Int(d[:current_hour]) + h - 1
            gen = Dict(name => value_at(g, name, h) for name in GENS)
            demand = float(d[:demand_base][h]) + float(d[:demand_flex][h])
            charge = float(d[:charging][h])
            discharge = float(d[:discharging][h])
            wind_available = h == 1 ? float(get(d, :wind_available_h1, gen["Wind"])) : NaN
            wind_curtailment = h == 1 ? float(get(d, :wind_curtailment_h1, 0.0)) : NaN
            push!(rows, (
                clearing = clearing,
                global_hour = global_hour,
                base = gen["Base"],
                mid = gen["Mid"],
                peak = gen["Peak"],
                solar = gen["Solar"],
                wind = gen["Wind"],
                demand = demand,
                charge = charge,
                discharge = discharge,
                net_discharge = discharge - charge,
                wind_available = wind_available,
                wind_curtailment = wind_curtailment,
                price = float(d[:prices][h]),
                mid_q = value_at(q, "Mid", h),
            ))
        end
    end
    return rows
end

function sumfield(rows, field::Symbol)
    vals = [getfield(row, field) for row in rows]
    return sum(skipmissing(filter(!isnan, vals)))
end

rows_by_case = Dict(name => executed_rows(path) for (name, path) in CASES)

metrics = (
    :demand,
    :charge,
    :discharge,
    :net_discharge,
    :base,
    :mid,
    :peak,
    :solar,
    :wind,
    :wind_available,
    :wind_curtailment,
)

println("Executed-hour Mid delivery decomposition")
println("Positive delta means Rolling 36h exceeds Fixed 36h.")
println()
@printf("%-20s %14s %14s %14s\n", "Metric", "Fixed 36h", "Rolling 36h", "Rolling-Fixed")
totals = Dict{String, Dict{Symbol, Float64}}()
for case_name in ("Fixed 36h", "Rolling 36h")
    totals[case_name] = Dict(metric => sumfield(rows_by_case[case_name], metric) for metric in metrics)
end
for metric in metrics
    f = totals["Fixed 36h"][metric]
    r = totals["Rolling 36h"][metric]
    @printf("%-20s %14.3f %14.3f %14.3f\n", String(metric), f, r, r - f)
end

println()
println("Energy-balance identity for the Mid difference:")
println("  Mid = demand + charge - discharge - Base - Peak - Solar - Wind")
delta = Dict(metric => totals["Rolling 36h"][metric] - totals["Fixed 36h"][metric] for metric in metrics)
terms = Dict(
    :demand => delta[:demand],
    :charge => delta[:charge],
    :minus_discharge => -delta[:discharge],
    :minus_base => -delta[:base],
    :minus_peak => -delta[:peak],
    :minus_solar => -delta[:solar],
    :minus_wind => -delta[:wind],
)
for key in (:demand, :charge, :minus_discharge, :minus_base, :minus_peak, :minus_solar, :minus_wind)
    @printf("  %-18s %+12.3f MWh\n", String(key), terms[key])
end
@printf("  %-18s %+12.3f MWh\n", "sum", sum(values(terms)))
@printf("  %-18s %+12.3f MWh\n", "actual_mid_delta", delta[:mid])

fixed_by_hour = Dict(row.global_hour => row for row in rows_by_case["Fixed 36h"])
rolling_by_hour = Dict(row.global_hour => row for row in rows_by_case["Rolling 36h"])
paired = []
for h in sort(collect(intersect(keys(fixed_by_hour), keys(rolling_by_hour))))
    f = fixed_by_hour[h]
    r = rolling_by_hour[h]
    push!(paired, (
        hour = h,
        delta_mid = r.mid - f.mid,
        delta_wind = r.wind - f.wind,
        delta_wind_available = r.wind_available - f.wind_available,
        delta_curtailment = r.wind_curtailment - f.wind_curtailment,
        delta_demand = r.demand - f.demand,
        delta_net_discharge = r.net_discharge - f.net_discharge,
        delta_peak = r.peak - f.peak,
        fixed_mid = f.mid,
        rolling_mid = r.mid,
        fixed_price = f.price,
        rolling_price = r.price,
    ))
end

sort!(paired, by = row -> abs(row.delta_mid), rev = true)
println()
println("Top executed hours by |Rolling - Fixed Mid output|:")
@printf("%8s %12s %12s %12s %12s %12s %12s %12s\n",
    "hour", "d_mid", "d_wind", "d_w_avail", "d_curt", "d_demand", "d_net_dis", "d_peak")
for row in paired[1:min(15, length(paired))]
    @printf("%8d %12.3f %12.3f %12.3f %12.3f %12.3f %12.3f %12.3f\n",
        row.hour, row.delta_mid, row.delta_wind, row.delta_wind_available,
        row.delta_curtailment, row.delta_demand, row.delta_net_discharge, row.delta_peak)
end

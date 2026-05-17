using Serialization
using JuMP
using HiGHS
using Printf

const RUN_DIR = get(ARGS, 1, joinpath("Results", "thesis_runs", "all_20260512_101146"))
const CASES = Dict(
    "Fixed 36h" => joinpath(RUN_DIR, "fixed_36h", "all_results.jls"),
    "Rolling 36h" => joinpath(RUN_DIR, "rolling_36h", "all_results.jls"),
)

value_at(a, g::String, h::Int) = float(a[g, h])

function executed_rows(path::String)
    r = deserialize(path)
    rows = []
    for clearing in sort(collect(keys(r[:clearing_details])))
        d = r[:clearing_details][clearing]
        executed_hours = Int(d[:executed_hours])
        g = d[:g_planned]
        q = d[:q]
        q_prev = d[:Q_prev]
        for h in 1:executed_hours
            push!(rows, (
                clearing = clearing,
                global_hour = Int(d[:current_hour]) + h - 1,
                base = value_at(g, "Base", h),
                base_q = value_at(q, "Base", h),
                base_prev = q_prev[("Base", h)],
                mid = value_at(g, "Mid", h),
                peak = value_at(g, "Peak", h),
                solar = value_at(g, "Solar", h),
                wind = value_at(g, "Wind", h),
                demand = float(d[:demand_base][h]) + float(d[:demand_flex][h]),
                charge = float(d[:charging][h]),
                discharge = float(d[:discharging][h]),
                net_discharge = float(d[:discharging][h]) - float(d[:charging][h]),
                price = float(d[:prices][h]),
            ))
        end
    end
    return rows
end

sumfield(rows, field::Symbol) = sum(getfield(row, field) for row in rows)

rows_by_case = Dict(name => executed_rows(path) for (name, path) in CASES)
metrics = (:base, :base_prev, :base_q, :mid, :peak, :solar, :wind, :demand, :charge, :discharge, :net_discharge)

println("Executed-hour Base delivery decomposition")
println("Positive delta means Fixed 36h exceeds Rolling 36h.")
println()
@printf("%-18s %14s %14s %14s\n", "Metric", "Fixed 36h", "Rolling 36h", "Fixed-Rolling")

totals = Dict{String, Dict{Symbol, Float64}}()
for case_name in ("Fixed 36h", "Rolling 36h")
    totals[case_name] = Dict(metric => sumfield(rows_by_case[case_name], metric) for metric in metrics)
end

for metric in metrics
    f = totals["Fixed 36h"][metric]
    r = totals["Rolling 36h"][metric]
    @printf("%-18s %14.3f %14.3f %14.3f\n", String(metric), f, r, f - r)
end

println()
println("Base gap split:")
@printf("  %-26s %+12.3f MWh\n", "locked/previous position", totals["Fixed 36h"][:base_prev] - totals["Rolling 36h"][:base_prev])
@printf("  %-26s %+12.3f MWh\n", "fresh adjustment q", totals["Fixed 36h"][:base_q] - totals["Rolling 36h"][:base_q])
@printf("  %-26s %+12.3f MWh\n", "total Base", totals["Fixed 36h"][:base] - totals["Rolling 36h"][:base])

fixed_by_hour = Dict(row.global_hour => row for row in rows_by_case["Fixed 36h"])
rolling_by_hour = Dict(row.global_hour => row for row in rows_by_case["Rolling 36h"])
paired = []
for h in sort(collect(intersect(keys(fixed_by_hour), keys(rolling_by_hour))))
    f = fixed_by_hour[h]
    r = rolling_by_hour[h]
    push!(paired, (
        hour = h,
        delta_base = f.base - r.base,
        delta_base_prev = f.base_prev - r.base_prev,
        delta_base_q = f.base_q - r.base_q,
        delta_mid = f.mid - r.mid,
        delta_wind = f.wind - r.wind,
        delta_net_discharge = f.net_discharge - r.net_discharge,
        fixed_price = f.price,
        rolling_price = r.price,
    ))
end

sort!(paired, by = row -> abs(row.delta_base), rev = true)
println()
println("Top executed hours by |Fixed - Rolling Base output|:")
@printf("%8s %12s %12s %12s %12s %12s %12s\n", "hour", "d_base", "d_prev", "d_q", "d_mid", "d_wind", "d_net_dis")
for row in paired[1:min(15, length(paired))]
    @printf("%8d %12.3f %12.3f %12.3f %12.3f %12.3f %12.3f\n",
        row.hour, row.delta_base, row.delta_base_prev, row.delta_base_q,
        row.delta_mid, row.delta_wind, row.delta_net_discharge)
end

using YAML
using Statistics
using Distributions
using Random
using JuMP

include("src/model_setup.jl")

cfg = YAML.load_file("input_data_rolling.yaml")
apply_simulation_month!(cfg)

rh = cfg["rolling_horizon"]
sim_days = Int(rh["simulation_days"])
look_ahead = Int(rh["look_ahead_window"])
forecast_noise = float(rh["forecast_noise_std"])
total_hours = sim_days * 24 + 1

# Build sets and load time series exactly like the rolling model does.
data = load_input_data("input_data_rolling.yaml")
m = Model()
define_sets!(m, data)
IG = m.ext[:sets][:IG]
ID = m.ext[:sets][:ID]
Pr_gen_full, Q_gen_full, Pr_dem_full, Q_dem_full = load_and_expand_timeseries(cfg, total_hours)

wind_cap = float(cfg["variableGenerators"]["Wind"]["capacity"])
t_dist = TDist(10)
rng = MersenneTwister(1234)
start_hours = 1:(total_hours - look_ahead)

abs_mw_err = Float64[]
abs_af_err = Float64[]
abs_pct_err = Float64[]
signed_pct_err = Float64[]
abs_cap_pct_err = Float64[]
abs_pct_err_gt10cap = Float64[]
abs_pct_err_gt20cap = Float64[]
simplified_signed_mw_err = Float64[]
per_h_abs_pct = [Float64[] for _ in 1:look_ahead]
per_h_abs_mw = [Float64[] for _ in 1:look_ahead]

n_samples = 200

for sh in start_hours
    _, Q_window, _, _ = get_window_timeseries(
        Pr_gen_full,
        Q_gen_full,
        Pr_dem_full,
        Q_dem_full,
        sh,
        look_ahead,
        IG,
        ID,
    )

    for h in 2:look_ahead
        actual = Q_window[("Wind", h)]
        if actual < 1e-6
            continue
        end

        time_factor = sqrt((h - 1) / (look_ahead - 1))
        std_dev = forecast_noise * time_factor
        af0 = actual / wind_cap

        for _ in 1:n_samples
            noise = rand(rng, t_dist) * std_dev
            af1 = clamp(af0 + noise, 0.0, 1.0)
            pred = wind_cap * af1
            err = pred - actual

            apct = abs(err) / actual * 100
            push!(abs_mw_err, abs(err))
            push!(abs_af_err, abs(af1 - af0))
            push!(abs_pct_err, apct)
            push!(signed_pct_err, err / actual * 100)
            push!(abs_cap_pct_err, abs(err) / wind_cap * 100)
            push!(simplified_signed_mw_err, err)
            if actual >= 0.10 * wind_cap
                push!(abs_pct_err_gt10cap, apct)
            end
            if actual >= 0.20 * wind_cap
                push!(abs_pct_err_gt20cap, apct)
            end
            push!(per_h_abs_pct[h], apct)
            push!(per_h_abs_mw[h], abs(err))
        end
    end
end

q(v, p) = quantile(v, p)

println("SUMMARY")
println("sim_days=$(sim_days) look_ahead=$(look_ahead) forecast_noise_std=$(forecast_noise) t_df=10 n_samples=$(n_samples)")
println("N points=$(length(abs_pct_err))")
println("ABS_PERCENT median=$(round(q(abs_pct_err, 0.5), digits=2)) p90=$(round(q(abs_pct_err, 0.9), digits=2)) p95=$(round(q(abs_pct_err, 0.95), digits=2)) p99=$(round(q(abs_pct_err, 0.99), digits=2))")
println("ABS_MW median=$(round(q(abs_mw_err, 0.5), digits=1)) p90=$(round(q(abs_mw_err, 0.9), digits=1)) p95=$(round(q(abs_mw_err, 0.95), digits=1)) p99=$(round(q(abs_mw_err, 0.99), digits=1))")
println("ABS_AF median=$(round(q(abs_af_err, 0.5), digits=4)) p90=$(round(q(abs_af_err, 0.9), digits=4)) p95=$(round(q(abs_af_err, 0.95), digits=4)) p99=$(round(q(abs_af_err, 0.99), digits=4))")
println("SIGNED_PERCENT mean=$(round(mean(signed_pct_err), digits=2)) std=$(round(std(signed_pct_err), digits=2))")
println("ABS_CAP_PERCENT median=$(round(q(abs_cap_pct_err, 0.5), digits=2)) p90=$(round(q(abs_cap_pct_err, 0.9), digits=2)) p95=$(round(q(abs_cap_pct_err, 0.95), digits=2)) p99=$(round(q(abs_cap_pct_err, 0.99), digits=2))")
println("ABS_PERCENT_WHEN_ACTUAL_GE_10PCTCAP median=$(round(q(abs_pct_err_gt10cap, 0.5), digits=2)) p90=$(round(q(abs_pct_err_gt10cap, 0.9), digits=2)) p95=$(round(q(abs_pct_err_gt10cap, 0.95), digits=2))")
println("ABS_PERCENT_WHEN_ACTUAL_GE_20PCTCAP median=$(round(q(abs_pct_err_gt20cap, 0.5), digits=2)) p90=$(round(q(abs_pct_err_gt20cap, 0.9), digits=2)) p95=$(round(q(abs_pct_err_gt20cap, 0.95), digits=2))")
println("SIGNED_MW mean=$(round(mean(simplified_signed_mw_err), digits=2))")

for h in (2, 6, 12, 18, 24)
    v = per_h_abs_pct[h]
    w = per_h_abs_mw[h]
    println("H=$(h) abs_percent_p50=$(round(q(v, 0.5), digits=2)) abs_percent_p90=$(round(q(v, 0.9), digits=2)) abs_percent_p95=$(round(q(v, 0.95), digits=2)) abs_mw_p50=$(round(q(w, 0.5), digits=1)) abs_mw_p90=$(round(q(w, 0.9), digits=1)) abs_mw_p95=$(round(q(w, 0.95), digits=1))")
end

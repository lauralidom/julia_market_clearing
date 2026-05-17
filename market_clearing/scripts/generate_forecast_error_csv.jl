using YAML
include(joinpath(@__DIR__, "..", "src", "model_setup.jl"))

cfg = YAML.load_file(joinpath(@__DIR__, "..", "input_data_rolling.yaml"))
rh = get(cfg, "rolling_horizon", Dict())

total_hours = Int(rh["wind_noise_total_hours"])
max_window = Int(rh["wind_noise_max_look_ahead"])
max_noise_std = float(rh["forecast_noise_std"])

println("Using total_hours=", total_hours, ", max_window=", max_window, ", max_noise_std=", max_noise_std)

path = wind_noise_scenario_path(cfg)
println("Scenario path=", path)

forecast_errors = load_or_create_wind_forecast_error_scenario!(cfg, max_noise_std, total_hours, max_window)
println("Generated entries=", length(forecast_errors))

using Test
using CSV
using DataFrames
using Statistics

include(joinpath(@__DIR__, "..", "src", "model_setup.jl"))

function fixed_visible_horizon(window_start_hour::Int; max_look_ahead::Int=36, min_look_ahead::Int=13)
    cycle_length = max_look_ahead - min_look_ahead + 1
    offset = mod(window_start_hour - 1, cycle_length)
    return max_look_ahead - offset
end

@testset "Wind Forecast Error Scenario" begin
    simulation_hours = 400
    max_window_length = 72
    max_noise_std = 0.20
    forecast_errors, rows = generate_wind_forecast_error_scenario(simulation_hours, max_window_length, max_noise_std; seed=20260325)

    @test validate_wind_forecast_error_coverage(forecast_errors, simulation_hours, max_window_length) === nothing
    @test all(rows.lead_time .== rows.abs_hour .- rows.window_start_hour .+ 1)

    lead1_rows = rows[rows.lead_time .== 1, :]
    @test all(lead1_rows.forecast_error .== 0.0)
    @test all(lead1_rows.raw_draw .== 0.0)
    @test all(lead1_rows.z_value .== 0.0)
    @test all(lead1_rows.std_dev .== 0.0)

    first_visible_rows = rows[(rows.lead_time .> 1) .& (rows.window_start_hour .== max.(1, rows.abs_hour .- max_window_length .+ 1)), :]
    @test !isempty(first_visible_rows)
    @test all(isapprox.(first_visible_rows.z_value, first_visible_rows.raw_draw; atol=1e-12, rtol=0.0))
    @test all(isapprox.(first_visible_rows.forecast_error, first_visible_rows.std_dev .* first_visible_rows.raw_draw; atol=1e-12, rtol=0.0))

    std_36 = std(rows[rows.lead_time .== 36, :forecast_error])
    std_72 = std(rows[rows.lead_time .== 72, :forecast_error])
    @test std_72 > std_36

    rolling36 = Dict{Tuple{Int, Int}, Float64}()
    fixed36 = Dict{Tuple{Int, Int}, Float64}()
    rolling72 = Dict{Tuple{Int, Int}, Float64}()

    for window_start_hour in 1:simulation_hours
        for lead_time in 1:36
            abs_hour = window_start_hour + lead_time - 1
            rolling36[(window_start_hour, abs_hour)] = forecast_errors[(window_start_hour, abs_hour)]
        end

        for lead_time in 1:72
            abs_hour = window_start_hour + lead_time - 1
            rolling72[(window_start_hour, abs_hour)] = forecast_errors[(window_start_hour, abs_hour)]
        end

        for lead_time in 1:fixed_visible_horizon(window_start_hour)
            abs_hour = window_start_hour + lead_time - 1
            fixed36[(window_start_hour, abs_hour)] = forecast_errors[(window_start_hour, abs_hour)]
        end
    end

    for key in keys(fixed36)
        @test fixed36[key] == rolling36[key]
    end

    for key in keys(rolling36)
        @test rolling36[key] == rolling72[key]
    end

    broken_errors = copy(forecast_errors)
    delete!(broken_errors, (10, 15))
    coverage_err = try
        validate_wind_forecast_error_coverage(broken_errors, simulation_hours, max_window_length)
        nothing
    catch err
        err
    end
    @test coverage_err isa ErrorException
    @test occursin("missing", lowercase(sprint(showerror, coverage_err)))

    wind_cfg = Dict(
        "variableGenerators" => Dict(
            "Wind" => Dict("capacity" => 100.0),
            "Solar" => Dict("capacity" => 80.0),
        ),
    )
    q_window = Dict(
        ("Wind", 1) => 60.0,
        ("Wind", 2) => 60.0,
        ("Solar", 1) => 40.0,
        ("Solar", 2) => 40.0,
    )
    missing_key_err = try
        add_wind_forecast_noise!(q_window, wind_cfg, max_noise_std, ["Wind", "Solar"], 2, 99; precomputed_errors=Dict{Tuple{Int, Int}, Float64}())
        nothing
    catch err
        err
    end
    @test missing_key_err isa ErrorException
    @test occursin("Missing precomputed wind forecast error", sprint(showerror, missing_key_err))

    tmpdir = mktempdir()
    scenario_path = joinpath(tmpdir, "scenario.csv")
    broken_rows = rows[Not((rows.window_start_hour .== 10) .& (rows.abs_hour .== 15)), :]
    CSV.write(scenario_path, broken_rows)

    cfg = Dict(
        "rolling_horizon" => Dict(
            "wind_noise_mode" => "predefined",
            "wind_noise_scenario_path" => scenario_path,
            "wind_noise_seed" => 20260325,
            "wind_noise_total_hours" => simulation_hours,
            "wind_noise_max_look_ahead" => max_window_length,
        ),
    )

    load_err = try
        load_or_create_wind_forecast_error_scenario!(cfg, max_noise_std, simulation_hours, max_window_length)
        nothing
    catch err
        err
    end
    @test load_err isa ErrorException
    @test occursin("missing", lowercase(sprint(showerror, load_err)))
end

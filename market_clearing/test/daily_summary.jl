using Test
using Dates
using JuMP
using XLSX

include(joinpath(@__DIR__, "..", "src", "costs.jl"))

function synthetic_cfg()
    return Dict(
        "rolling_horizon" => Dict(
            "simulation_month" => 1,
            "simulation_start_hour" => 12,
            "simulation_days" => 30,
        ),
        "dispatchableGenerators" => Dict(
            "Base" => Dict("bidPrice" => 30.0),
            "Mid" => Dict("bidPrice" => 80.0),
            "Peak" => Dict("bidPrice" => 150.0),
        ),
        "variableGenerators" => Dict(
            "Wind" => Dict("bidPrice" => 0.0),
            "Solar" => Dict("bidPrice" => 0.0),
        ),
        "batteryStorage" => Dict(
            "energyCapacity" => 6000.0,
            "powerCapacity" => 2000.0,
        ),
        "demand" => Dict(
            "segments" => Dict(
                "Base" => Dict("bidPrice" => 300.0),
                "Flex" => Dict("bidPrice" => 50.0),
            ),
        ),
    )
end

function synthetic_dispatch(base::Float64, mid::Float64, peak::Float64, wind::Float64, solar::Float64)
    data = reshape([base, mid, peak, wind, solar], 5, 1)
    return JuMP.Containers.DenseAxisArray(data, ["Base", "Mid", "Peak", "Wind", "Solar"], 1:1)
end

function synthetic_results(day_specs)
    clearing_details = Dict{Int, Dict{Symbol, Any}}()

    for (idx, spec) in enumerate(day_specs)
        clearing_details[idx] = Dict{Symbol, Any}(
            :current_hour => spec.current_hour,
            :executed_hours => 1,
            :prices => [spec.price],
            :g_planned => synthetic_dispatch(spec.base, spec.mid, spec.peak, spec.wind, spec.solar),
            :demand_base => [spec.demand_base],
            :demand_flex => [spec.demand_flex],
            :charging => [spec.charge],
            :discharging => [spec.discharge],
            :storage_soc_path => [spec.end_soc],
            :storage_soc_end_executed => spec.end_soc,
            :wind_curtailment_h1 => spec.curtailment,
            :imbalance_h1 => spec.imbalance,
        )
    end

    return Dict(
        :clearing_details => clearing_details,
    )
end

@testset "Daily Summary Export" begin
    cfg = synthetic_cfg()

    fixed_results = synthetic_results([
        (current_hour=1, price=40.0, base=2.0, mid=0.0, peak=0.0, wind=1.0, solar=0.0, demand_base=3.0, demand_flex=0.0, charge=1.0, discharge=0.0, end_soc=100.0, curtailment=0.0, imbalance=0.0),
        (current_hour=13, price=60.0, base=3.0, mid=0.0, peak=0.0, wind=1.0, solar=0.0, demand_base=4.0, demand_flex=0.0, charge=0.0, discharge=2.0, end_soc=80.0, curtailment=1.0, imbalance=0.75),
    ])
    rolling_results = synthetic_results([
        (current_hour=1, price=35.0, base=1.5, mid=0.0, peak=0.0, wind=1.5, solar=0.0, demand_base=3.0, demand_flex=0.0, charge=0.5, discharge=0.0, end_soc=110.0, curtailment=0.0, imbalance=-0.25),
        (current_hour=13, price=70.0, base=3.5, mid=0.0, peak=0.0, wind=0.5, solar=0.0, demand_base=4.0, demand_flex=0.0, charge=0.0, discharge=1.5, end_soc=70.0, curtailment=2.0, imbalance=1.25),
    ])

    fixed_daily = collect_daily_case_metrics(fixed_results, cfg)
    @test nrow(fixed_daily) == 2
    @test fixed_daily.simulation_day == [1, 2]
    @test fixed_daily.executed_hours == [1, 1]
    @test fixed_daily.social_welfare_eur == [840.0, 1110.0]
    @test fixed_daily.storage_revenue_eur == [-40.0, 120.0]
    @test fixed_daily.end_soc_mwh == [100.0, 80.0]
    @test fixed_daily.imbalance_mwh == [0.0, 0.75]

    fixed_case = Dict(
        :case_name => "Fixed 36h",
        :case_type => "fixed",
        :cfg => cfg,
        :all_results => fixed_results,
        :kpis => (look_ahead_h=36, storage_energy_capacity_mwh=6000.0, storage_power_capacity_mw=2000.0),
    )
    rolling_case = Dict(
        :case_name => "Rolling 36h",
        :case_type => "rolling",
        :cfg => cfg,
        :all_results => rolling_results,
        :kpis => (look_ahead_h=36, storage_energy_capacity_mwh=6000.0, storage_power_capacity_mw=2000.0),
    )
    rolling_48_results = synthetic_results([
        (current_hour=1, price=34.0, base=1.4, mid=0.0, peak=0.0, wind=1.6, solar=0.0, demand_base=3.0, demand_flex=0.0, charge=0.4, discharge=0.0, end_soc=115.0, curtailment=0.0, imbalance=-0.15),
        (current_hour=13, price=68.0, base=3.3, mid=0.0, peak=0.0, wind=0.7, solar=0.0, demand_base=4.0, demand_flex=0.0, charge=0.0, discharge=1.7, end_soc=75.0, curtailment=1.5, imbalance=0.9),
    ])
    rolling_72_results = synthetic_results([
        (current_hour=1, price=33.0, base=1.2, mid=0.0, peak=0.0, wind=1.8, solar=0.0, demand_base=3.0, demand_flex=0.0, charge=0.3, discharge=0.0, end_soc=120.0, curtailment=0.0, imbalance=-0.35),
        (current_hour=13, price=66.0, base=3.1, mid=0.0, peak=0.0, wind=0.9, solar=0.0, demand_base=4.0, demand_flex=0.0, charge=0.0, discharge=1.8, end_soc=78.0, curtailment=1.0, imbalance=0.6),
    ])
    rolling_48_case = Dict(
        :case_name => "Rolling 48h",
        :case_type => "rolling",
        :cfg => cfg,
        :all_results => rolling_48_results,
        :kpis => (look_ahead_h=48, storage_energy_capacity_mwh=6000.0, storage_power_capacity_mw=2000.0),
    )
    rolling_72_case = Dict(
        :case_name => "Rolling 72h",
        :case_type => "rolling",
        :cfg => cfg,
        :all_results => rolling_72_results,
        :kpis => (look_ahead_h=72, storage_energy_capacity_mwh=6000.0, storage_power_capacity_mw=2000.0),
    )

    pair_df, left_name, right_name = build_daily_pair_dataframe(fixed_case, rolling_case)
    @test left_name == "Fixed 36h"
    @test right_name == "Rolling 36h"
    @test pair_df.rank_by_delta_social_welfare == [1, 2]
    @test pair_df.simulation_day == [1, 2]
    @test pair_df.social_welfare_eur_diff == [15.0, -15.0]
    @test pair_df.generation_cost_eur_diff == [-15.0, 15.0]
    @test pair_df.end_soc_mwh_diff == [10.0, -10.0]
    @test pair_df.imbalance_mwh_diff == [-0.25, 0.5]

    stats_row = daily_delta_swf_stats_row(pair_df, left_name, right_name)
    @test stats_row.case_a == "Fixed 36h"
    @test stats_row.case_b == "Rolling 36h"
    @test stats_row.delta_definition == "Rolling 36h - Fixed 36h"
    @test stats_row.aligned_days == 2
    @test stats_row.mean_daily_delta_swf_eur == 0.0
    @test stats_row.median_daily_delta_swf_eur == 0.0
    @test isapprox(stats_row.std_daily_delta_swf_eur, sqrt(450.0); atol=1e-10)
    @test stats_row.share_days_case_b_better == 0.5
    @test stats_row.share_days_case_a_better == 0.5
    @test stats_row.share_days_equal == 0.0
    @test stats_row.count_days_case_b_better == 1
    @test stats_row.count_days_case_a_better == 1
    @test stats_row.count_days_equal == 0

    driver_df = build_daily_driver_pair_dataframe(fixed_case, rolling_case)
    @test nrow(driver_df) == 2
    @test driver_df.rank_by_delta_social_welfare == [1, 2]
    @test driver_df.delta_social_welfare_eur == [15.0, -15.0]
    @test driver_df.delta_avg_price_eur_per_mwh == [-5.0, 10.0]
    @test driver_df.delta_wind_mwh == [0.5, -0.5]
    @test driver_df.delta_imbalance_mwh == [-0.25, 0.5]
    @test driver_df.delta_mid_dispatch_mwh == [0.0, 0.0]
    @test ismissing(driver_df.delta_avg_visible_abs_forecast_error[1])

    pairs = daily_summary_case_pairs([fixed_case, rolling_case, rolling_48_case, rolling_72_case])
    @test length(pairs) == 4

    groups = daily_summary_rolling_groups([fixed_case, rolling_case, rolling_48_case, rolling_72_case])
    @test length(groups) == 1
    @test [case[:case_name] for case in first(groups)] == ["Rolling 36h", "Rolling 48h", "Rolling 72h"]

    multi_df, ordered_cases, case_names, prefixes, pair_specs = build_daily_multicase_dataframe(first(groups))
    @test case_names == ["Rolling 36h", "Rolling 48h", "Rolling 72h"]
    @test prefixes == ["rolling_36h", "rolling_48h", "rolling_72h"]
    @test length(pair_specs) == 3
    @test multi_df.rank_by_span_social_welfare == [1, 2]
    @test multi_df[1, :rolling_36h_to_rolling_72h_social_welfare_eur_diff] == 12.0
    @test multi_df[2, :rolling_36h_to_rolling_72h_social_welfare_eur_diff] == 9.0

    tmpdir = mktempdir()
    path = joinpath(tmpdir, "summary_daily.xlsx")
    export_daily_summary_to_excel([fixed_case, rolling_case, rolling_48_case, rolling_72_case]; path=path)
    @test isfile(path)
    @test isfile(joinpath(tmpdir, "daily_drivers.csv"))
    @test isfile(joinpath(tmpdir, "delta_swf_stats.csv"))
    xf = XLSX.readxlsx(path)
    @test "Delta_SWF_Stats" in XLSX.sheetnames(xf)
    @test "Daily_Drivers" in XLSX.sheetnames(xf)
    @test "rolling_group_vs_36h_48h_72h" in XLSX.sheetnames(xf)
end

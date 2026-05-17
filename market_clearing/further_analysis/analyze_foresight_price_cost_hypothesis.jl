using Serialization
using Statistics
using CSV
using DataFrames
using Plots
using Printf

# Small standalone analysis for the saved foresight run.
# It reconstructs executed-hour outcomes case by case and compares
# aligned hourly deltas to test the price/system-cost story directly.

const RUN_DIR = joinpath("Results", "thesis_runs", "foresight_20260323_234223")
const CASE_FOLDERS = Dict(
    "Rolling 36h" => "rolling_36h",
    "Rolling 48h" => "rolling_48h",
    "Rolling 72h" => "rolling_72h",
)

function load_case(run_dir::AbstractString, case_folder::AbstractString)
    case_dir = joinpath(run_dir, case_folder)
    all_results = deserialize(joinpath(case_dir, "all_results.jls"))
    cfg = deserialize(joinpath(case_dir, "cfg.jls"))
    return all_results, cfg
end

function dispatch_value(details::Dict, gen::AbstractString, h::Int)
    g_planned = details[:g_planned]
    return g_planned[gen, h]
end

function executed_hourly_df(case_name::AbstractString, all_results::Dict, cfg::Dict)
    clearing_details = all_results[:clearing_details]
    rows = NamedTuple[]

    bid_base = float(cfg["dispatchableGenerators"]["Base"]["bidPrice"])
    bid_mid = float(cfg["dispatchableGenerators"]["Mid"]["bidPrice"])
    bid_peak = float(cfg["dispatchableGenerators"]["Peak"]["bidPrice"])

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        current_hour = details[:current_hour]

        for h in 1:executed_hours
            global_hour = current_hour + h - 1
            hour_of_day = mod(global_hour - 1, 24) + 1

            base = dispatch_value(details, "Base", h)
            mid = dispatch_value(details, "Mid", h)
            peak = dispatch_value(details, "Peak", h)
            solar = dispatch_value(details, "Solar", h)
            wind = dispatch_value(details, "Wind", h)

            charge = details[:charging][h]
            discharge = details[:discharging][h]
            net_discharge = discharge - charge
            flex = details[:demand_flex][h]
            demand_total = details[:demand_base][h] + flex
            thermal_cost = base * bid_base + mid * bid_mid + peak * bid_peak

            push!(rows, (
                case_name = String(case_name),
                clearing = clearing_num,
                global_hour = global_hour,
                hour_of_day = hour_of_day,
                price = details[:prices][h],
                base = base,
                mid = mid,
                peak = peak,
                solar = solar,
                wind = wind,
                charge = charge,
                discharge = discharge,
                net_discharge = net_discharge,
                flex_demand = flex,
                total_demand = demand_total,
                thermal_dispatch = base + mid + peak,
                thermal_cost = thermal_cost,
                wind_curtailment = get(details, :wind_curtailment_h1, 0.0),
            ))
        end
    end

    return DataFrame(rows)
end

function summarise_case(df_case::DataFrame)
    return (
        hours = nrow(df_case),
        avg_price = mean(df_case.price),
        avg_thermal_cost_per_hour = mean(df_case.thermal_cost),
        avg_net_discharge = mean(df_case.net_discharge),
        avg_flex_demand = mean(df_case.flex_demand),
        avg_mid = mean(df_case.mid),
        avg_peak = mean(df_case.peak),
        avg_curtailment = mean(df_case.wind_curtailment),
    )
end

function paired_delta_df(df::DataFrame, left_case::AbstractString, right_case::AbstractString)
    left = select(
        filter(:case_name => ==(left_case), df),
        :global_hour,
        :price,
        :thermal_cost,
        :net_discharge,
        :flex_demand,
        :mid,
        :peak,
        :wind_curtailment,
    )
    rename_left = Dict{Symbol, Symbol}()
    for name in propertynames(left)
        if name != :global_hour
            rename_left[name] = Symbol(string(name), "_left")
        end
    end
    rename!(left, rename_left)

    right = select(
        filter(:case_name => ==(right_case), df),
        :global_hour,
        :price,
        :thermal_cost,
        :net_discharge,
        :flex_demand,
        :mid,
        :peak,
        :wind_curtailment,
    )
    rename_right = Dict{Symbol, Symbol}()
    for name in propertynames(right)
        if name != :global_hour
            rename_right[name] = Symbol(string(name), "_right")
        end
    end
    rename!(right, rename_right)

    paired = innerjoin(left, right, on=:global_hour)
    paired[!, :delta_price] = paired.price_right .- paired.price_left
    paired[!, :delta_thermal_cost] = paired.thermal_cost_right .- paired.thermal_cost_left
    paired[!, :delta_net_discharge] = paired.net_discharge_right .- paired.net_discharge_left
    paired[!, :delta_flex_demand] = paired.flex_demand_right .- paired.flex_demand_left
    paired[!, :delta_mid] = paired.mid_right .- paired.mid_left
    paired[!, :delta_peak] = paired.peak_right .- paired.peak_left
    paired[!, :delta_mid_peak] = paired.delta_mid .+ paired.delta_peak
    paired[!, :delta_curtailment] = paired.wind_curtailment_right .- paired.wind_curtailment_left
    return paired
end

function safe_cor(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    (length(x) > 1 && std(x) > 0 && std(y) > 0) ? cor(x, y) : NaN
end

function print_pair_story(paired::DataFrame, left_case::AbstractString, right_case::AbstractString)
    println()
    println("Pair analysis: $right_case minus $left_case")
    println("-"^72)
    @printf("Aligned executed hours: %d\n", nrow(paired))
    @printf("Mean delta price (EUR/MWh): %.4f\n", mean(paired.delta_price))
    @printf("Mean delta thermal cost (EUR/h): %.2f\n", mean(paired.delta_thermal_cost))
    @printf("Mean delta net battery discharge (MWh/h): %.4f\n", mean(paired.delta_net_discharge))
    @printf("Mean delta flex demand (MWh/h): %.4f\n", mean(paired.delta_flex_demand))
    @printf("Mean delta Mid+Peak dispatch (MWh/h): %.4f\n", mean(paired.delta_mid_peak))
    @printf("Mean delta curtailment (MWh/h): %.4f\n", mean(paired.delta_curtailment))
    @printf("corr(delta price, delta net discharge): %.4f\n", safe_cor(paired.delta_price, paired.delta_net_discharge))
    @printf("corr(delta thermal cost, delta Mid+Peak dispatch): %.4f\n", safe_cor(paired.delta_thermal_cost, paired.delta_mid_peak))
end

function plot_hourly_profiles(df::DataFrame, output_dir::AbstractString)
    hourly = combine(
        groupby(df, [:case_name, :hour_of_day]),
        :price => mean => :avg_price,
        :thermal_cost => mean => :avg_thermal_cost,
        :net_discharge => mean => :avg_net_discharge,
        :flex_demand => mean => :avg_flex_demand,
    )

    case_order = ["Rolling 36h", "Rolling 48h", "Rolling 72h"]
    metrics = [
        (:avg_price, "Average Executed Price", "EUR/MWh"),
        (:avg_thermal_cost, "Average Thermal Cost", "EUR/h"),
        (:avg_net_discharge, "Average Net Battery Discharge", "MWh/h"),
        (:avg_flex_demand, "Average Flex Demand Served", "MWh/h"),
    ]

    p = plot(layout=(length(metrics), 1), size=(1100, 320 * length(metrics)))
    for (idx, (metric, title, ylabel)) in enumerate(metrics)
        for case_name in case_order
            subset = sort(filter(:case_name => ==(case_name), hourly), :hour_of_day)
            plot!(
                p[idx],
                subset.hour_of_day,
                subset[!, metric],
                linewidth=3,
                marker=:circle,
                markersize=3,
                xlabel="Hour of day",
                ylabel=ylabel,
                title=title,
                label=case_name,
            )
        end
    end

    savefig(p, joinpath(output_dir, "foresight_price_cost_hourly_profiles.png"))
    return p
end

function plot_price_duration(df::DataFrame, output_dir::AbstractString)
    case_order = ["Rolling 36h", "Rolling 48h", "Rolling 72h"]
    p = plot(size=(1000, 500), xlabel="Executed hour rank", ylabel="Price (EUR/MWh)", title="Executed Price Duration Curves")
    for case_name in case_order
        prices = sort(collect(filter(:case_name => ==(case_name), df).price), rev=true)
        plot!(p, 1:length(prices), prices, linewidth=3, label=case_name)
    end
    savefig(p, joinpath(output_dir, "foresight_price_duration_curves.png"))
    return p
end

function plot_delta_scatter(paired::DataFrame, left_case::AbstractString, right_case::AbstractString, output_dir::AbstractString)
    p1 = scatter(
        paired.delta_net_discharge,
        paired.delta_price,
        xlabel="Delta net battery discharge (MWh/h)",
        ylabel="Delta price (EUR/MWh)",
        title="$right_case - $left_case: Price vs Battery Shift",
        alpha=0.6,
        markersize=3,
        label="",
    )

    p2 = scatter(
        paired.delta_mid_peak,
        paired.delta_thermal_cost,
        xlabel="Delta Mid+Peak dispatch (MWh/h)",
        ylabel="Delta thermal cost (EUR/h)",
        title="$right_case - $left_case: Cost vs Expensive Thermal Dispatch",
        alpha=0.6,
        markersize=3,
        label="",
    )

    combined = plot(p1, p2, layout=(1, 2), size=(1300, 500))
    filename = replace(lowercase("$right_case minus $left_case"), r"[^a-z0-9]+" => "_")
    savefig(combined, joinpath(output_dir, "delta_scatter_$filename.png"))
    return combined
end

function main()
    isdir(RUN_DIR) || error("Run directory not found: $RUN_DIR")
    output_dir = joinpath(RUN_DIR, "_hypothesis_analysis")
    isdir(output_dir) || mkpath(output_dir)

    case_dfs = DataFrame[]
    for (case_name, folder_name) in CASE_FOLDERS
        all_results, cfg = load_case(RUN_DIR, folder_name)
        df_case = executed_hourly_df(case_name, all_results, cfg)
        push!(case_dfs, df_case)
        summary = summarise_case(df_case)
        println()
        println("Case summary: $case_name")
        println("-"^72)
        @printf("Executed hours: %d\n", summary.hours)
        @printf("Average executed price (EUR/MWh): %.4f\n", summary.avg_price)
        @printf("Average thermal cost per executed hour (EUR/h): %.2f\n", summary.avg_thermal_cost_per_hour)
        @printf("Average net battery discharge (MWh/h): %.4f\n", summary.avg_net_discharge)
        @printf("Average flex demand served (MWh/h): %.4f\n", summary.avg_flex_demand)
        @printf("Average Mid dispatch (MWh/h): %.4f\n", summary.avg_mid)
        @printf("Average Peak dispatch (MWh/h): %.4f\n", summary.avg_peak)
        @printf("Average curtailment (MWh/h): %.4f\n", summary.avg_curtailment)
    end

    df = vcat(case_dfs...)
    CSV.write(joinpath(output_dir, "executed_hourly_metrics.csv"), df)

    plot_hourly_profiles(df, output_dir)
    plot_price_duration(df, output_dir)

    paired_48_36 = paired_delta_df(df, "Rolling 36h", "Rolling 48h")
    paired_72_48 = paired_delta_df(df, "Rolling 48h", "Rolling 72h")
    CSV.write(joinpath(output_dir, "paired_deltas_48_minus_36.csv"), paired_48_36)
    CSV.write(joinpath(output_dir, "paired_deltas_72_minus_48.csv"), paired_72_48)

    print_pair_story(paired_48_36, "Rolling 36h", "Rolling 48h")
    print_pair_story(paired_72_48, "Rolling 48h", "Rolling 72h")

    plot_delta_scatter(paired_48_36, "Rolling 36h", "Rolling 48h", output_dir)
    plot_delta_scatter(paired_72_48, "Rolling 48h", "Rolling 72h", output_dir)

    println()
    println("Saved hypothesis-analysis outputs to: $output_dir")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

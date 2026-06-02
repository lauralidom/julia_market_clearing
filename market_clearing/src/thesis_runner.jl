using YAML
using JuMP
using HiGHS
using Plots
using Random
using Statistics
using Distributions
using CSV
using DataFrames
using Serialization
using Printf
using Dates

include("model_setup.jl")
include("market_model.jl")
include("visualisation.jl")
include("costs.jl")

function sanitize_case_name(case_name::AbstractString)
    safe = replace(lowercase(String(case_name)), r"[^a-z0-9]+" => "_")
    safe = replace(safe, r"^_+|_+$" => "")
    return isempty(safe) ? "case" : safe
end

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
    return path
end

function run_embedded_daily_driver_analysis(summary_dir::AbstractString; verbose::Bool=true)
    analysis_path = normpath(joinpath(@__DIR__, "..", "further_analysis", "analyze_daily_driver_patterns.jl"))
    analysis_module = Module(gensym(:DailyDriverPatternAnalysis))
    Base.include(analysis_module, analysis_path)
    return Core.eval(
        analysis_module,
        :(run_daily_driver_pattern_analysis($summary_dir; verbose=$verbose)),
    )
end

function disabled_script_plot_selection()
    return Dict(
        :case_overview => false,
        :price_storage_timing => false,
        :storage_value => false,
    )
end

function average_executed_price(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    total_price = 0.0
    total_hours = 0

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        for h in 1:executed_hours
            total_price += details[:prices][h]
            total_hours += 1
        end
    end

    return total_hours > 0 ? total_price / total_hours : 0.0
end

function thesis_collect_price_storage_timing_diagnostics(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    isempty(clearing_details) && error("No clearing details found in all_results.")

    avg_price_by_hour = zeros(Float64, 24)
    net_discharge_by_hour = zeros(Float64, 24)
    hour_counts = zeros(Int, 24)

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        start_hour = details[:current_hour]

        for h in 1:executed_hours
            global_hour = start_hour + h - 1
            hour_of_day = mod(global_hour - 1, 24) + 1
            price = details[:prices][h]
            net_discharge = details[:discharging][h] - details[:charging][h]

            avg_price_by_hour[hour_of_day] += price
            net_discharge_by_hour[hour_of_day] += net_discharge
            hour_counts[hour_of_day] += 1
        end
    end

    return Dict(
        :avg_price_by_hour => [hour_counts[h] > 0 ? avg_price_by_hour[h] / hour_counts[h] : 0.0 for h in 1:24],
        :avg_net_discharge_by_hour => [hour_counts[h] > 0 ? net_discharge_by_hour[h] / hour_counts[h] : 0.0 for h in 1:24],
        :hour_counts => hour_counts,
    )
end

function thesis_collect_storage_value_diagnostics(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    isempty(clearing_details) && error("No clearing details found in all_results.")

    marginal_value_by_hour = zeros(Float64, 24)
    hour_counts = zeros(Int, 24)
    marginal_values = Float64[]

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        hour_of_day = mod(details[:current_hour] - 1, 24) + 1
        marginal_value = -details[:storage_initial_soc_dual]
        marginal_value_by_hour[hour_of_day] += marginal_value
        hour_counts[hour_of_day] += 1
        push!(marginal_values, marginal_value)
    end

    return Dict(
        :avg_marginal_value_by_hour => [hour_counts[h] > 0 ? marginal_value_by_hour[h] / hour_counts[h] : 0.0 for h in 1:24],
        :all_marginal_values => marginal_values,
        :hour_counts => hour_counts,
    )
end

function final_executed_soc(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    isempty(clearing_details) && return 0.0
    last_clearing = maximum(collect(keys(clearing_details)))
    return clearing_details[last_clearing][:storage_soc_end_executed]
end

function executed_days(all_results::Dict)
    clearing_details = get(all_results, :clearing_details, Dict())
    total_executed_hours = sum(details[:executed_hours] for details in values(clearing_details))
    return total_executed_hours / 24
end

function collect_case_kpis(case_name::AbstractString, case_type::AbstractString, all_results::Dict, cfg::Dict)
    welfare = calculate_social_welfare(all_results, cfg)
    storage = calculate_storage_revenue(all_results, cfg)
    sim_days = Int(cfg["rolling_horizon"]["simulation_days"])
    actual_days = executed_days(all_results)
    normalization_days = haskey(cfg["rolling_horizon"], "comparable_delivery_hours_override") ? actual_days : sim_days
    look_ahead = Int(cfg["rolling_horizon"]["look_ahead_window"])
    reclear_freq = Int(cfg["rolling_horizon"]["reclear_frequency"])
    battery = cfg["batteryStorage"]
    total_curtailment = haskey(all_results, :curtailment_energy) ? sum(all_results[:curtailment_energy]) : 0.0
    total_imbalance = haskey(all_results, :imbalance_energy) ? sum(all_results[:imbalance_energy]) : 0.0
    normalization_days > 0 || error("No executed delivery hours found for case $case_name.")

    return (
        case_name = String(case_name),
        case_type = String(case_type),
        look_ahead_h = look_ahead,
        reclear_frequency_h = reclear_freq,
        sim_days = sim_days,
        executed_days = actual_days,
        normalization_days = normalization_days,
        storage_energy_capacity_mwh = float(battery["energyCapacity"]),
        storage_power_capacity_mw = float(battery["powerCapacity"]),
        social_welfare_eur_per_day = welfare[:social_welfare] / normalization_days,
        generation_cost_eur_per_day = welfare[:total_generation_cost] / normalization_days,
        demand_value_eur_per_day = welfare[:total_demand_value] / normalization_days,
        avg_executed_price_eur_per_mwh = average_executed_price(all_results),
        max_executed_price_eur_per_mwh = calculate_adequacy_metrics(all_results, cfg)[:max_executed_price],
        wind_curtailment_mwh_per_day = total_curtailment / normalization_days,
        imbalance_mwh_per_day = total_imbalance / normalization_days,
        storage_charge_mwh_per_day = storage[:total_charging_energy] / normalization_days,
        storage_discharge_mwh_per_day = storage[:total_discharge_energy] / normalization_days,
        storage_throughput_mwh_per_day = (storage[:total_charging_energy] + storage[:total_discharge_energy]) / normalization_days,
        storage_net_revenue_eur_per_day = storage[:net_revenue] / normalization_days,
        avg_charging_price_eur_per_mwh = storage[:avg_charging_price],
        avg_discharging_price_eur_per_mwh = storage[:avg_discharge_price],
        final_soc_mwh = final_executed_soc(all_results),
    )
end

function save_case_artifacts(all_results::Dict, cfg::Dict, case_dir::AbstractString;
                             plot_selection::Dict=Dict{Symbol, Bool}(),
                             save_results::Bool=true,
                             save_excel_summary::Bool=true,
                             display_plots::Bool=false)
    ensure_dir(case_dir)

    if save_results
        serialize(joinpath(case_dir, "all_results.jls"), all_results)
        serialize(joinpath(case_dir, "cfg.jls"), cfg)
    end

    if save_excel_summary
        export_full_summary_to_excel(all_results, cfg; path=joinpath(case_dir, "economic_summary.xlsx"))
    end

    if get(plot_selection, :case_overview, false)
        p = plot_rolling_horizon_results(all_results)
        savefig(p, joinpath(case_dir, "case_overview.png"))
        display_plots && display(p)
    end

    if get(plot_selection, :battery_diagnostics, false)
        p = plot_battery_diagnostics(all_results)
        savefig(p, joinpath(case_dir, "battery_diagnostics.png"))
        display_plots && display(p)
    end

    if get(plot_selection, :price_storage_timing, false)
        p = plot_price_storage_timing_diagnostics(all_results)
        savefig(p, joinpath(case_dir, "price_storage_timing.png"))
        display_plots && display(p)
    end

    if get(plot_selection, :storage_value, false)
        p = plot_storage_value_diagnostics(all_results)
        savefig(p, joinpath(case_dir, "storage_value.png"))
        display_plots && display(p)
    end

    return case_dir
end

function save_kpi_summary(kpi_rows, output_dir::AbstractString; filename::AbstractString="kpi_summary.csv")
    ensure_dir(output_dir)
    df = DataFrame(kpi_rows)
    path = joinpath(output_dir, filename)
    CSV.write(path, df)
    return path, df
end

function computation_rows_for_case(case_output::AbstractDict)
    all_results = case_output[:all_results]
    computation = get(all_results, :computation, NamedTuple[])
    isempty(computation) && return NamedTuple[]

    return [
        merge(row, (
            case_name = case_output[:case_name],
            case_type = case_output[:case_type],
            case_wall_seconds = case_output[:case_wall_seconds],
        ))
        for row in computation
    ]
end

function finite_values(values)
    out = Float64[]
    for value in values
        if value !== missing
            v = Float64(value)
            isfinite(v) && push!(out, v)
        end
    end
    return out
end

function sys_info(name::Symbol)
    try
        return string(getfield(Sys, name))
    catch
        return "unknown"
    end
end

function computation_kpis(all_results::Dict, case_wall_seconds::Float64)
    computation = get(all_results, :computation, NamedTuple[])
    clearing_details = get(all_results, :clearing_details, Dict())
    executed_hours_total = sum(details[:executed_hours] for details in values(clearing_details))

    if isempty(computation)
        return (
            case_wall_seconds = case_wall_seconds,
            solver_wall_seconds = missing,
            mean_solve_seconds_per_clearing = missing,
            max_solve_seconds_per_clearing = missing,
            clearings_per_wall_second = missing,
        )
    end

    solve_seconds = finite_values(getproperty.(computation, :wall_solve_seconds))
    solver_total = isempty(solve_seconds) ? missing : sum(solve_seconds)
    return (
        case_wall_seconds = case_wall_seconds,
        solver_wall_seconds = solver_total,
        mean_solve_seconds_per_clearing = isempty(solve_seconds) ? missing : mean(solve_seconds),
        max_solve_seconds_per_clearing = isempty(solve_seconds) ? missing : maximum(solve_seconds),
        clearings_per_wall_second = case_wall_seconds > 0 ? length(computation) / case_wall_seconds : missing,
        executed_delivery_hours_per_wall_second = case_wall_seconds > 0 ? executed_hours_total / case_wall_seconds : missing,
    )
end

function save_computation_summary(case_outputs::AbstractVector{<:AbstractDict}, output_dir::AbstractString)
    ensure_dir(output_dir)
    rows = NamedTuple[]

    for case_output in case_outputs
        computation = get(case_output[:all_results], :computation, NamedTuple[])
        solve_seconds = finite_values(getproperty.(computation, :wall_solve_seconds))
        solver_reported = isempty(computation) ? Float64[] : finite_values(getproperty.(computation, :solver_reported_seconds))
        variable_counts = isempty(computation) ? Int[] : Int.(getproperty.(computation, :variables))
        constraint_values = isempty(computation) ? Any[] : collect(skipmissing(getproperty.(computation, :constraints)))
        clearing_details = get(case_output[:all_results], :clearing_details, Dict())
        executed_hours_total = sum(details[:executed_hours] for details in values(clearing_details))

        push!(rows, (
            case_name = case_output[:case_name],
            case_type = case_output[:case_type],
            look_ahead_h = Int(case_output[:cfg]["rolling_horizon"]["look_ahead_window"]),
            reclear_frequency_h = Int(case_output[:cfg]["rolling_horizon"]["reclear_frequency"]),
            executed_delivery_hours = executed_hours_total,
            clearings = length(computation),
            case_wall_seconds = case_output[:case_wall_seconds],
            solver_wall_seconds = isempty(solve_seconds) ? missing : sum(solve_seconds),
            solver_reported_seconds = isempty(solver_reported) ? missing : sum(solver_reported),
            mean_solve_seconds_per_clearing = isempty(solve_seconds) ? missing : mean(solve_seconds),
            median_solve_seconds_per_clearing = isempty(solve_seconds) ? missing : median(solve_seconds),
            max_solve_seconds_per_clearing = isempty(solve_seconds) ? missing : maximum(solve_seconds),
            solver_share_of_case_wall_time = (!isempty(solve_seconds) && case_output[:case_wall_seconds] > 0) ? sum(solve_seconds) / case_output[:case_wall_seconds] : missing,
            max_variables = isempty(variable_counts) ? missing : maximum(variable_counts),
            max_constraints = isempty(constraint_values) ? missing : maximum(Int.(constraint_values)),
            clearings_per_wall_second = case_output[:case_wall_seconds] > 0 ? length(computation) / case_output[:case_wall_seconds] : missing,
            executed_delivery_hours_per_wall_second = case_output[:case_wall_seconds] > 0 ? executed_hours_total / case_output[:case_wall_seconds] : missing,
        ))
    end

    df = DataFrame(rows)
    path = joinpath(output_dir, "computation_summary.csv")
    CSV.write(path, df)

    detail_rows = NamedTuple[]
    for case_output in case_outputs
        append!(detail_rows, computation_rows_for_case(case_output))
    end
    detail_path = joinpath(output_dir, "computation_detail.csv")
    CSV.write(detail_path, DataFrame(detail_rows))

    report_path = joinpath(output_dir, "computation_report.md")
    write_computation_report(report_path, df)
    return path, detail_path, report_path, df
end

function seconds_text(value)
    if value === missing
        return "n/a"
    end
    seconds = Float64(value)
    if seconds < 60
        return @sprintf("%.2f s", seconds)
    elseif seconds < 3600
        return @sprintf("%.1f min", seconds / 60)
    else
        return @sprintf("%.2f h", seconds / 3600)
    end
end

function write_computation_report(path::AbstractString, df::DataFrame)
    lines = String[]
    generated_at = Dates.format(now(), dateformat"yyyy-mm-dd HH:MM:SS")
    push!(lines, "# Computation Time and Computational Limits")
    push!(lines, "")
    push!(lines, "Generated: $(generated_at)")
    push!(lines, "")
    push!(lines, "## Run Environment")
    push!(lines, "- Julia version: $(VERSION)")
    push!(lines, "- CPU: $(sys_info(:CPU_NAME))")
    push!(lines, "- Julia threads: $(Threads.nthreads())")
    push!(lines, "- Machine: $(sys_info(:MACHINE))")
    push!(lines, "")
    push!(lines, "## Case-Level Timing")
    push!(lines, "")
    push!(lines, "case_name | clearings | executed_hours | case_wall_time | solver_wall_time | mean_solve_time | max_solve_time | max_variables | max_constraints")
    push!(lines, "--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---:")
    for row in eachrow(df)
        push!(lines, join([
            row.case_name,
            string(row.clearings),
            string(row.executed_delivery_hours),
            seconds_text(row.case_wall_seconds),
            seconds_text(row.solver_wall_seconds),
            seconds_text(row.mean_solve_seconds_per_clearing),
            seconds_text(row.max_solve_seconds_per_clearing),
            string(row.max_variables),
            string(row.max_constraints),
        ], " | "))
    end

    if nrow(df) > 0
        total_wall = sum(skipmissing(df.case_wall_seconds))
        total_solver = sum(skipmissing(df.solver_wall_seconds))
        max_case_idx = argmax(Float64.(df.case_wall_seconds))
        slowest = df[max_case_idx, :]
        push!(lines, "")
        push!(lines, "## Thesis Text Draft")
        push!(lines, "")
        push!(lines, "The complete case set required $(seconds_text(total_wall)) of wall-clock computation time on the machine reported above. Across cases, the optimization solver itself accounted for $(seconds_text(total_solver)); the remaining time is attributable to model construction, data preparation, result extraction, and output writing. The slowest case was `$(slowest.case_name)`, with $(slowest.clearings) sequential market clearings and a wall-clock runtime of $(seconds_text(slowest.case_wall_seconds)).")
        push!(lines, "")
        push!(lines, "Computationally, the experiment is limited mainly by the repeated solution of sequential linear market-clearing problems. Each clearing is modest in size, but longer look-ahead windows increase the number of time-indexed variables and constraints, while longer simulated periods increase the number of clearings. Because each clearing depends on the previous clearing through financial positions, generator states, and storage state of charge, the clearings within one case are solved sequentially rather than independently in parallel.")
        push!(lines, "")
        push!(lines, "The reported timings should therefore be interpreted as implementation- and hardware-specific rather than universal model properties. Scaling the analysis to finer time resolution, more network detail, stochastic scenario trees, integer unit-commitment decisions, or larger sensitivity sweeps would increase computation time and may require decomposition, parallel execution across independent cases, or a more selective scenario design.")
    end

    write(path, join(lines, "\n") * "\n")
    return path
end

function plot_case_metric_bars(df::DataFrame, output_path::AbstractString, metrics::Vector{Symbol};
                               title::AbstractString)
    case_names = String.(df.case_name)
    p = plot(layout=(length(metrics), 1), size=(1000, 320 * length(metrics)))

    for (idx, metric) in enumerate(metrics)
        values = Float64.(df[!, metric])
        bar!(
            p[idx],
            case_names,
            values,
            xlabel="Case",
            ylabel=String(metric),
            title=replace(String(metric), "_" => " "),
            legend=false,
            xrotation=20,
            color=:steelblue,
            alpha=0.8,
        )
    end

    plot!(p, plot_title=title)
    savefig(p, output_path)
    return p
end

function plot_thesis_comparison_figures(df::DataFrame, output_dir::AbstractString)
    ensure_dir(output_dir)

    system_metrics = [:social_welfare_eur_per_day, :generation_cost_eur_per_day, :wind_curtailment_mwh_per_day, :imbalance_mwh_per_day]
    storage_metrics = [:storage_charge_mwh_per_day, :storage_discharge_mwh_per_day, :storage_net_revenue_eur_per_day]

    p1 = plot_case_metric_bars(
        df,
        joinpath(output_dir, "system_kpis.png"),
        system_metrics;
        title="System Outcomes Across Cases",
    )
    p2 = plot_case_metric_bars(
        df,
        joinpath(output_dir, "storage_kpis.png"),
        storage_metrics;
        title="Storage Outcomes Across Cases",
    )

    return Dict(:system_kpis => p1, :storage_kpis => p2)
end

function case_output_map(case_outputs::AbstractVector{<:AbstractDict})
    return Dict(case_output[:case_name] => case_output for case_output in case_outputs)
end

function mean_storage_value(all_results::Dict)
    diag = thesis_collect_storage_value_diagnostics(all_results)
    values = diag[:all_marginal_values]
    return isempty(values) ? 0.0 : mean(values)
end

function plot_hourly_pair(values_left::Vector{Float64}, values_right::Vector{Float64},
                          label_left::AbstractString, label_right::AbstractString;
                          title::AbstractString, ylabel::AbstractString, kind::Symbol=:line)
    hours = 1:24
    combined_values = vcat(values_left, values_right)
    y_min = minimum(combined_values)
    y_max = maximum(combined_values)

    if kind == :bar
        extreme = max(abs(y_min), abs(y_max))
        ylims_pair = (-1.05 * extreme, 1.05 * extreme)
    else
        span = y_max - y_min
        padding = span > 0 ? 0.05 * span : max(1.0, 0.05 * max(abs(y_min), abs(y_max)))
        ylims_pair = (y_min - padding, y_max + padding)
    end

    if kind == :bar
        p_left = bar(hours, values_left, title=label_left, xlabel="Hour of Day", ylabel=ylabel,
                     color=:steelblue, alpha=0.8, legend=false, xlims=(1, 24))
        hline!(p_left, [0.0], color=:black, linewidth=1.0, label="")
        p_right = bar(hours, values_right, title=label_right, xlabel="Hour of Day", ylabel=ylabel,
                      color=:darkorange, alpha=0.8, legend=false, xlims=(1, 24))
        hline!(p_right, [0.0], color=:black, linewidth=1.0, label="")
    else
        p_left = plot(hours, values_left, title=label_left, xlabel="Hour of Day", ylabel=ylabel,
                      linewidth=3, marker=:circle, markersize=4, color=:steelblue, legend=false, xlims=(1, 24))
        p_right = plot(hours, values_right, title=label_right, xlabel="Hour of Day", ylabel=ylabel,
                       linewidth=3, marker=:circle, markersize=4, color=:darkorange, legend=false, xlims=(1, 24))
    end

    ylims!(p_left, ylims_pair)
    ylims!(p_right, ylims_pair)

    return plot(p_left, p_right, layout=(1, 2), size=(1600, 500), plot_title=title)
end

function plot_price_forecasts_for_day(all_results::Dict; day_of_month::Int=28, start_clearing_of_day::Int=1, num_clearings_to_show::Int=5, title_suffix::AbstractString="")
    clearing_details = all_results[:clearing_details]
    day_clearings = get_clearings_for_day(clearing_details, day_of_month)
    last_idx = min(length(day_clearings), start_clearing_of_day + num_clearings_to_show - 1)
    clearing_indices = day_clearings[start_clearing_of_day:last_idx]

    start_clearing = clearing_indices[1]
    start_global_hour = clearing_details[start_clearing][:current_hour]
    last_clearing = clearing_indices[end]
    end_global_hour = clearing_details[last_clearing][:current_hour] + clearing_details[last_clearing][:look_ahead] - 1

    line_styles = [:solid, :dash, :dot, :dashdot, :dashdotdot]
    markers = [:circle, :square, :diamond, :utriangle, :dtriangle]

    p = plot(
        xlabel="Global Hour",
        ylabel="Price (EUR/MWh)",
        title="Price Forecasts - 28/05$title_suffix",
        legend=:topright,
        linewidth=2.5,
        size=(900, 450),
    )

    for (idx, clearing_num) in enumerate(clearing_indices)
        details = clearing_details[clearing_num]
        clearing_start_hour = details[:current_hour]
        prices = details[:prices]
        global_hours = clearing_start_hour .+ ((1:length(prices)) .- 1)
        plot!(
            p,
            global_hours,
            prices,
            label="Clearing $clearing_num",
            linewidth=2.5,
            linestyle=line_styles[mod1(idx, length(line_styles))],
            marker=markers[mod1(idx, length(markers))],
            markersize=4,
            markerstrokewidth=0,
            alpha=0.85,
        )
    end

    xlims!(p, start_global_hour - 0.5, end_global_hour + 0.5)
    return p
end

function plot_position_changes_for_day(all_results::Dict; day_of_month::Int=28, start_clearing_of_day::Int=1, num_clearings_to_show::Int=5, title_suffix::AbstractString="")
    clearing_details = all_results[:clearing_details]
    day_clearings = get_clearings_for_day(clearing_details, day_of_month)
    last_idx = min(length(day_clearings), start_clearing_of_day + num_clearings_to_show - 1)
    clearing_indices = day_clearings[start_clearing_of_day:last_idx]
    num_selected_clearings = length(clearing_indices)
    start_clearing = clearing_indices[1]
    start_global_hour = clearing_details[start_clearing][:current_hour]
    last_clearing = clearing_indices[end]
    end_global_hour = clearing_details[last_clearing][:current_hour] + clearing_details[last_clearing][:look_ahead] - 1

    subplots = Any[]
    generators = ["Mid", "Wind"]

    for gen_name in generators
        ytick_labels = vcat(["q_prev"], ["C$c" for c in clearing_indices])
        p_gen = plot(
            title="$gen_name$title_suffix",
            xlabel="Global Hour",
            ylabel="Clearing",
            legend=false,
            size=(900, 320),
            yticks=(0:num_selected_clearings, ytick_labels),
            yflip=true,
            tickfontsize=7,
            guidefontsize=9,
            titlefontsize=11,
        )

        Q_prev_dict = clearing_details[start_clearing][:Q_prev]
        clearing_start_hour = clearing_details[start_clearing][:current_hour]
        look_ahead_hours = clearing_details[start_clearing][:look_ahead]
        for local_h in 1:look_ahead_hours
            global_h = clearing_start_hour + local_h - 1
            value = Q_prev_dict[(gen_name, local_h)]
            if value > 0.01
                plot!(p_gen, [global_h - 0.4, global_h + 0.4], [0, 0], fillrange=[0.4, 0.4],
                      fillcolor=:orange, fillalpha=0.6, linewidth=0)
                if value >= 10
                    annotate!(p_gen, global_h, 0, text(@sprintf("%.0f", value), 6, :black))
                end
            end
        end

        for (row_idx, clearing_num) in enumerate(clearing_indices)
            q_dict = clearing_details[clearing_num][:q]
            clearing_start_hour = clearing_details[clearing_num][:current_hour]
            look_ahead_hours = clearing_details[clearing_num][:look_ahead]
            for local_h in 1:look_ahead_hours
                global_h = clearing_start_hour + local_h - 1
                value = q_dict[gen_name, local_h]
                if abs(value) > 0.01
                    bar_color = value > 0 ? :lightgreen : :lightcoral
                    plot!(p_gen, [global_h - 0.4, global_h + 0.4], [row_idx, row_idx],
                          fillrange=[row_idx + 0.4, row_idx + 0.4], fillcolor=bar_color, fillalpha=0.7, linewidth=0)
                    sign_str = value > 0 ? "+" : ""
                    annotate!(p_gen, global_h, row_idx, text(@sprintf("%s%.0f", sign_str, value), 6, :black))
                end
            end
        end

        xlims!(p_gen, start_global_hour - 0.5, end_global_hour + 0.5)
        ylims!(p_gen, -0.5, num_selected_clearings + 0.5)
        push!(subplots, p_gen)
    end

    return plot(subplots..., layout=(2, 1), size=(1000, 700), plot_title="Position Changes - 28/05$title_suffix")
end

function plot_generation_mix_for_day(all_results::Dict; day_of_month::Int=28, start_clearing_of_day::Int=1, num_clearings_to_show::Int=3, title_suffix::AbstractString="")
    clearing_details = all_results[:clearing_details]
    dispatch_dict = all_results[:dispatch]
    day_clearings = get_clearings_for_day(clearing_details, day_of_month)
    last_idx = min(length(day_clearings), start_clearing_of_day + num_clearings_to_show - 1)
    clearing_indices = day_clearings[start_clearing_of_day:last_idx]

    gen_order = ["Base", "Mid", "Solar", "Wind", "Peak"]
    gen_colors_map = Dict("Base" => :steelblue, "Mid" => :lightblue, "Solar" => :yellow,
                          "Wind" => :lightgreen, "Peak" => :coral, "Discharge" => :gold)

    mix_plots = Any[]
    for clearing_num in clearing_indices
        gen_data = dispatch_dict[clearing_num]
        details = clearing_details[clearing_num]
        available_gens = filter(g -> g in keys(gen_data), gen_order)
        look_ahead_hours = details[:look_ahead]
        hours = 1:look_ahead_hours

        discharge_data = details[:discharging][1:look_ahead_hours]
        charging_data = details[:charging][1:look_ahead_hours]
        demand_base = details[:demand_base][1:look_ahead_hours]
        demand_flex = details[:demand_flex][1:look_ahead_hours]
        total_demand = demand_base .+ demand_flex
        total_demand_with_charging = total_demand .+ charging_data

        p_mix = plot(
            xlabel="Local Hour",
            ylabel="MW",
            title="Clearing $clearing_num$title_suffix",
            legend=:topright,
            size=(350, 450),
            tickfontsize=7,
            guidefontsize=9,
            titlefontsize=10,
            legendfontsize=6,
        )

        cumsum_prev = zeros(look_ahead_hours)
        for gen in available_gens
            gen_values = gen_data[gen][1:look_ahead_hours]
            cumsum_curr = cumsum_prev .+ gen_values
            plot!(p_mix, hours, cumsum_curr, fillrange=cumsum_prev, label=gen,
                  color=gen_colors_map[gen], alpha=0.8, linewidth=0)
            cumsum_prev = cumsum_curr
        end

        if maximum(discharge_data) > 0.1
            cumsum_discharge = cumsum_prev .+ discharge_data
            plot!(p_mix, hours, cumsum_discharge, fillrange=cumsum_prev, label="Discharge",
                  color=gen_colors_map["Discharge"], alpha=0.8, linewidth=0)
            cumsum_prev = cumsum_discharge
        end

        if maximum(charging_data) > 0.1
            plot!(p_mix, hours, total_demand_with_charging, label="Charging", color=:mediumpurple, linewidth=2)
        end
        plot!(p_mix, hours, total_demand, label="Demand", color=:black, linewidth=2)
        xlims!(p_mix, 0.5, look_ahead_hours + 0.5)
        push!(mix_plots, p_mix)
    end

    return plot(mix_plots..., layout=(1, length(mix_plots)), size=(1400, 450), plot_title="Generation Mix - 28/05$title_suffix")
end

function resolve_baseline_case_pair(case_map::Dict)
    if haskey(case_map, "Fixed 36h") && haskey(case_map, "Rolling 36h")
        return "Fixed 36h", "Rolling 36h"
    elseif haskey(case_map, "Fixed 24h") && haskey(case_map, "Rolling 24h")
        return "Fixed 24h", "Rolling 24h"
    end

    fixed_names = sort([String(name) for (name, case_output) in case_map if get(case_output, :case_type, nothing) == "fixed"])
    rolling_names = sort([String(name) for (name, case_output) in case_map if get(case_output, :case_type, nothing) == "rolling"])

    isempty(fixed_names) && error("Baseline figure set requires one fixed case.")
    isempty(rolling_names) && error("Baseline figure set requires one rolling case.")
    return first(fixed_names), first(rolling_names)
end

function save_baseline_market_design_figures(case_map::Dict, output_dir::AbstractString)
    ensure_dir(output_dir)
    fixed_name, rolling_name = resolve_baseline_case_pair(case_map)
    fixed_case = case_map[fixed_name]
    rolling_case = case_map[rolling_name]

    fixed_all = fixed_case[:all_results]
    rolling_all = rolling_case[:all_results]

    fixed_price_diag = thesis_collect_price_storage_timing_diagnostics(fixed_all)
    rolling_price_diag = thesis_collect_price_storage_timing_diagnostics(rolling_all)
    fixed_storage_diag = thesis_collect_storage_value_diagnostics(fixed_all)
    rolling_storage_diag = thesis_collect_storage_value_diagnostics(rolling_all)

    p1 = plot_hourly_pair(
        fixed_price_diag[:avg_price_by_hour],
        rolling_price_diag[:avg_price_by_hour],
        fixed_name,
        rolling_name;
        title="Average Executed Price by Hour of Day",
        ylabel="EUR/MWh",
        kind=:line,
    )
    savefig(p1, joinpath(output_dir, "baseline_01_avg_executed_price.png"))

    p2 = plot_hourly_pair(
        fixed_price_diag[:avg_net_discharge_by_hour],
        rolling_price_diag[:avg_net_discharge_by_hour],
        fixed_name,
        rolling_name;
        title="Average Battery Net Discharge by Hour of Day",
        ylabel="MWh",
        kind=:bar,
    )
    savefig(p2, joinpath(output_dir, "baseline_02_avg_net_discharge.png"))

    p3 = plot_hourly_pair(
        fixed_storage_diag[:avg_marginal_value_by_hour],
        rolling_storage_diag[:avg_marginal_value_by_hour],
        fixed_name,
        rolling_name;
        title="Average Marginal Value of Initial SOC by Hour of Day",
        ylabel="EUR/MWh",
        kind=:line,
    )
    savefig(p3, joinpath(output_dir, "baseline_03_avg_marginal_soc_value.png"))

    p4_left = plot_price_forecasts_for_day(fixed_all; day_of_month=28, num_clearings_to_show=5, title_suffix=" - $fixed_name")
    p4_right = plot_price_forecasts_for_day(rolling_all; day_of_month=28, num_clearings_to_show=5, title_suffix=" - $rolling_name")
    p4 = plot(p4_left, p4_right, layout=(1, 2), size=(1800, 500), plot_title="Price Forecasts on 28/05 Across 5 Clearings")
    savefig(p4, joinpath(output_dir, "baseline_04_price_forecast_28_05.png"))

    p5_left = plot_position_changes_for_day(fixed_all; day_of_month=28, num_clearings_to_show=5, title_suffix=" - $fixed_name")
    p5_right = plot_position_changes_for_day(rolling_all; day_of_month=28, num_clearings_to_show=5, title_suffix=" - $rolling_name")
    p5 = plot(p5_left, p5_right, layout=(1, 2), size=(2000, 800), plot_title="Position Changes on 28/05 Across 5 Clearings")
    savefig(p5, joinpath(output_dir, "baseline_05_position_changes_28_05.png"))

    p6_left = plot_generation_mix_for_day(fixed_all; day_of_month=28, num_clearings_to_show=3, title_suffix=" - $fixed_name")
    p6_right = plot_generation_mix_for_day(rolling_all; day_of_month=28, num_clearings_to_show=3, title_suffix=" - $rolling_name")
    p6 = plot(p6_left, p6_right, layout=(2, 1), size=(1600, 1000), plot_title="Generation Mix on 28/05 Across 3 Clearings")
    savefig(p6, joinpath(output_dir, "baseline_06_generation_mix_28_05.png"))

    return Dict(
        :avg_price => p1,
        :avg_net_discharge => p2,
        :avg_marginal_soc_value => p3,
        :price_forecast => p4,
        :position_changes => p5,
        :generation_mix => p6,
    )
end

function plot_metric_vs_lookahead(df::DataFrame, metrics::Vector{Symbol}, output_path::AbstractString; title::AbstractString)
    df_sorted = sort(df, :look_ahead_h)
    x = Int.(df_sorted.look_ahead_h)
    subplots = Any[]
    for metric in metrics
        y = Float64.(df_sorted[!, metric])
        p = plot(x, y, marker=:circle, linewidth=3, xlabel="Look-ahead (h)", ylabel=String(metric),
                 title=replace(String(metric), "_" => " "), legend=false, color=:steelblue)
        push!(subplots, p)
    end
    combined = plot(subplots..., layout=(length(metrics), 1), size=(900, 320 * length(metrics)), plot_title=title)
    savefig(combined, output_path)
    return combined
end

function plot_grouped_storage_metrics(df::DataFrame, output_path::AbstractString, metrics::Vector{Symbol}; title::AbstractString)
    labels = String.(df.case_name)
    p = plot(layout=(length(metrics), 1), size=(1000, 300 * length(metrics)), plot_title=title)
    for (idx, metric) in enumerate(metrics)
        values = Float64.(df[!, metric])
        bar!(p[idx], labels, values, xrotation=20, ylabel=String(metric), xlabel="Scenario",
             title=replace(String(metric), "_" => " "), legend=false, alpha=0.8, color=:steelblue)
    end
    savefig(p, output_path)
    return p
end

function save_foresight_figures(df::DataFrame, output_dir::AbstractString)
    ensure_dir(output_dir)
    foresight_names = ["Rolling 36h", "Rolling 48h", "Rolling 72h"]
    foresight_df = filter(row -> row.case_name in foresight_names, df)
    nrow(foresight_df) > 0 || error("Foresight figure set requires at least one of: $(join(foresight_names, ", ")).")

    p1 = plot_metric_vs_lookahead(
        foresight_df,
        [:social_welfare_eur_per_day, :generation_cost_eur_per_day, :wind_curtailment_mwh_per_day, :imbalance_mwh_per_day, :storage_net_revenue_eur_per_day],
        joinpath(output_dir, "foresight_01_kpis_vs_lookahead.png");
        title="Foresight Comparison: System and Storage KPIs",
    )

    p2 = plot_metric_vs_lookahead(
        foresight_df,
        [:storage_charge_mwh_per_day, :storage_discharge_mwh_per_day],
        joinpath(output_dir, "foresight_02_charge_discharge_vs_lookahead.png");
        title="Foresight Comparison: Storage Charge and Discharge",
    )

    return Dict(:kpis => p1, :charge_discharge => p2)
end

function save_high_storage_figures(case_map::Dict, df::DataFrame, output_dir::AbstractString)
    ensure_dir(output_dir)
    fixed_vs_rolling_names = ["High-storage Fixed 36h", "High-storage Rolling 36h"]
    lookahead_names = ["High-storage Rolling 36h", "High-storage Rolling 48h", "High-storage Rolling 72h"]
    fixed_vs_rolling_df = filter(row -> row.case_name in fixed_vs_rolling_names, df)
    lookahead_df = filter(row -> row.case_name in lookahead_names, df)
    nrow(fixed_vs_rolling_df) == 2 || error("High-storage figure set requires High-storage Fixed 36h and High-storage Rolling 36h.")
    nrow(lookahead_df) > 0 || error("High-storage figure set requires at least one high-storage rolling look-ahead case.")

    fixed_vs_rolling_dir = ensure_dir(joinpath(output_dir, "fixed_vs_rolling_36h"))
    fixed_vs_rolling_map = Dict(name => case_map[name] for name in fixed_vs_rolling_names)
    fixed_vs_rolling_outputs = save_baseline_market_design_figures(fixed_vs_rolling_map, fixed_vs_rolling_dir)

    p1 = plot_grouped_storage_metrics(
        fixed_vs_rolling_df,
        joinpath(output_dir, "high_storage_01_fixed_vs_rolling_charge_discharge_revenue.png"),
        [:storage_charge_mwh_per_day, :storage_discharge_mwh_per_day, :storage_net_revenue_eur_per_day];
        title="High-storage Fixed vs Rolling 36h: Charge, Discharge, and Revenue",
    )

    p2 = plot_grouped_storage_metrics(
        fixed_vs_rolling_df,
        joinpath(output_dir, "high_storage_02_fixed_vs_rolling_charge_discharge_prices.png"),
        [:avg_charging_price_eur_per_mwh, :avg_discharging_price_eur_per_mwh];
        title="High-storage Fixed vs Rolling 36h: Charging and Discharging Prices",
    )

    p3 = plot_metric_vs_lookahead(
        lookahead_df,
        [:social_welfare_eur_per_day, :generation_cost_eur_per_day, :wind_curtailment_mwh_per_day, :imbalance_mwh_per_day, :storage_net_revenue_eur_per_day],
        joinpath(output_dir, "high_storage_03_rolling_kpis_vs_lookahead.png");
        title="High-storage Rolling: System and Storage KPIs vs Look-ahead",
    )

    p4 = plot_metric_vs_lookahead(
        lookahead_df,
        [:storage_charge_mwh_per_day, :storage_discharge_mwh_per_day],
        joinpath(output_dir, "high_storage_04_rolling_charge_discharge_vs_lookahead.png");
        title="High-storage Rolling: Storage Charge and Discharge vs Look-ahead",
    )

    marginal_values = Float64[]
    present_names = String.(lookahead_df.case_name)
    for case_name in present_names
        push!(marginal_values, mean_storage_value(case_map[case_name][:all_results]))
    end
    p5 = bar(
        present_names,
        marginal_values,
        xrotation=20,
        ylabel="EUR/MWh",
        xlabel="Scenario",
        title="High-storage Rolling: Average Marginal Value of Initial SOC",
        legend=false,
        color=:steelblue,
        alpha=0.8,
        size=(900, 450),
    )
    savefig(p5, joinpath(output_dir, "high_storage_05_rolling_avg_marginal_soc_value.png"))

    return Dict(
        :fixed_vs_rolling_market_design => fixed_vs_rolling_outputs,
        :fixed_vs_rolling_charge_discharge_revenue => p1,
        :fixed_vs_rolling_charge_discharge_prices => p2,
        :rolling_kpis_vs_lookahead => p3,
        :rolling_charge_discharge_vs_lookahead => p4,
        :rolling_avg_marginal_soc_value => p5,
    )
end

function save_all_scenarios_summary_figure(case_map::Dict, df::DataFrame, output_dir::AbstractString)
    ensure_dir(output_dir)
    summary_df = deepcopy(df)
    summary_df[!, :avg_marginal_soc_value_eur_per_mwh] = [mean_storage_value(case_map[name][:all_results]) for name in summary_df.case_name]

    metrics = [
        :social_welfare_eur_per_day,
        :generation_cost_eur_per_day,
        :wind_curtailment_mwh_per_day,
        :imbalance_mwh_per_day,
        :storage_throughput_mwh_per_day,
        :storage_net_revenue_eur_per_day,
        :avg_marginal_soc_value_eur_per_mwh,
    ]

    p = plot_grouped_storage_metrics(
        summary_df,
        joinpath(output_dir, "all_scenarios_main_kpis.png"),
        metrics;
        title="All Scenarios: Main System and Storage KPIs",
    )
    return p
end

function generate_thesis_figure_set(case_outputs::AbstractVector{<:AbstractDict}, df::DataFrame, output_dir::AbstractString;
                                   figure_groups::Vector{String}=["baseline", "foresight", "high_storage", "all_scenarios"])
    ensure_dir(output_dir)
    c_map = case_output_map(case_outputs)
    outputs = Dict{Symbol, Any}()

    if "baseline" in figure_groups
        baseline_dir = ensure_dir(joinpath(output_dir, "baseline_market_design"))
        outputs[:baseline] = save_baseline_market_design_figures(c_map, baseline_dir)
    end
    if "foresight" in figure_groups
        foresight_dir = ensure_dir(joinpath(output_dir, "foresight_comparison"))
        outputs[:foresight] = save_foresight_figures(df, foresight_dir)
    end
    if "high_storage" in figure_groups
        high_storage_dir = ensure_dir(joinpath(output_dir, "high_storage"))
        outputs[:high_storage] = save_high_storage_figures(c_map, df, high_storage_dir)
    end
    if "all_scenarios" in figure_groups
        overall_dir = ensure_dir(joinpath(output_dir, "all_scenarios"))
        outputs[:overall] = save_all_scenarios_summary_figure(c_map, df, overall_dir)
    end

    return outputs
end

function apply_case_overrides(base_cfg::AbstractDict, case_def::AbstractDict)
    cfg = deepcopy(base_cfg)

    # Keep the original timing logic from the model scripts unless a case
    # explicitly opts into an override. In the normal thesis workflow this
    # should mainly be the rolling look-ahead length.
    if haskey(case_def, :look_ahead)
        cfg["rolling_horizon"]["look_ahead_window"] = case_def[:look_ahead]
    end
    if haskey(case_def, :fixed_horizon_min_window)
        cfg["rolling_horizon"]["fixed_horizon_min_window"] = case_def[:fixed_horizon_min_window]
    end
    if haskey(case_def, :reclear_frequency)
        cfg["rolling_horizon"]["reclear_frequency"] = case_def[:reclear_frequency]
    end
    if haskey(case_def, :gate_closure)
        cfg["rolling_horizon"]["gate_closure"] = case_def[:gate_closure]
    end
    if haskey(case_def, :forecast_noise_std)
        cfg["rolling_horizon"]["forecast_noise_std"] = case_def[:forecast_noise_std]
    end
    if haskey(case_def, :wind_noise_seed)
        cfg["rolling_horizon"]["wind_noise_seed"] = Int(case_def[:wind_noise_seed])
    end
    if haskey(case_def, :wind_noise_scenario_path)
        cfg["rolling_horizon"]["wind_noise_scenario_path"] = String(case_def[:wind_noise_scenario_path])
    end
    if haskey(case_def, :random_seed)
        cfg["rolling_horizon"]["random_seed"] = Int(case_def[:random_seed])
    end
    if haskey(case_def, :comparable_delivery_hours_override)
        cfg["rolling_horizon"]["comparable_delivery_hours_override"] = case_def[:comparable_delivery_hours_override]
    end
    if haskey(case_def, :battery_energy_capacity)
        cfg["batteryStorage"]["energyCapacity"] = case_def[:battery_energy_capacity]
    end
    if haskey(case_def, :battery_power_capacity)
        cfg["batteryStorage"]["powerCapacity"] = case_def[:battery_power_capacity]
    end
    if haskey(case_def, :battery_initial_soc)
        cfg["batteryStorage"]["initialSOC"] = case_def[:battery_initial_soc]
    end
    if haskey(case_def, :ramp_rate_override)
        for (gen_name, gen_data) in cfg["dispatchableGenerators"]
            gen_data["rampRate"] = case_def[:ramp_rate_override]
            cfg["dispatchableGenerators"][gen_name] = gen_data
        end
    end

    apply_simulation_month!(cfg)
    return cfg
end

function run_rolling_case(cfg::Dict;
                          output_dir::AbstractString=".",
                          plot_selection::Dict=Dict{Symbol, Bool}(),
                          display_plots::Bool=false,
                          verbose::Bool=true)
    run_module = Module(gensym(:RollingCaseRun))
    results_ref = Ref{Any}(nothing)
    cfg_ref = Ref{Any}(nothing)
    Core.eval(run_module, :(include(path::AbstractString) = Base.include(@__MODULE__, path)))
    Core.eval(run_module, :(const MARKET_CLEARING_CFG_OVERRIDE = $cfg))
    Core.eval(run_module, :(const MARKET_CLEARING_OUTPUT_DIR = $output_dir))
    Core.eval(run_module, :(const MARKET_CLEARING_PLOT_SELECTION = $plot_selection))
    Core.eval(run_module, :(const MARKET_CLEARING_DISPLAY_PLOTS = $display_plots))
    Core.eval(run_module, :(const MARKET_CLEARING_SKIP_PLOTS = true))
    Core.eval(run_module, :(const MARKET_CLEARING_RESULTS_REF = $results_ref))
    Core.eval(run_module, :(const MARKET_CLEARING_CFG_REF = $cfg_ref))
    Core.eval(run_module, :(print_battery_diagnostics(all_results) = nothing))
    runner_path = normpath(joinpath(@__DIR__, "..", "market_clearing_rolling.jl"))

    if verbose
        Base.include(run_module, runner_path)
    else
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                Base.include(run_module, runner_path)
            end
        end
    end

    results_ref[] === nothing && error("Rolling wrapper did not populate MARKET_CLEARING_RESULTS_REF.")
    cfg_ref[] === nothing && error("Rolling wrapper did not populate MARKET_CLEARING_CFG_REF.")
    return results_ref[], cfg_ref[]
end

function run_fixed_case(cfg::Dict;
                        output_dir::AbstractString=".",
                        plot_selection::Dict=Dict{Symbol, Bool}(),
                        display_plots::Bool=false,
                        verbose::Bool=true,
                        runner_variant::AbstractString="continuous")
    run_module = Module(gensym(:FixedCaseRun))
    results_ref = Ref{Any}(nothing)
    cfg_ref = Ref{Any}(nothing)
    Core.eval(run_module, :(include(path::AbstractString) = Base.include(@__MODULE__, path)))
    Core.eval(run_module, :(const MARKET_CLEARING_CFG_OVERRIDE = $cfg))
    Core.eval(run_module, :(const MARKET_CLEARING_OUTPUT_DIR = $output_dir))
    Core.eval(run_module, :(const MARKET_CLEARING_PLOT_SELECTION = $plot_selection))
    Core.eval(run_module, :(const MARKET_CLEARING_DISPLAY_PLOTS = $display_plots))
    Core.eval(run_module, :(const MARKET_CLEARING_SKIP_PLOTS = true))
    Core.eval(run_module, :(const MARKET_CLEARING_RESULTS_REF = $results_ref))
    Core.eval(run_module, :(const MARKET_CLEARING_CFG_REF = $cfg_ref))
    Core.eval(run_module, :(print_battery_diagnostics(all_results) = nothing))
    runner_filename =
        runner_variant == "continuous" ? "market_clearing_fixed_continuous.jl" :
        runner_variant == "original_24h" ? "market_clearing_fixed.jl" :
        error("Unsupported fixed runner variant: $runner_variant")
    runner_path = normpath(joinpath(@__DIR__, "..", runner_filename))

    if verbose
        Base.include(run_module, runner_path)
    else
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                Base.include(run_module, runner_path)
            end
        end
    end

    results_ref[] === nothing && error("Fixed wrapper did not populate MARKET_CLEARING_RESULTS_REF.")
    cfg_ref[] === nothing && error("Fixed wrapper did not populate MARKET_CLEARING_CFG_REF.")
    return results_ref[], cfg_ref[]
end

function run_case(case_def::AbstractDict, base_cfg::AbstractDict, output_root::AbstractString;
                  save_results::Bool=true,
                  save_excel_summary::Bool=true,
                  display_plots::Bool=false,
                  verbose::Bool=true)
    case_name = String(case_def[:name])
    case_type = String(case_def[:mode])
    cfg = apply_case_overrides(base_cfg, case_def)
    case_dir = joinpath(output_root, sanitize_case_name(case_name))
    ensure_dir(case_dir)

    if verbose
        println()
        println("="^80)
        println("Running case: $case_name")
        println("="^80)
        if haskey(cfg["rolling_horizon"], "random_seed")
            println("Random seed: $(cfg["rolling_horizon"]["random_seed"])")
        end
        if haskey(cfg["rolling_horizon"], "comparable_delivery_hours_override")
            println("Comparable delivery hours override: $(cfg["rolling_horizon"]["comparable_delivery_hours_override"])")
        end
    end

    if haskey(cfg["rolling_horizon"], "random_seed")
        Random.seed!(Int(cfg["rolling_horizon"]["random_seed"]))
    end

    case_wall_start = time()
    all_results, cfg_used =
        case_type == "rolling" ? run_rolling_case(
            cfg;
            output_dir=case_dir,
            plot_selection=disabled_script_plot_selection(),
            display_plots=display_plots,
            verbose=verbose,
        ) :
        case_type == "fixed" ? run_fixed_case(
            cfg;
            output_dir=case_dir,
            plot_selection=disabled_script_plot_selection(),
            display_plots=display_plots,
            verbose=verbose,
            runner_variant=get(case_def, :runner_variant, "continuous"),
        ) :
        error("Unsupported case mode: $case_type")
    case_wall_seconds = time() - case_wall_start
    all_results[:run_metadata] = Dict(
        :case_wall_seconds => case_wall_seconds,
        :completed_at => Dates.format(now(), dateformat"yyyy-mm-dd HH:MM:SS"),
        :julia_version => string(VERSION),
        :cpu_name => sys_info(:CPU_NAME),
        :julia_threads => Threads.nthreads(),
    )

    kpis = merge(collect_case_kpis(case_name, case_type, all_results, cfg_used),
                 computation_kpis(all_results, case_wall_seconds))

    if save_results || save_excel_summary
        save_case_artifacts(
            all_results, cfg_used, case_dir;
            plot_selection=Dict{Symbol, Bool}(),
            save_results=save_results,
            save_excel_summary=save_excel_summary,
            display_plots=display_plots,
        )
    end

    return Dict(
        :case_name => case_name,
        :case_type => case_type,
        :cfg => cfg_used,
        :all_results => all_results,
        :kpis => kpis,
        :case_dir => case_dir,
        :case_wall_seconds => case_wall_seconds,
    )
end

function run_thesis_cases(case_defs::AbstractVector{<:AbstractDict};
                          cfg_path::AbstractString="input_data_rolling.yaml",
                          output_root::AbstractString=joinpath("Results", "thesis_runs"),
                          save_results::Bool=true,
                          save_excel_summary::Bool=true,
                          run_daily_driver_analysis::Bool=false,
                          save_comparison_plots::Bool=true,
                          comparison_groups::Vector{String}=["baseline", "foresight", "high_storage", "all_scenarios"],
                          display_plots::Bool=false,
                          verbose::Bool=true)
    base_cfg = YAML.load_file(cfg_path)
    apply_simulation_month!(base_cfg)

    ensure_dir(output_root)

    # Compute a shared comparable delivery-hours override so all cases execute
    # the same number of delivered hours (and therefore the same number of
    # clearings). This avoids differences coming from per-run horizon math.
    candidates = Int[]
    for case_def in case_defs
        cfg_candidate = apply_case_overrides(base_cfg, case_def)
        push!(candidates, calculate_comparable_delivery_hours(cfg_candidate))
    end
    common_delivery_hours = minimum(candidates)
    if verbose
        println("Using common comparable_delivery_hours_override = $common_delivery_hours for all cases to ensure comparable clearings")
    end
    # Apply override to all case definitions (overwrites any explicit value)
    for case_def in case_defs
        case_def[:comparable_delivery_hours_override] = common_delivery_hours
    end

    case_outputs = Vector{Dict}(undef, length(case_defs))
    kpi_rows = NamedTuple[]

    for (idx, case_def) in enumerate(case_defs)
        case_output = run_case(
            case_def,
            base_cfg,
            output_root;
            save_results=save_results,
            save_excel_summary=save_excel_summary,
            display_plots=display_plots,
            verbose=verbose,
        )
        case_outputs[idx] = case_output
        push!(kpi_rows, case_output[:kpis])
    end

    summary_dir = ensure_dir(joinpath(output_root, "_summary"))
    kpi_path, df = save_kpi_summary(kpi_rows, summary_dir)
    computation_path, computation_detail_path, computation_report_path, computation_table =
        save_computation_summary(case_outputs, summary_dir)
    daily_summary_path = export_daily_summary_to_excel(case_outputs; path=joinpath(summary_dir, "summary_daily.xlsx"))
    daily_driver_analysis =
        run_daily_driver_analysis ? run_embedded_daily_driver_analysis(summary_dir; verbose=verbose) : Dict{Symbol, Any}()

    comparison_plots = save_comparison_plots ? generate_thesis_figure_set(case_outputs, df, summary_dir; figure_groups=comparison_groups) : Dict{Symbol, Any}()

    return Dict(
        :cases => case_outputs,
        :kpi_table => df,
        :kpi_path => kpi_path,
        :computation_table => computation_table,
        :computation_path => computation_path,
        :computation_detail_path => computation_detail_path,
        :computation_report_path => computation_report_path,
        :daily_summary_path => daily_summary_path,
        :daily_driver_analysis => daily_driver_analysis,
        :summary_dir => summary_dir,
        :comparison_plots => comparison_plots,
    )
end

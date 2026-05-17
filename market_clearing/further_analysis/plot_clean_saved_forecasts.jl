using Serialization
using Plots
using Statistics

# Standalone figure builder for saved thesis-run outputs.
# It recreates cleaner versions of the price-forecast and position-change figures
# directly from serialized all_results/cfg files, so no rerun is needed.

const RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260320_205737_withstoragestory")
const CASE_FOLDERS = Dict(
    "Fixed 36h" => "fixed_36h",
    "Rolling 36h" => "rolling_36h",
)
const DAY_OF_MONTH = 28
const START_CLEARING_OF_DAY = 1
const NUM_CLEARINGS_TO_SHOW = 5
const POSITION_GENERATORS = ["Mid", "Wind"]
const POSITION_LABEL_THRESHOLD = 150.0
const POSITION_LABEL_FONTSIZE = 6
const REPRESENTATIVE_DAYS_TO_SHOW = 3

function load_case(run_dir::AbstractString, case_folder::AbstractString)
    case_dir = joinpath(run_dir, case_folder)
    all_results = deserialize(joinpath(case_dir, "all_results.jls"))
    cfg = deserialize(joinpath(case_dir, "cfg.jls"))
    return all_results, cfg
end

function collect_avg_net_discharge_by_hour(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    avg_net_discharge = zeros(Float64, 24)
    hour_counts = zeros(Int, 24)

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        start_hour = details[:current_hour]

        for h in 1:executed_hours
            global_hour = start_hour + h - 1
            hour_of_day = mod(global_hour - 1, 24) + 1
            net_discharge = details[:discharging][h] - details[:charging][h]
            avg_net_discharge[hour_of_day] += net_discharge
            hour_counts[hour_of_day] += 1
        end
    end

    return [hour_counts[h] > 0 ? avg_net_discharge[h] / hour_counts[h] : 0.0 for h in 1:24]
end

function collect_avg_executed_price_by_hour(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    avg_price = zeros(Float64, 24)
    hour_counts = zeros(Int, 24)

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        start_hour = details[:current_hour]

        for h in 1:executed_hours
            global_hour = start_hour + h - 1
            hour_of_day = mod(global_hour - 1, 24) + 1
            avg_price[hour_of_day] += details[:prices][h]
            hour_counts[hour_of_day] += 1
        end
    end

    return [hour_counts[h] > 0 ? avg_price[h] / hour_counts[h] : 0.0 for h in 1:24]
end

function collect_avg_marginal_soc_value_by_hour(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    avg_value = zeros(Float64, 24)
    hour_counts = zeros(Int, 24)

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        hour_of_day = mod(details[:current_hour] - 1, 24) + 1
        marginal_value = -details[:storage_initial_soc_dual]
        avg_value[hour_of_day] += marginal_value
        hour_counts[hour_of_day] += 1
    end

    return [hour_counts[h] > 0 ? avg_value[h] / hour_counts[h] : 0.0 for h in 1:24]
end

function collect_executed_soc_by_day(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    num_days = Int(floor(sum(details[:executed_hours] for details in values(clearing_details)) / 24))
    daily_soc = [fill(NaN, 24) for _ in 1:num_days]

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        start_hour = details[:current_hour]
        executed_hours = details[:executed_hours]

        for h in 1:executed_hours
            global_hour = start_hour + h - 1
            day_idx = Int(fld(global_hour - 1, 24)) + 1
            hour_of_day = mod(global_hour - 1, 24) + 1
            day_idx <= num_days || continue
            daily_soc[day_idx][hour_of_day] = details[:storage_soc_end_executed]
        end
    end

    return daily_soc
end

function collect_daily_throughput(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    num_days = Int(floor(sum(details[:executed_hours] for details in values(clearing_details)) / 24))
    daily_throughput = zeros(Float64, num_days)

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        start_hour = details[:current_hour]
        executed_hours = details[:executed_hours]

        for h in 1:executed_hours
            global_hour = start_hour + h - 1
            day_idx = Int(fld(global_hour - 1, 24)) + 1
            day_idx <= num_days || continue
            daily_throughput[day_idx] += details[:charging][h] + details[:discharging][h]
        end
    end

    return daily_throughput
end

function representative_day_indices(fixed_results::Dict, rolling_results::Dict; max_days::Int=3)
    fixed_throughput = collect_daily_throughput(fixed_results)
    rolling_throughput = collect_daily_throughput(rolling_results)
    num_days = min(length(fixed_throughput), length(rolling_throughput))
    num_days > 0 || error("No complete executed days available for representative-day selection.")

    deltas = fixed_throughput[1:num_days] .- rolling_throughput[1:num_days]
    day_indices = Int[]

    push!(day_indices, argmax(deltas))
    push!(day_indices, argmin(deltas))

    remaining = setdiff(1:num_days, day_indices)
    if !isempty(remaining)
        typical_day = remaining[argmin(abs.(deltas[remaining]))]
        push!(day_indices, typical_day)
    end

    unique_days = unique(day_indices)
    unique_days = [day == 7 ? 2 : day for day in unique_days]
    unique_days = unique(unique_days)

    if !isempty(unique_days)
        if length(unique_days) >= 3
            unique_days[3] = 28
        else
            push!(unique_days, 28)
        end
        unique_days = unique_days[1:min(max_days, length(unique_days))]
    end
    return unique_days[1:min(max_days, length(unique_days))]
end

function plot_representative_soc_trajectories(fixed_results::Dict, rolling_results::Dict;
                                              fixed_label::AbstractString="Fixed 36h",
                                              rolling_label::AbstractString="Rolling 36h")
    fixed_soc = collect_executed_soc_by_day(fixed_results)
    rolling_soc = collect_executed_soc_by_day(rolling_results)
    day_indices = representative_day_indices(fixed_results, rolling_results; max_days=REPRESENTATIVE_DAYS_TO_SHOW)
    hours = 1:24

    combined_values = Float64[]
    for day_idx in day_indices
        append!(combined_values, filter(!isnan, fixed_soc[day_idx]))
        append!(combined_values, filter(!isnan, rolling_soc[day_idx]))
    end
    y_max = isempty(combined_values) ? 1.0 : 1.05 * maximum(combined_values)

    panels = Any[]
    for day_idx in day_indices
        p_left = plot(
            hours,
            fixed_soc[day_idx],
            color=:steelblue,
            linewidth=2.5,
            marker=:circle,
            markersize=4,
            xlabel="Hour of Day",
            ylabel="SOC (MWh)",
            title="$fixed_label - Day $day_idx",
            legend=false,
            xlims=(1, 24),
            ylims=(0, y_max),
            bottom_margin=10Plots.mm,
            left_margin=16Plots.mm,
            top_margin=6Plots.mm,
        )

        p_right = plot(
            hours,
            rolling_soc[day_idx],
            color=:darkorange,
            linewidth=2.5,
            marker=:circle,
            markersize=4,
            xlabel="Hour of Day",
            ylabel="SOC (MWh)",
            title="$rolling_label - Day $day_idx",
            legend=false,
            xlims=(1, 24),
            ylims=(0, y_max),
            bottom_margin=10Plots.mm,
            left_margin=12Plots.mm,
            top_margin=6Plots.mm,
        )

        push!(panels, p_left, p_right)
    end

    return plot(
        panels...,
        layout=grid(length(day_indices), 2, vgap=10Plots.mm, hgap=6Plots.mm),
        size=(1500, 390 * length(day_indices)),
        left_margin=10Plots.mm,
        right_margin=6Plots.mm,
        top_margin=8Plots.mm,
        bottom_margin=6Plots.mm,
        plot_title="Battery SOC Trajectories for Representative Days",
    )
end

function difference_panel(hours, values, title_text, ylabel_text; color=:firebrick)
    extreme = maximum(abs.(values))
    y_pad = extreme > 0 ? 1.1 * extreme : 1.0

    p = bar(
        hours,
        values,
        color=color,
        alpha=0.85,
        xlabel="Hour of Day",
        ylabel=ylabel_text,
        title=title_text,
        legend=false,
        xlims=(1, 24),
        ylims=(-y_pad, y_pad),
    )
    hline!(p, [0.0], color=:black, linewidth=1.0, label="")
    return p
end

function plot_fixed_minus_rolling_hourly_differences(fixed_results::Dict, rolling_results::Dict)
    hours = 1:24
    price_delta = collect_avg_executed_price_by_hour(fixed_results) .- collect_avg_executed_price_by_hour(rolling_results)
    net_discharge_delta = collect_avg_net_discharge_by_hour(fixed_results) .- collect_avg_net_discharge_by_hour(rolling_results)
    marginal_soc_value_delta = collect_avg_marginal_soc_value_by_hour(fixed_results) .- collect_avg_marginal_soc_value_by_hour(rolling_results)

    p1 = difference_panel(hours, price_delta, "Executed Price", "EUR/MWh")
    p2 = difference_panel(hours, net_discharge_delta, "Net Battery Discharge", "MWh")
    p3 = difference_panel(hours, marginal_soc_value_delta, "Marginal SOC Value", "EUR/MWh")

    return plot(
        p1,
        p2,
        p3,
        layout=(1, 3),
        size=(1800, 520),
        plot_title="Fixed - Rolling Differences by Hour of Day",
    )
end

function plot_avg_net_discharge_pair(left_values::Vector{Float64}, right_values::Vector{Float64},
                                     left_label::AbstractString, right_label::AbstractString)
    hours = 1:24
    combined_values = vcat(left_values, right_values)
    extreme = maximum(abs.(combined_values))
    y_pad = extreme > 0 ? 1.05 * extreme : 1.0
    shared_ylims = (-y_pad, y_pad)

    p_left = bar(
        hours,
        left_values,
        title=left_label,
        xlabel="Hour of Day",
        ylabel="MWh",
        color=:steelblue,
        alpha=0.8,
        legend=false,
        xlims=(1, 24),
        ylims=shared_ylims,
        size=(780, 450),
    )
    hline!(p_left, [0.0], color=:black, linewidth=1.0, label="")

    p_right = bar(
        hours,
        right_values,
        title=right_label,
        xlabel="Hour of Day",
        ylabel="MWh",
        color=:darkorange,
        alpha=0.8,
        legend=false,
        xlims=(1, 24),
        ylims=shared_ylims,
        size=(780, 450),
    )
    hline!(p_right, [0.0], color=:black, linewidth=1.0, label="")

    return plot(
        p_left,
        p_right,
        layout=(1, 2),
        size=(1600, 500),
        plot_title="Average Battery Net Discharge by Hour of Day",
    )
end

function get_clearings_for_day(clearing_details::Dict, day_of_month::Int)
    day_start_hour = (day_of_month - 1) * 24 + 1
    day_end_hour = day_of_month * 24
    clearing_indices = sort(collect(keys(clearing_details)))
    return [c for c in clearing_indices if day_start_hour <= clearing_details[c][:current_hour] <= day_end_hour]
end

function selected_clearings(clearing_details::Dict; day_of_month::Int, start_clearing_of_day::Int, num_clearings_to_show::Int)
    day_clearings = get_clearings_for_day(clearing_details, day_of_month)
    isempty(day_clearings) && error("No clearings found for day $day_of_month.")
    start_clearing_of_day <= length(day_clearings) || error("start_clearing_of_day is out of range for day $day_of_month.")
    last_idx = min(length(day_clearings), start_clearing_of_day + num_clearings_to_show - 1)
    return day_clearings[start_clearing_of_day:last_idx]
end

function global_hour_window(clearing_details::Dict, clearing_indices::Vector{Int})
    first_clearing = clearing_indices[1]
    last_clearing = clearing_indices[end]
    start_global_hour = clearing_details[first_clearing][:current_hour]
    end_global_hour = clearing_details[last_clearing][:current_hour] + clearing_details[last_clearing][:look_ahead] - 1
    return start_global_hour, end_global_hour
end

function clean_price_forecast_plot(all_results::Dict; day_of_month::Int, start_clearing_of_day::Int, num_clearings_to_show::Int, title_suffix::AbstractString="")
    clearing_details = all_results[:clearing_details]
    clearing_indices = selected_clearings(
        clearing_details;
        day_of_month=day_of_month,
        start_clearing_of_day=start_clearing_of_day,
        num_clearings_to_show=num_clearings_to_show,
    )
    start_global_hour, end_global_hour = global_hour_window(clearing_details, clearing_indices)

    p = plot(
        xlabel="Global Hour",
        ylabel="Price (EUR/MWh)",
        title="Prices$title_suffix",
        legend=:top,
        legend_column=1,
        linewidth=2.5,
        size=(1100, 430),
        left_margin=14Plots.mm,
        right_margin=8Plots.mm,
        top_margin=8Plots.mm,
        bottom_margin=8Plots.mm,
    )

    line_styles = [:solid, :dash, :dot, :dashdot, :dashdotdot]
    markers = [:circle, :square, :diamond, :utriangle, :dtriangle]

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

    plot!(p, legend_position=(0.66, 0.98))
    xlims!(p, start_global_hour - 0.5, end_global_hour + 0.5)
    return p
end

function single_position_plot(clearing_details::Dict, clearing_indices::Vector{Int}, gen_name::AbstractString, title_suffix::AbstractString)
    start_global_hour, end_global_hour = global_hour_window(clearing_details, clearing_indices)
    num_selected_clearings = length(clearing_indices)
    ytick_labels = vcat(["q_prev"], ["C$c" for c in clearing_indices])

    p = plot(
        title="$gen_name$title_suffix",
        xlabel="Global Hour",
        ylabel="Clearing",
        legend=false,
        size=(1100, 300),
        yticks=(0:num_selected_clearings, ytick_labels),
        yflip=true,
        tickfontsize=7,
        guidefontsize=10,
        titlefontsize=13,
        left_margin=14Plots.mm,
        right_margin=8Plots.mm,
        top_margin=8Plots.mm,
        bottom_margin=8Plots.mm,
    )

    first_clearing = clearing_indices[1]
    Q_prev_dict = clearing_details[first_clearing][:Q_prev]
    clearing_start_hour = clearing_details[first_clearing][:current_hour]
    look_ahead_hours = clearing_details[first_clearing][:look_ahead]
    for local_h in 1:look_ahead_hours
        global_h = clearing_start_hour + local_h - 1
        value = Q_prev_dict[(gen_name, local_h)]
        if value > 0.01
            plot!(
                p,
                [global_h - 0.4, global_h + 0.4],
                [0, 0],
                fillrange=[0.4, 0.4],
                fillcolor=:orange,
                fillalpha=0.6,
                linecolor=:white,
                linewidth=0.6,
                label="",
            )
            if value >= POSITION_LABEL_THRESHOLD
                annotate!(p, global_h, 0, Plots.text(string(round(Int, value)), POSITION_LABEL_FONTSIZE, :black, :center))
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
                plot!(
                    p,
                    [global_h - 0.4, global_h + 0.4],
                    [row_idx, row_idx],
                    fillrange=[row_idx + 0.4, row_idx + 0.4],
                    fillcolor=bar_color,
                    fillalpha=0.7,
                    linecolor=:white,
                    linewidth=0.6,
                    label="",
                )
                if abs(value) >= POSITION_LABEL_THRESHOLD
                    sign_str = value > 0 ? "+" : ""
                    annotate!(p, global_h, row_idx, Plots.text("$(sign_str)$(round(Int, value))", POSITION_LABEL_FONTSIZE, :black, :center))
                end
            end
        end
    end

    xlims!(p, start_global_hour - 0.5, end_global_hour + 0.5)
    ylims!(p, -0.5, num_selected_clearings + 0.5)
    return p
end

function clean_position_plots(all_results::Dict; generators::Vector{String}, day_of_month::Int, start_clearing_of_day::Int, num_clearings_to_show::Int, title_suffix::AbstractString="")
    clearing_details = all_results[:clearing_details]
    clearing_indices = selected_clearings(
        clearing_details;
        day_of_month=day_of_month,
        start_clearing_of_day=start_clearing_of_day,
        num_clearings_to_show=num_clearings_to_show,
    )

    panels = Any[]
    for gen_name in generators
        push!(panels, single_position_plot(clearing_details, clearing_indices, gen_name, title_suffix))
    end

    return panels
end

function save_case_plots(run_dir::AbstractString, case_name::AbstractString, case_folder::AbstractString)
    all_results, _ = load_case(run_dir, case_folder)
    output_dir = joinpath(run_dir, "_clean_saved_plots")
    isdir(output_dir) || mkpath(output_dir)

    title_suffix = " - $case_name (Day $DAY_OF_MONTH)"
    price_plot = clean_price_forecast_plot(
        all_results;
        day_of_month=DAY_OF_MONTH,
        start_clearing_of_day=START_CLEARING_OF_DAY,
        num_clearings_to_show=NUM_CLEARINGS_TO_SHOW,
        title_suffix=title_suffix,
    )

    position_panels = clean_position_plots(
        all_results;
        generators=POSITION_GENERATORS,
        day_of_month=DAY_OF_MONTH,
        start_clearing_of_day=START_CLEARING_OF_DAY,
        num_clearings_to_show=NUM_CLEARINGS_TO_SHOW,
        title_suffix=title_suffix,
    )

    combined_plot = plot(
        price_plot,
        position_panels...,
        layout=grid(3, 1, heights=[0.42, 0.29, 0.29]),
        size=(1150, 1160),
        margin=3Plots.mm,
    )

    base_name = replace(lowercase(case_name), " " => "_")
    combined_path = joinpath(output_dir, base_name * "_clean_prices_positions.png")
    savefig(combined_plot, combined_path)

    println("Saved $case_name combined plot to: $combined_path")
end

function main()
    isdir(RUN_DIR) || error("Run directory not found: $RUN_DIR")
    loaded_cases = Dict{String, Dict}()
    for (case_name, case_folder) in CASE_FOLDERS
        save_case_plots(RUN_DIR, case_name, case_folder)
        all_results, cfg = load_case(RUN_DIR, case_folder)
        loaded_cases[case_name] = Dict(:all_results => all_results, :cfg => cfg)
    end

    output_dir = joinpath(RUN_DIR, "_clean_saved_plots")
    fixed_values = collect_avg_net_discharge_by_hour(loaded_cases["Fixed 36h"][:all_results])
    rolling_values = collect_avg_net_discharge_by_hour(loaded_cases["Rolling 36h"][:all_results])
    avg_net_discharge_plot = plot_avg_net_discharge_pair(
        fixed_values,
        rolling_values,
        "Fixed 36h",
        "Rolling 36h",
    )
    savefig(avg_net_discharge_plot, joinpath(output_dir, "avg_battery_net_discharge_shared_axis.png"))

    soc_trajectories_plot = plot_representative_soc_trajectories(
        loaded_cases["Fixed 36h"][:all_results],
        loaded_cases["Rolling 36h"][:all_results];
        fixed_label="Fixed 36h",
        rolling_label="Rolling 36h",
    )
    savefig(soc_trajectories_plot, joinpath(output_dir, "representative_day_soc_trajectories.png"))

    delta_plot = plot_fixed_minus_rolling_hourly_differences(
        loaded_cases["Fixed 36h"][:all_results],
        loaded_cases["Rolling 36h"][:all_results],
    )
    savefig(delta_plot, joinpath(output_dir, "fixed_minus_rolling_hourly_differences.png"))

    println("Clean saved-result plots written under: $(joinpath(RUN_DIR, "_clean_saved_plots"))")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

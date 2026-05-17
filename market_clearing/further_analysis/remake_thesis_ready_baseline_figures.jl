using Serialization
using Plots
using StatsPlots
using Printf
using YAML
using JuMP
using HiGHS
using Random
using Statistics
using Distributions
using CSV
using DataFrames

const DEFAULT_RUN_DIR = joinpath("Results", "thesis_runs", "baseline_20260505_162324_seedA")
const DEFAULT_OUTPUT_DIR = joinpath(DEFAULT_RUN_DIR, "_summary", "thesis_ready_figures")
const LABEL_THRESHOLD_MW = 150.0
const THESIS_TICK_FONT = 10
const THESIS_GUIDE_FONT = 11
const THESIS_TITLE_FONT = 12
const THESIS_SUPTITLE_FONT = 15
const THESIS_LEGEND_FONT = 10
const THESIS_ANNOTATION_FONT = 7
const THESIS_DPI = 300

default(
    dpi=THESIS_DPI,
    grid=true,
    gridalpha=0.15,
    gridlinewidth=0.6,
    foreground_color_grid=:grey70,
    framestyle=:semi,
    legend_background_color=:white,
    legend_foreground_color=:grey45,
    background_color=:white,
    thickness_scaling=1.0,
)

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
    return path
end

function load_saved_case(run_dir::AbstractString, case_folder::AbstractString)
    path = joinpath(run_dir, case_folder, "all_results.jls")
    isfile(path) || error("Saved result file not found: $path")
    return deserialize(path)
end

function get_clearings_for_day(clearing_details::Dict, day_of_month::Int)
    day_start_hour = (day_of_month - 1) * 24 + 1
    day_end_hour = day_of_month * 24
    all_clearing_indices = sort(collect(keys(clearing_details)))
    return [c for c in all_clearing_indices if day_start_hour <= clearing_details[c][:current_hour] <= day_end_hour]
end

function integer_tick_label(x)
    value = round(Int, x)
    sign = value < 0 ? "-" : ""
    digits = string(abs(value))
    groups = String[]

    while length(digits) > 3
        pushfirst!(groups, digits[end-2:end])
        digits = digits[1:end-3]
    end

    pushfirst!(groups, digits)
    return sign * join(groups, ",")
end

function plain_integer_label(x)
    return integer_tick_label(round(Int, x))
end

function save_publication_figure(p, path::AbstractString)
    savefig(p, path)
    return path
end

function maybe_annotate!(p, x, y, value; threshold::Real=LABEL_THRESHOLD_MW)
    if abs(value) > threshold
        sign_str = value > 0 ? "+" : ""
        annotate!(p, x, y, text(@sprintf("%s%.0f", sign_str, value), THESIS_ANNOTATION_FONT, :black))
    end
end

function selected_day_clearings(clearing_details::Dict, day_of_month::Int, start_clearing_of_day::Int, num_clearings_to_show::Int)
    day_clearings = get_clearings_for_day(clearing_details, day_of_month)
    last_idx = min(length(day_clearings), start_clearing_of_day + num_clearings_to_show - 1)
    isempty(day_clearings) && error("No clearings found for day $day_of_month.")
    return day_clearings[start_clearing_of_day:last_idx]
end

function selected_global_hour_window(clearing_details::Dict, clearing_indices)
    start_clearing = clearing_indices[1]
    start_global_hour = clearing_details[start_clearing][:current_hour]
    last_clearing = clearing_indices[end]
    end_global_hour = clearing_details[last_clearing][:current_hour] + clearing_details[last_clearing][:look_ahead] - 1
    return start_global_hour, end_global_hour
end

function plot_price_forecasts_for_day_thesis(all_results::Dict;
                                             day_of_month::Int=28,
                                             start_clearing_of_day::Int=1,
                                             num_clearings_to_show::Int=5,
                                             case_label::AbstractString="",
                                             xlims_override=nothing)
    clearing_details = all_results[:clearing_details]
    clearing_indices = selected_day_clearings(
        clearing_details,
        day_of_month,
        start_clearing_of_day,
        num_clearings_to_show,
    )
    start_global_hour, end_global_hour = selected_global_hour_window(clearing_details, clearing_indices)

    line_styles = [:solid, :dash, :dot, :dashdot, :dashdotdot]
    markers = [:circle, :square, :diamond, :utriangle, :dtriangle]

    p = plot(
        xlabel="Global Hour",
        ylabel="Price (EUR/MWh)",
        title="Prices - $case_label (Day $day_of_month)",
        legend=:topright,
        linewidth=3.0,
        size=(1700, 430),
        tickfontsize=THESIS_TICK_FONT,
        guidefontsize=THESIS_GUIDE_FONT,
        titlefontsize=THESIS_TITLE_FONT,
        legendfontsize=THESIS_LEGEND_FONT,
        left_margin=16Plots.mm,
        right_margin=10Plots.mm,
        top_margin=7Plots.mm,
        bottom_margin=14Plots.mm,
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
            linewidth=3.0,
            linestyle=line_styles[mod1(idx, length(line_styles))],
            marker=markers[mod1(idx, length(markers))],
            markersize=6,
            markerstrokewidth=0,
            alpha=0.9,
        )
    end

    if isnothing(xlims_override)
        xlims!(p, start_global_hour - 0.5, end_global_hour + 0.5)
    else
        xlims!(p, xlims_override...)
    end
    return p
end

function plot_generation_mix_for_day_thesis(all_results::Dict;
                                            day_of_month::Int=28,
                                            start_clearing_of_day::Int=1,
                                            num_clearings_to_show::Int=3,
                                            title_suffix::AbstractString="")
    clearing_details = all_results[:clearing_details]
    dispatch_dict = all_results[:dispatch]
    day_clearings = get_clearings_for_day(clearing_details, day_of_month)
    last_idx = min(length(day_clearings), start_clearing_of_day + num_clearings_to_show - 1)
    clearing_indices = day_clearings[start_clearing_of_day:last_idx]

    gen_order = ["Base", "Mid", "Solar", "Wind", "Peak"]
    gen_colors_map = Dict(
        "Base" => :steelblue,
        "Mid" => :lightblue,
        "Solar" => :yellow,
        "Wind" => :lightgreen,
        "Peak" => :coral,
        "Discharge" => :gold,
    )

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
            ylabel="Power (MW)",
            title="Clearing $clearing_num$title_suffix",
            legend=:topright,
            size=(410, 430),
            tickfontsize=THESIS_TICK_FONT,
            guidefontsize=THESIS_GUIDE_FONT,
            titlefontsize=THESIS_TITLE_FONT,
            legendfontsize=THESIS_LEGEND_FONT,
            yformatter=integer_tick_label,
            left_margin=12Plots.mm,
            right_margin=6Plots.mm,
            top_margin=7Plots.mm,
            bottom_margin=12Plots.mm,
        )

        cumsum_prev = zeros(look_ahead_hours)
        for gen in available_gens
            gen_values = gen_data[gen][1:look_ahead_hours]
            cumsum_curr = cumsum_prev .+ gen_values
            plot!(
                p_mix,
                hours,
                cumsum_curr,
                fillrange=cumsum_prev,
                label=gen,
                color=gen_colors_map[gen],
                alpha=0.8,
                linewidth=0,
            )
            cumsum_prev = cumsum_curr
        end

        if maximum(discharge_data) > 0.1
            cumsum_discharge = cumsum_prev .+ discharge_data
            plot!(
                p_mix,
                hours,
                cumsum_discharge,
                fillrange=cumsum_prev,
                label="Discharge",
                color=gen_colors_map["Discharge"],
                alpha=0.8,
                linewidth=0,
            )
            cumsum_prev = cumsum_discharge
        end

        if maximum(charging_data) > 0.1
            plot!(p_mix, hours, total_demand_with_charging, label="Charging", color=:mediumpurple, linewidth=2)
        end

        plot!(p_mix, hours, total_demand, label="Demand", color=:black, linewidth=2)
        xlims!(p_mix, 0.5, look_ahead_hours + 0.5)
        push!(mix_plots, p_mix)
    end

    return plot(
        mix_plots...,
        layout=(1, length(mix_plots)),
        size=(1520, 490),
        plot_title="Generation Mix - 28/05$title_suffix",
        plot_titlefontsize=THESIS_SUPTITLE_FONT,
        top_margin=8Plots.mm,
        bottom_margin=12Plots.mm,
    )
end

function position_change_subplots_for_day_thesis(all_results::Dict;
                                                 day_of_month::Int=28,
                                                 start_clearing_of_day::Int=1,
                                                 num_clearings_to_show::Int=5,
                                                 title_suffix::AbstractString="",
                                                 xlims_override=nothing)
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
            size=(920, 390),
            yticks=(0:num_selected_clearings, ytick_labels),
            yflip=true,
            tickfontsize=THESIS_TICK_FONT,
            guidefontsize=THESIS_GUIDE_FONT,
            titlefontsize=THESIS_TITLE_FONT,
            left_margin=16Plots.mm,
            right_margin=10Plots.mm,
            top_margin=10Plots.mm,
            bottom_margin=16Plots.mm,
        )

        Q_prev_dict = clearing_details[start_clearing][:Q_prev]
        clearing_start_hour = clearing_details[start_clearing][:current_hour]
        look_ahead_hours = clearing_details[start_clearing][:look_ahead]
        for local_h in 1:look_ahead_hours
            global_h = clearing_start_hour + local_h - 1
            value = Q_prev_dict[(gen_name, local_h)]
            if value > 0.01
                plot!(
                    p_gen,
                    [global_h - 0.4, global_h + 0.4],
                    [0, 0],
                    fillrange=[0.4, 0.4],
                    fillcolor=:orange,
                    fillalpha=0.6,
                    linewidth=0,
                )
                maybe_annotate!(p_gen, global_h, 0, value)
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
                        p_gen,
                        [global_h - 0.4, global_h + 0.4],
                        [row_idx, row_idx],
                        fillrange=[row_idx + 0.4, row_idx + 0.4],
                        fillcolor=bar_color,
                        fillalpha=0.7,
                        linewidth=0,
                    )
                    maybe_annotate!(p_gen, global_h, row_idx, value)
                end
            end
        end

        if isnothing(xlims_override)
            xlims!(p_gen, start_global_hour - 0.5, end_global_hour + 0.5)
        else
            xlims!(p_gen, xlims_override...)
        end
        ylims!(p_gen, -0.5, num_selected_clearings + 0.5)
        push!(subplots, p_gen)
    end

    return subplots
end

function plot_price_position_three_panel(all_results::Dict, case_label::AbstractString;
                                         day_of_month::Int=28,
                                         start_clearing_of_day::Int=1,
                                         num_clearings_to_show::Int=5,
                                         xlims_override=nothing)
    p_price = plot_price_forecasts_for_day_thesis(
        all_results;
        day_of_month=day_of_month,
        start_clearing_of_day=start_clearing_of_day,
        num_clearings_to_show=num_clearings_to_show,
        case_label=case_label,
        xlims_override=xlims_override,
    )
    p_mid, p_wind = position_change_subplots_for_day_thesis(
        all_results;
        day_of_month=day_of_month,
        start_clearing_of_day=start_clearing_of_day,
        num_clearings_to_show=num_clearings_to_show,
        title_suffix=" - $case_label (Day $day_of_month)",
        xlims_override=xlims_override,
    )

    return plot(
        p_price,
        p_mid,
        p_wind,
        layout=(3, 1),
        size=(1900, 1500),
        top_margin=8Plots.mm,
        bottom_margin=12Plots.mm,
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
    )
end

function common_price_position_xlim(fixed_all::Dict, rolling_all::Dict;
                                    day_of_month::Int=28,
                                    start_clearing_of_day::Int=1,
                                    num_clearings_to_show::Int=5)
    windows = Tuple{Int, Int}[]
    for all_results in (fixed_all, rolling_all)
        clearing_details = all_results[:clearing_details]
        clearing_indices = selected_day_clearings(
            clearing_details,
            day_of_month,
            start_clearing_of_day,
            num_clearings_to_show,
        )
        push!(windows, selected_global_hour_window(clearing_details, clearing_indices))
    end

    x_min = minimum(first.(windows)) - 0.5
    x_max = maximum(last.(windows)) + 0.5
    return (x_min, x_max)
end

function plot_position_changes_for_day_thesis(all_results::Dict;
                                              day_of_month::Int=28,
                                              start_clearing_of_day::Int=1,
                                              num_clearings_to_show::Int=5,
                                              title_suffix::AbstractString="")
    subplots = position_change_subplots_for_day_thesis(
        all_results;
        day_of_month=day_of_month,
        start_clearing_of_day=start_clearing_of_day,
        num_clearings_to_show=num_clearings_to_show,
        title_suffix=title_suffix,
    )

    return plot(
        subplots...,
        layout=(2, 1),
        size=(1030, 820),
        plot_title="Position Changes - 28/05$title_suffix",
        plot_titlefontsize=THESIS_SUPTITLE_FONT,
        top_margin=10Plots.mm,
        bottom_margin=12Plots.mm,
    )
end

function build_retrade_adjustment_plot(run_dir::AbstractString, output_dir::AbstractString)
    csv_path = joinpath(run_dir, "_revenue_profit_gap_analysis", "generator_financial_comparison.csv")
    isfile(csv_path) || error("Generator financial comparison not found: $csv_path")

    generator_df = CSV.read(csv_path, DataFrame)
    gens = ["Base", "Mid", "Peak", "Solar", "Wind"]
    fixed = filter(:case_name => ==("Fixed 36h"), generator_df)
    rolling = filter(:case_name => ==("Rolling 36h"), generator_df)

    fixed_adj = [only(filter(:generator => ==(g), fixed)).retrade_adjustment / 1e6 for g in gens]
    rolling_adj = [only(filter(:generator => ==(g), rolling)).retrade_adjustment / 1e6 for g in gens]
    y_min = minimum(vcat(fixed_adj, rolling_adj))
    y_max = maximum(vcat(fixed_adj, rolling_adj))
    y_padding = 0.12 * (y_max - y_min)

    p = groupedbar(
        gens,
        [fixed_adj rolling_adj],
        color=[:steelblue :darkorange],
        label=["Fixed 36h" "Rolling 36h"],
        title="Re-trading Adjustment by Generator",
        ylabel="EUR million",
        legend=:bottomleft,
        size=(1150, 720),
        tickfontsize=THESIS_TICK_FONT,
        guidefontsize=THESIS_GUIDE_FONT,
        titlefontsize=THESIS_SUPTITLE_FONT,
        legendfontsize=THESIS_LEGEND_FONT,
        ylims=(y_min - y_padding, y_max + y_padding),
        yformatter=y -> @sprintf("%.0f", y),
        left_margin=24Plots.mm,
        right_margin=14Plots.mm,
        top_margin=12Plots.mm,
        bottom_margin=18Plots.mm,
    )
    hline!(p, [0.0], color=:black, linewidth=1.0, label="")

    png_path = joinpath(output_dir, "baseline_09_retrade_adjustment_by_generator_seedA_thesis_ready.png")
    pdf_path = joinpath(output_dir, "baseline_09_retrade_adjustment_by_generator_seedA_thesis_ready.pdf")
    save_publication_figure(p, png_path)
    save_publication_figure(p, pdf_path)

    return Dict(:plot => p, :png => png_path, :pdf => pdf_path)
end

function average_net_discharge_by_hour(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    values_by_hour = zeros(Float64, 24)
    hour_counts = zeros(Int, 24)

    for clearing_num in sort(collect(keys(clearing_details)))
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        start_hour = details[:current_hour]

        for h in 1:executed_hours
            global_hour = start_hour + h - 1
            hour_of_day = mod(global_hour - 1, 24) + 1
            values_by_hour[hour_of_day] += details[:discharging][h] - details[:charging][h]
            hour_counts[hour_of_day] += 1
        end
    end

    return [
        hour_counts[h] > 0 ? values_by_hour[h] / hour_counts[h] : 0.0
        for h in 1:24
    ]
end

function build_avg_net_discharge_plot(fixed_all::Dict, rolling_all::Dict, output_dir::AbstractString)
    hours = 1:24
    fixed_values = average_net_discharge_by_hour(fixed_all)
    rolling_values = average_net_discharge_by_hour(rolling_all)
    combined_values = vcat(fixed_values, rolling_values)
    y_min = minimum(combined_values)
    y_max = maximum(combined_values)
    y_padding = 0.12 * (y_max - y_min)

    p = plot(
        hours,
        fixed_values,
        label="Fixed 36h",
        color=:steelblue,
        linewidth=3.0,
        marker=:circle,
        markersize=5,
        xlabel="Hour of Day",
        ylabel="Average net discharge (MWh)",
        title="Average Battery Net Discharge by Hour of Day",
        legend=:topright,
        size=(1250, 720),
        xlims=(1, 24),
        ylims=(y_min - y_padding, y_max + y_padding),
        xticks=1:2:24,
        tickfontsize=THESIS_TICK_FONT,
        guidefontsize=THESIS_GUIDE_FONT,
        titlefontsize=THESIS_SUPTITLE_FONT,
        legendfontsize=THESIS_LEGEND_FONT,
        left_margin=24Plots.mm,
        right_margin=12Plots.mm,
        top_margin=12Plots.mm,
        bottom_margin=22Plots.mm,
    )
    plot!(
        p,
        hours,
        rolling_values,
        label="Rolling 36h",
        color=:darkorange,
        linewidth=3.0,
        marker=:diamond,
        markersize=5,
    )
    hline!(p, [0.0], color=:black, linewidth=1.0, alpha=0.7, label="")

    png_path = joinpath(output_dir, "baseline_10_avg_net_discharge_by_hour_seedA_thesis_ready.png")
    pdf_path = joinpath(output_dir, "baseline_10_avg_net_discharge_by_hour_seedA_thesis_ready.pdf")
    save_publication_figure(p, png_path)
    save_publication_figure(p, pdf_path)

    return Dict(:plot => p, :png => png_path, :pdf => pdf_path)
end

function build_sorted_delta_swf_plot(run_dir::AbstractString, output_dir::AbstractString)
    csv_path = joinpath(
        run_dir,
        "_summary",
        "_daily_driver_patterns",
        "rolling_36h_minus_fixed_36h",
        "comparison_rows.csv",
    )
    isfile(csv_path) || error("Daily-driver comparison rows not found: $csv_path")

    df = CSV.read(csv_path, DataFrame)
    complete_days = filter(row -> row.left_is_complete_day && row.right_is_complete_day, df)
    sorted = sort(complete_days, :delta_social_welfare_eur, rev=true)
    y = Float64.(sorted.delta_social_welfare_eur)
    x = 1:length(y)
    colors = [val >= 0 ? RGB(0.15, 0.55, 0.30) : RGB(0.75, 0.22, 0.22) for val in y]
    y_min = minimum(y)
    y_max = maximum(y)
    y_padding = 0.14 * (y_max - y_min)

    p = bar(
        x,
        y,
        color=colors,
        legend=false,
        xlabel="Days ranked by social welfare difference",
        ylabel="Social welfare difference (EUR)",
        title="Rolling 36h - Fixed 36h: Daily Social Welfare Difference",
        size=(1250, 720),
        xlims=(0.25, length(y) + 0.75),
        ylims=(y_min - y_padding, y_max + y_padding),
        tickfontsize=THESIS_TICK_FONT,
        guidefontsize=THESIS_GUIDE_FONT,
        titlefontsize=THESIS_SUPTITLE_FONT,
        yformatter=plain_integer_label,
        left_margin=28Plots.mm,
        right_margin=18Plots.mm,
        top_margin=12Plots.mm,
        bottom_margin=24Plots.mm,
    )
    hline!(p, [0.0], color=:black, linestyle=:dash, linewidth=1.5, label="")

    png_path = joinpath(output_dir, "baseline_11_sorted_social_welfare_difference_seedA_thesis_ready.png")
    pdf_path = joinpath(output_dir, "baseline_11_sorted_social_welfare_difference_seedA_thesis_ready.pdf")
    save_publication_figure(p, png_path)
    save_publication_figure(p, pdf_path)

    return Dict(:plot => p, :png => png_path, :pdf => pdf_path)
end

function remake_thesis_ready_baseline_figures(run_dir::AbstractString=DEFAULT_RUN_DIR;
                                              output_dir::AbstractString=DEFAULT_OUTPUT_DIR)
    ensure_dir(output_dir)
    fixed_all = load_saved_case(run_dir, "fixed_36h")
    rolling_all = load_saved_case(run_dir, "rolling_36h")

    p_generation_fixed = plot_generation_mix_for_day_thesis(fixed_all; title_suffix=" - Fixed 36h")
    p_generation_rolling = plot_generation_mix_for_day_thesis(rolling_all; title_suffix=" - Rolling 36h")
    p_generation = plot(
        p_generation_fixed,
        p_generation_rolling,
        layout=(2, 1),
        size=(1600, 1160),
        plot_title="Generation Mix on 28/05 Across 3 Clearings",
        plot_titlefontsize=THESIS_SUPTITLE_FONT,
        top_margin=10Plots.mm,
        bottom_margin=18Plots.mm,
    )

    p_position_fixed_subplots = position_change_subplots_for_day_thesis(fixed_all; title_suffix=" - Fixed 36h")
    p_position_rolling_subplots = position_change_subplots_for_day_thesis(rolling_all; title_suffix=" - Rolling 36h")
    p_position = plot(
        p_position_fixed_subplots[1],
        p_position_rolling_subplots[1],
        p_position_fixed_subplots[2],
        p_position_rolling_subplots[2],
        layout=(2, 2),
        size=(2200, 1050),
        plot_title="Position Changes on 28/05 Across 5 Clearings",
        plot_titlefontsize=THESIS_SUPTITLE_FONT,
        top_margin=10Plots.mm,
        bottom_margin=16Plots.mm,
    )

    shared_three_panel_xlim = common_price_position_xlim(fixed_all, rolling_all)
    p_fixed_three_panel = plot_price_position_three_panel(fixed_all, "Fixed 36h"; xlims_override=shared_three_panel_xlim)
    p_rolling_three_panel = plot_price_position_three_panel(rolling_all, "Rolling 36h"; xlims_override=shared_three_panel_xlim)
    retrade_plot = build_retrade_adjustment_plot(run_dir, output_dir)
    net_discharge_plot = build_avg_net_discharge_plot(fixed_all, rolling_all, output_dir)
    sorted_delta_swf_plot = build_sorted_delta_swf_plot(run_dir, output_dir)

    generation_png = joinpath(output_dir, "baseline_06_generation_mix_28_05_thesis_ready.png")
    generation_pdf = joinpath(output_dir, "baseline_06_generation_mix_28_05_thesis_ready.pdf")
    position_png = joinpath(output_dir, "baseline_05_position_changes_28_05_thesis_ready.png")
    position_pdf = joinpath(output_dir, "baseline_05_position_changes_28_05_thesis_ready.pdf")
    fixed_three_panel_png = joinpath(output_dir, "baseline_07_fixed_price_positions_28_05_thesis_ready.png")
    fixed_three_panel_pdf = joinpath(output_dir, "baseline_07_fixed_price_positions_28_05_thesis_ready.pdf")
    rolling_three_panel_png = joinpath(output_dir, "baseline_08_rolling_price_positions_28_05_thesis_ready.png")
    rolling_three_panel_pdf = joinpath(output_dir, "baseline_08_rolling_price_positions_28_05_thesis_ready.pdf")

    save_publication_figure(p_generation, generation_png)
    save_publication_figure(p_generation, generation_pdf)
    save_publication_figure(p_position, position_png)
    save_publication_figure(p_position, position_pdf)
    save_publication_figure(p_fixed_three_panel, fixed_three_panel_png)
    save_publication_figure(p_fixed_three_panel, fixed_three_panel_pdf)
    save_publication_figure(p_rolling_three_panel, rolling_three_panel_png)
    save_publication_figure(p_rolling_three_panel, rolling_three_panel_pdf)

    println("Saved thesis-ready figures:")
    println("  $generation_png")
    println("  $generation_pdf")
    println("  $position_png")
    println("  $position_pdf")
    println("  $fixed_three_panel_png")
    println("  $fixed_three_panel_pdf")
    println("  $rolling_three_panel_png")
    println("  $rolling_three_panel_pdf")
    println("  $(retrade_plot[:png])")
    println("  $(retrade_plot[:pdf])")
    println("  $(net_discharge_plot[:png])")
    println("  $(net_discharge_plot[:pdf])")
    println("  $(sorted_delta_swf_plot[:png])")
    println("  $(sorted_delta_swf_plot[:pdf])")

    return Dict(
        :generation_mix => p_generation,
        :position_changes => p_position,
        :fixed_price_positions => p_fixed_three_panel,
        :rolling_price_positions => p_rolling_three_panel,
        :retrade_adjustment_by_generator => retrade_plot[:plot],
        :avg_net_discharge_by_hour => net_discharge_plot[:plot],
        :sorted_daily_delta_swf => sorted_delta_swf_plot[:plot],
        :generation_png => generation_png,
        :generation_pdf => generation_pdf,
        :position_png => position_png,
        :position_pdf => position_pdf,
        :fixed_three_panel_png => fixed_three_panel_png,
        :fixed_three_panel_pdf => fixed_three_panel_pdf,
        :rolling_three_panel_png => rolling_three_panel_png,
        :rolling_three_panel_pdf => rolling_three_panel_pdf,
        :retrade_adjustment_png => retrade_plot[:png],
        :retrade_adjustment_pdf => retrade_plot[:pdf],
        :avg_net_discharge_png => net_discharge_plot[:png],
        :avg_net_discharge_pdf => net_discharge_plot[:pdf],
        :sorted_daily_delta_swf_png => sorted_delta_swf_plot[:png],
        :sorted_daily_delta_swf_pdf => sorted_delta_swf_plot[:pdf],
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_dir = length(ARGS) >= 1 ? ARGS[1] : DEFAULT_RUN_DIR
    output_dir = length(ARGS) >= 2 ? ARGS[2] : joinpath(run_dir, "_summary", "thesis_ready_figures")
    remake_thesis_ready_baseline_figures(run_dir; output_dir=output_dir)
end

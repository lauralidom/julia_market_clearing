using Serialization
using Plots
using JuMP
using HiGHS

const RUN_DIR = joinpath("Results", "thesis_runs", "all_20260512_101146")
const OUTPUT_DIR = joinpath(RUN_DIR, "_summary", "baseline_market_design", "may05_generation_mix_24_clearings")
const DAY_OF_MONTH = 5
const NUM_CLEARINGS_TO_SHOW = 30
const CASES = [
    ("Fixed 36h", "fixed_36h"),
    ("Rolling 36h", "rolling_36h"),
]

default(
    dpi=300,
    grid=true,
    gridalpha=0.12,
    gridlinewidth=0.5,
    foreground_color_grid=:grey70,
    framestyle=:semi,
    legend_background_color=:white,
    legend_foreground_color=:grey45,
    background_color=:white,
)

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
    return path
end

function load_saved_case(case_folder::AbstractString)
    path = joinpath(RUN_DIR, case_folder, "all_results.jls")
    isfile(path) || error("Saved result file not found: $path")
    return deserialize(path)
end

function get_clearings_for_day(clearing_details::Dict, day_of_month::Int)
    day_start_hour = (day_of_month - 1) * 24 + 1
    day_end_hour = day_of_month * 24
    all_clearing_indices = sort(collect(keys(clearing_details)))
    return [c for c in all_clearing_indices if day_start_hour <= clearing_details[c][:current_hour] <= day_end_hour]
end

function consecutive_clearings_from_day_start(clearing_details::Dict, day_of_month::Int, num_clearings::Int)
    day_clearings = get_clearings_for_day(clearing_details, day_of_month)
    isempty(day_clearings) && error("No clearings found for day $day_of_month.")

    all_clearing_indices = sort(collect(keys(clearing_details)))
    start_idx = findfirst(==(first(day_clearings)), all_clearing_indices)
    last_idx = min(length(all_clearing_indices), start_idx + num_clearings - 1)
    return all_clearing_indices[start_idx:last_idx]
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

function case_day_ymax(all_results::Dict, clearing_indices)
    clearing_details = all_results[:clearing_details]
    dispatch_dict = all_results[:dispatch]
    gen_order = ["Base", "Mid", "Solar", "Wind", "Peak"]
    max_value = 0.0

    for clearing_num in clearing_indices
        details = clearing_details[clearing_num]
        gen_data = dispatch_dict[clearing_num]
        look_ahead_hours = details[:look_ahead]
        stack_total = zeros(look_ahead_hours)

        for gen in gen_order
            if haskey(gen_data, gen)
                stack_total .+= gen_data[gen][1:look_ahead_hours]
            end
        end

        discharge = details[:discharging][1:look_ahead_hours]
        charging = details[:charging][1:look_ahead_hours]
        demand = details[:demand_base][1:look_ahead_hours] .+ details[:demand_flex][1:look_ahead_hours]

        max_value = max(max_value, maximum(stack_total .+ discharge), maximum(demand .+ charging))
    end

    return max_value
end

function generation_mix_subplot(all_results::Dict, clearing_num::Int, case_label::AbstractString; y_max::Real, show_legend::Bool=false)
    clearing_details = all_results[:clearing_details]
    dispatch_dict = all_results[:dispatch]
    gen_order = ["Base", "Mid", "Solar", "Wind", "Peak"]
    gen_colors = Dict(
        "Base" => :steelblue,
        "Mid" => :lightblue,
        "Solar" => :yellow,
        "Wind" => :lightgreen,
        "Peak" => :coral,
        "Discharge" => :gold,
    )

    details = clearing_details[clearing_num]
    gen_data = dispatch_dict[clearing_num]
    look_ahead_hours = details[:look_ahead]
    hours = 1:look_ahead_hours
    available_gens = filter(g -> haskey(gen_data, g), gen_order)

    discharge = details[:discharging][1:look_ahead_hours]
    charging = details[:charging][1:look_ahead_hours]
    demand = details[:demand_base][1:look_ahead_hours] .+ details[:demand_flex][1:look_ahead_hours]

    p = plot(
        xlabel="",
        ylabel="",
        title="C$clearing_num - $case_label",
        legend=show_legend ? :topright : :none,
        tickfontsize=5,
        guidefontsize=7,
        titlefontsize=8,
        legendfontsize=5,
        yformatter=integer_tick_label,
        left_margin=3Plots.mm,
        right_margin=2Plots.mm,
        top_margin=3Plots.mm,
        bottom_margin=3Plots.mm,
    )

    cumsum_prev = zeros(look_ahead_hours)
    for gen in available_gens
        gen_values = gen_data[gen][1:look_ahead_hours]
        cumsum_curr = cumsum_prev .+ gen_values
        plot!(
            p,
            hours,
            cumsum_curr,
            fillrange=cumsum_prev,
            label=gen,
            color=gen_colors[gen],
            alpha=0.8,
            linewidth=0,
        )
        cumsum_prev = cumsum_curr
    end

    if maximum(discharge) > 0.1
        cumsum_discharge = cumsum_prev .+ discharge
        plot!(
            p,
            hours,
            cumsum_discharge,
            fillrange=cumsum_prev,
            label="Discharge",
            color=gen_colors["Discharge"],
            alpha=0.8,
            linewidth=0,
        )
    end

    if maximum(charging) > 0.1
        plot!(p, hours, demand .+ charging, label="Charging", color=:mediumpurple, linewidth=1.4)
    end

    plot!(p, hours, demand, label="Demand", color=:black, linewidth=1.4)
    xlims!(p, 0.5, look_ahead_hours + 0.5)
    ylims!(p, 0, y_max * 1.05)
    return p
end

function generation_mix_grid(all_results::Dict, case_label::AbstractString, clearing_indices; y_max::Real)
    subplots = Any[
        generation_mix_subplot(
            all_results,
            clearing_num,
            case_label;
            y_max=y_max,
            show_legend=i == 1,
        )
        for (i, clearing_num) in enumerate(clearing_indices)
    ]

    return plot(
        subplots...,
        layout=(5, 6),
        size=(2700, 2200),
        plot_title="Generation Mix from 05/05 Across 30 Clearings - $case_label",
        plot_titlefontsize=15,
        bottom_margin=4Plots.mm,
    )
end

function paired_generation_mix_grid(case_results, clearing_indices; y_max::Real)
    subplots = Any[]
    for chunk_start in 1:6:length(clearing_indices)
        chunk = clearing_indices[chunk_start:min(chunk_start + 5, end)]
        for (case_label, all_results) in case_results
            for (offset, clearing_num) in enumerate(chunk)
                show_legend = chunk_start == 1 && offset == 1 && case_label == "Fixed 36h"
                push!(
                    subplots,
                    generation_mix_subplot(
                        all_results,
                        clearing_num,
                        case_label;
                        y_max=y_max,
                        show_legend=show_legend,
                    ),
                )
            end
        end
    end

    return plot(
        subplots...,
        layout=(10, 6),
        size=(3000, 3700),
        plot_title="Generation Mix from 05/05 Across 30 Clearings - Fixed 36h vs Rolling 36h",
        plot_titlefontsize=15,
        bottom_margin=3Plots.mm,
    )
end

function main()
    ensure_dir(OUTPUT_DIR)
    loaded_cases = [(case_label, load_saved_case(case_folder)) for (case_label, case_folder) in CASES]

    first_details = loaded_cases[1][2][:clearing_details]
    clearing_indices = consecutive_clearings_from_day_start(first_details, DAY_OF_MONTH, NUM_CLEARINGS_TO_SHOW)
    length(clearing_indices) == NUM_CLEARINGS_TO_SHOW || @warn "Fewer clearings than requested" requested=NUM_CLEARINGS_TO_SHOW found=length(clearing_indices)

    y_max = maximum(case_day_ymax(all_results, clearing_indices) for (_, all_results) in loaded_cases)

    saved_paths = String[]
    for (case_label, all_results) in loaded_cases
        p = generation_mix_grid(all_results, case_label, clearing_indices; y_max=y_max)
        safe_case = replace(lowercase(case_label), " " => "_")
        path = joinpath(OUTPUT_DIR, "generation_mix_2025_05_05_$(safe_case)_30_clearings.png")
        savefig(p, path)
        push!(saved_paths, path)
    end

    paired = paired_generation_mix_grid(loaded_cases, clearing_indices; y_max=y_max)
    paired_path = joinpath(OUTPUT_DIR, "mix_0505_fixed_vs_rolling_36h_30_clearings.png")
    savefig(paired, paired_path)
    push!(saved_paths, paired_path)

    println("Saved May 5 generation mix plots:")
    foreach(path -> println("  ", path), saved_paths)
end

main()

# VISUALISATION

using Plots, Statistics, Printf, XLSX

# Shared visualization inputs (used by rolling and fixed simulation scripts)
# VIS_DAY_OF_MONTH accepts either an integer day (1 = first day) or :last.
const VIS_DAY_OF_MONTH = 17
const VIS_START_CLEARING_OF_DAY = 1
const VIS_NUM_CLEARINGS_TO_SHOW = 5

function get_clearings_for_day(clearing_details::Dict, day_of_month::Int)
    day_start_hour = (day_of_month - 1) * 24 + 1
    day_end_hour = day_of_month * 24

    all_clearing_indices = sort(collect(keys(clearing_details)))
    return [c for c in all_clearing_indices if day_start_hour <= clearing_details[c][:current_hour] <= day_end_hour]
end

function collect_battery_diagnostics(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    if isempty(clearing_details)
        error("No clearing details found in all_results.")
    end

    clearing_indices = sort(collect(keys(clearing_details)))

    global_hours = Int[]
    soc_start = Float64[]
    soc_end_executed = Float64[]
    soc_end_window = Float64[]
    charge_executed = Float64[]
    discharge_executed = Float64[]
    net_discharge_executed = Float64[]
    avg_exec_price = Float64[]

    for clearing_num in clearing_indices
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        soc_path = details[:storage_soc_path]

        push!(global_hours, details[:current_hour])
        push!(soc_start, details[:storage_soc_start])
        push!(soc_end_executed, details[:storage_soc_end_executed])
        push!(soc_end_window, details[:storage_soc_end_window])

        charge = sum(details[:charging][1:executed_hours])
        discharge = sum(details[:discharging][1:executed_hours])
        push!(charge_executed, charge)
        push!(discharge_executed, discharge)
        push!(net_discharge_executed, discharge - charge)
        push!(avg_exec_price, mean(details[:prices][1:executed_hours]))

        @assert length(soc_path) == details[:look_ahead] "SOC path length does not match look-ahead in clearing $clearing_num"
    end

    cumulative_net_absorbed = cumsum(charge_executed .- discharge_executed)

    return Dict(
        :global_hours => global_hours,
        :soc_start => soc_start,
        :soc_end_executed => soc_end_executed,
        :soc_end_window => soc_end_window,
        :charge_executed => charge_executed,
        :discharge_executed => discharge_executed,
        :net_discharge_executed => net_discharge_executed,
        :avg_exec_price => avg_exec_price,
        :cumulative_net_absorbed => cumulative_net_absorbed
    )
end

function plot_battery_diagnostics(all_results::Dict)
    diag = collect_battery_diagnostics(all_results)
    E_cap = get(all_results, :storage_energy_capacity, NaN)
    hours = diag[:global_hours]

    p_soc = plot(
        hours, diag[:soc_start],
        label="SOC start",
        xlabel="Global Hour",
        ylabel="Energy (MWh)",
        title="Battery SOC Across Clearings",
        linewidth=2.5,
        color=:steelblue,
        size=(1100, 350)
    )
    plot!(p_soc, hours, diag[:soc_end_executed], label="SOC after executed hour(s)", linewidth=2.5, color=:darkorange)
    plot!(p_soc, hours, diag[:soc_end_window], label="SOC at end of look-ahead", linewidth=2.0, linestyle=:dash, color=:forestgreen)
    if isfinite(E_cap)
        hline!(p_soc, [0.0, E_cap], label="", color=:gray60, linestyle=:dot, alpha=0.7)
    end

    p_flow = bar(
        hours, diag[:charge_executed],
        label="Charge",
        xlabel="Global Hour",
        ylabel="Executed Energy (MWh)",
        title="Executed Battery Energy per Clearing",
        color=:mediumpurple,
        alpha=0.75,
        size=(1100, 350)
    )
    bar!(p_flow, hours, -diag[:discharge_executed], label="Discharge", color=:goldenrod2, alpha=0.75)
    hline!(p_flow, [0.0], label="", color=:black, linewidth=1.0)

    p_cumulative = plot(
        hours, diag[:cumulative_net_absorbed],
        label="Cumulative (charge - discharge)",
        xlabel="Global Hour",
        ylabel="Energy (MWh)",
        title="Cumulative Net Energy Absorbed by Battery",
        linewidth=2.5,
        color=:firebrick,
        size=(1100, 350)
    )
    hline!(p_cumulative, [0.0], label="", color=:black, linewidth=1.0)

    p_price = scatter(
        diag[:avg_exec_price], diag[:net_discharge_executed],
        xlabel="Average Executed Price (EUR/MWh)",
        ylabel="Net Executed Discharge (MWh)",
        title="Battery Response vs Executed Price",
        label="One point per clearing",
        color=:teal,
        markersize=4,
        alpha=0.75,
        size=(1100, 350)
    )
    hline!(p_price, [0.0], label="", color=:black, linewidth=1.0)

    plot(p_soc, p_flow, p_cumulative, p_price, layout=(4, 1), size=(1100, 1400))
end

function collect_demand_diagnostics(all_results::Dict)
    clearing_details = all_results[:clearing_details]
    if isempty(clearing_details)
        error("No clearing details found in all_results.")
    end

    clearing_indices = sort(collect(keys(clearing_details)))

    total_base_served = 0.0
    total_flex_served = 0.0
    total_base_available = 0.0
    total_flex_available = 0.0
    flex_curtailed_hours = 0
    executed_hours_total = 0

    price_bucket_labels = ["<=50", "50-100", "100-150", ">150"]
    price_bucket_counts = Dict(label => 0 for label in price_bucket_labels)
    price_bucket_flex = Dict(label => 0.0 for label in price_bucket_labels)

    flex_served_by_hour = zeros(Float64, 24)
    flex_available_by_hour = zeros(Float64, 24)
    hour_counts = zeros(Int, 24)

    for clearing_num in clearing_indices
        details = clearing_details[clearing_num]
        executed_hours = details[:executed_hours]
        start_hour = details[:current_hour]

        for h in 1:executed_hours
            global_hour = start_hour + h - 1
            hour_of_day = mod(global_hour - 1, 24) + 1

            base_served = details[:demand_base][h]
            flex_served = details[:demand_flex][h]
            base_available = haskey(details, :demand_base_available) ? details[:demand_base_available][h] : base_served
            flex_available = haskey(details, :demand_flex_available) ? details[:demand_flex_available][h] : flex_served
            price = details[:prices][h]

            total_base_served += base_served
            total_flex_served += flex_served
            total_base_available += base_available
            total_flex_available += flex_available
            executed_hours_total += 1

            if flex_served + 1e-6 < flex_available
                flex_curtailed_hours += 1
            end

            bucket =
                price <= 50 ? "<=50" :
                price <= 100 ? "50-100" :
                price <= 150 ? "100-150" : ">150"

            price_bucket_counts[bucket] += 1
            price_bucket_flex[bucket] += flex_served

            flex_served_by_hour[hour_of_day] += flex_served
            flex_available_by_hour[hour_of_day] += flex_available
            hour_counts[hour_of_day] += 1
        end
    end

    avg_flex_served_by_hour = [hour_counts[h] > 0 ? flex_served_by_hour[h] / hour_counts[h] : 0.0 for h in 1:24]
    avg_flex_available_by_hour = [hour_counts[h] > 0 ? flex_available_by_hour[h] / hour_counts[h] : 0.0 for h in 1:24]

    avg_flex_by_bucket = Dict(
        label => (price_bucket_counts[label] > 0 ? price_bucket_flex[label] / price_bucket_counts[label] : 0.0)
        for label in price_bucket_labels
    )

    return Dict(
        :total_base_served => total_base_served,
        :total_flex_served => total_flex_served,
        :total_base_available => total_base_available,
        :total_flex_available => total_flex_available,
        :executed_hours_total => executed_hours_total,
        :flex_curtailed_hours => flex_curtailed_hours,
        :price_bucket_counts => price_bucket_counts,
        :avg_flex_by_bucket => avg_flex_by_bucket,
        :avg_flex_served_by_hour => avg_flex_served_by_hour,
        :avg_flex_available_by_hour => avg_flex_available_by_hour
    )
end

function plot_rolling_horizon_results(all_results::Dict;
                                      day_of_month=VIS_DAY_OF_MONTH,
                                      start_clearing_of_day::Int=VIS_START_CLEARING_OF_DAY,
                                      num_clearings_to_show::Int=VIS_NUM_CLEARINGS_TO_SHOW)
    
    clearing_details = all_results[:clearing_details]
    dispatch_dict = all_results[:dispatch]

    if isempty(clearing_details)
        error("No clearing details found in all_results.")
    end

    max_current_hour = maximum(clearing_details[c][:current_hour] for c in keys(clearing_details))
    max_day_available = Int(ceil(max_current_hour / 24))
    selected_day = day_of_month == :last ? max_day_available : Int(day_of_month)

    if selected_day < 1 || selected_day > max_day_available
        error("Invalid day_of_month=$day_of_month. Available range is 1:$max_day_available.")
    end

    day_clearings = get_clearings_for_day(clearing_details, selected_day)
    if isempty(day_clearings)
        error("No clearings found for day $selected_day.")
    end

    if start_clearing_of_day < 1 || start_clearing_of_day > length(day_clearings)
        error("Invalid start_clearing_of_day=$start_clearing_of_day for day $selected_day. Available range is 1:$(length(day_clearings)).")
    end

    last_idx_in_day = min(length(day_clearings), start_clearing_of_day + num_clearings_to_show - 1)
    clearing_indices = day_clearings[start_clearing_of_day:last_idx_in_day]
    num_selected_clearings = length(clearing_indices)
    start_clearing = clearing_indices[1]
    
    # Calculate global hour range for consistent x-axis across all plots
    start_global_hour = clearing_details[start_clearing][:current_hour]
    last_clearing = clearing_indices[end]
    last_clearing_start = clearing_details[last_clearing][:current_hour]
    end_global_hour = last_clearing_start + clearing_details[last_clearing][:look_ahead] - 1
    
    # Plot 1: Prices for the selected clearings
    p1 = plot(xlabel="Global Hour", ylabel="Price (EUR/MWh)",
              title="Prices - Day $selected_day, clearings $(start_clearing_of_day)-$(start_clearing_of_day+num_selected_clearings-1)",
              legend=:topright, linewidth=2.5, size=(1000, 400))
    
    # Define line styles and markers to distinguish overlapping lines
    line_styles = [:solid, :dash, :dot, :dashdot, :dashdotdot]
    markers = [:circle, :square, :diamond, :utriangle, :dtriangle]
    
    for (idx, clearing_num) in enumerate(clearing_indices)
        if haskey(clearing_details, clearing_num)
            details = clearing_details[clearing_num]
            clearing_start_hour = details[:current_hour]
            prices = details[:prices]
            
            # Global hours for this clearing
            local_hours = 1:length(prices)
            global_hours = clearing_start_hour .+ (local_hours .- 1)
            
            # Plot this clearing's price forecast with unique style
            plot!(p1, global_hours, prices, 
                  label="Clearing $clearing_num", 
                  linewidth=2.5,
                                    linestyle=line_styles[mod1(idx, length(line_styles))],
                                    marker=markers[mod1(idx, length(markers))],
                  markersize=4,
                  markerstrokewidth=0,
                  alpha=0.85)
        end
    end
    
    # Set consistent x-axis limits for price plot
    xlims!(p1, start_global_hour - 0.5, end_global_hour + 0.5)
    
    # Plot generator position evolution across consecutive clearings
    # Shows how g_planned and q change for each generator
    generators = ["Mid", "Wind"]
    
    # Create subplots - one for each generator
    subplots = []
    
    for gen_name in generators
        ytick_labels = vcat(["q_prev"], ["C$c" for c in clearing_indices])

        # Create subplot for this generator
        p_gen = plot(title="$gen_name", xlabel="Global Hour", ylabel="Clearing",
                    legend=false, size=(1000, 400),
                    yticks=(0:num_selected_clearings, ytick_labels),
                    yflip=true, tickfontsize=7, guidefontsize=9, titlefontsize=11)
        
        # First row: q_prev (previous position before the starting clearing)
        if haskey(clearing_details, start_clearing)
            Q_prev_dict = clearing_details[start_clearing][:Q_prev]
            clearing_start_hour = clearing_details[start_clearing][:current_hour]
            look_ahead_hours = clearing_details[start_clearing][:look_ahead]
            
            # Plot q_prev as bars using global hours
            for local_h in 1:look_ahead_hours
                global_h = clearing_start_hour + local_h - 1
                value = Q_prev_dict[(gen_name, local_h)]
                
                if value > 0.01
                    bar_color = :orange
                    plot!(p_gen, [global_h-0.4, global_h+0.4], [0, 0], fillrange=[0.4, 0.4], 
                          fillcolor=bar_color, fillalpha=0.6, linewidth=0)
                    # Add text annotation with value
                    if value >= 10  # Only show significant values
                        annotate!(p_gen, global_h, 0, text(@sprintf("%.0f", value), 6, :black))
                    end
                end
            end
        end
        
        # Next rows: q adjustments for each clearing
        for (row_idx, clearing_num) in enumerate(clearing_indices)
            if haskey(clearing_details, clearing_num)
                q_dict = clearing_details[clearing_num][:q]
                clearing_start_hour = clearing_details[clearing_num][:current_hour]
                look_ahead_hours = clearing_details[clearing_num][:look_ahead]
                
                # Plot q adjustments as bars using global hours
                for local_h in 1:look_ahead_hours
                    global_h = clearing_start_hour + local_h - 1
                    value = q_dict[gen_name, local_h]
                    
                    if abs(value) > 0.01  # Show non-zero adjustments
                        bar_color = value > 0 ? :lightgreen : :lightcoral
                        plot!(p_gen, [global_h-0.4, global_h+0.4], [row_idx, row_idx], 
                              fillrange=[row_idx+0.4, row_idx+0.4], 
                              fillcolor=bar_color, fillalpha=0.7, linewidth=0)
                        # Add text annotation with value (show +/-)
                        sign_str = value > 0 ? "+" : ""
                        annotate!(p_gen, global_h, row_idx, text(@sprintf("%s%.0f", sign_str, value), 6, :black))
                    end
                end
            end
        end
        
        # Set consistent x-axis limits across all generator plots
        xlims!(p_gen, start_global_hour - 0.5, end_global_hour + 0.5)
        ylims!(p_gen, -0.5, num_selected_clearings + 0.5)
        
        push!(subplots, p_gen)
    end
    
    # Plot 2: Generation Mix for 3 clearings (side by side stacked area plots)
    # Select 3 clearings to display
    clearings_for_mix = clearing_indices[1:min(3, length(clearing_indices))]
    
    # Generator order for stacking (bottom to top)
    gen_order = ["Base", "Mid", "Solar", "Wind", "Peak"]
    gen_colors_map = Dict("Base" => :steelblue, "Mid" => :lightblue, "Solar" => :yellow,
                          "Wind" => :lightgreen, "Peak" => :coral, "Discharge" => :gold)
    
    mix_plots = []
    for clearing_num in clearings_for_mix
        if haskey(dispatch_dict, clearing_num) && haskey(clearing_details, clearing_num)
            # Get dispatch data for this clearing
            gen_data = dispatch_dict[clearing_num]
            details = clearing_details[clearing_num]
            available_gens = filter(g -> g in keys(gen_data), gen_order)
            
            # Get the clearing start hour for title
            clearing_start_hour = details[:current_hour]
            look_ahead_hours = details[:look_ahead]
            hours = 1:look_ahead_hours
            global_hours = clearing_start_hour .+ (hours .- 1)
            
            # Get storage discharge data
            discharge_data = details[:discharging][1:look_ahead_hours]
            charging_data = details[:charging][1:look_ahead_hours]
            
            # Get demand data
            demand_base = details[:demand_base][1:look_ahead_hours]
            demand_flex = details[:demand_flex][1:look_ahead_hours]
            total_demand = demand_base .+ demand_flex
            total_demand_with_charging = total_demand .+ charging_data
            
            # Create stacked area plot
            p_mix = plot(xlabel="Local Hour", ylabel="MW",
                        title="Clearing $clearing_num (Global Hours $(global_hours[1])-$(global_hours[end]))",
                        legend=:topright, size=(320, 400), 
                        tickfontsize=7, guidefontsize=9, titlefontsize=10, legendfontsize=6,
                        yformatter=y -> y >= 1000 ? string(Int(round(y/1000))) * "k" : string(Int(round(y))))
            
            # Stack generators manually using fillrange
            cumsum_prev = zeros(look_ahead_hours)
            for gen in available_gens
                gen_values = gen_data[gen][1:look_ahead_hours]
                cumsum_curr = cumsum_prev .+ gen_values
                
                # Create filled area for this generator
                plot!(p_mix, hours, cumsum_curr,
                      fillrange=cumsum_prev, label=gen,
                      color=gen_colors_map[gen], alpha=0.8, linewidth=0)
                
                cumsum_prev = cumsum_curr
            end
            
            # Add storage discharge on top of generators
            if maximum(discharge_data) > 0.1
                cumsum_discharge = cumsum_prev .+ discharge_data
                plot!(p_mix, hours, cumsum_discharge,
                      fillrange=cumsum_prev, label="Discharge",
                      color=gen_colors_map["Discharge"], alpha=0.8, linewidth=0)
                cumsum_prev = cumsum_discharge
            end
            
            # Show charging as a line to avoid visual confusion with stacked areas.
            if maximum(charging_data) > 0.1
                plot!(p_mix, hours, total_demand_with_charging,
                      label="Charging", color=:mediumpurple, linewidth=2, linestyle=:solid)
            end
            
            # Actual demand line (no charging included)
            plot!(p_mix, hours, total_demand,
                  label="Demand", color=:black, linewidth=2, linestyle=:solid)
            
            xlims!(p_mix, 0.5, look_ahead_hours + 0.5)
            ylims!(p_mix, 0, maximum([maximum(cumsum_prev), maximum(total_demand_with_charging)]) * 1.1)
            
            push!(mix_plots, p_mix)
        end
    end
    
    # Combine all plots with equal height
    if length(subplots) == 2 && length(mix_plots) > 0
        # Create horizontal layout for generation mix plots
        p_mix_combined = plot(mix_plots..., layout=(1, length(mix_plots)), size=(1000, 400))
        plot(p1, p_mix_combined, subplots[1], subplots[2], layout=(4,1), size=(1000, 1600))
    elseif length(subplots) == 2
        plot(p1, subplots[1], subplots[2], layout=(3,1), size=(1000, 1200))
    elseif length(subplots) == 1
        plot(p1, subplots[1], layout=(2,1), size=(1000, 800))
    else
        plot(p1, layout=(1,1), size=(1000, 400))
    end
end
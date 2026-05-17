using YAML
using Dates
using Statistics
using Printf

function simulation_start_datetime(cfg::Dict)
    rh = cfg["rolling_horizon"]
    sim_month = Int(get(rh, "simulation_month", 1))
    sim_start_hour = Int(get(rh, "simulation_start_hour", 0))
    return DateTime(2025, sim_month, 1, sim_start_hour)
end

function collect_daily_executed_metrics(all_results::Dict, cfg::Dict)
    clearing_times = all_results[:clearing_times]
    details_dict = all_results[:clearing_details]
    prices_dict = all_results[:prices]
    sim_start_dt = simulation_start_datetime(cfg)

    daily = Dict{Date, Dict{Symbol, Any}}()

    for c_num in sort(collect(keys(details_dict)))
        details = details_dict[c_num]
        start_global = clearing_times[c_num]
        executed_hours = details[:executed_hours]
        prices = prices_dict[c_num]
        charging = details[:charging]
        discharging = details[:discharging]

        for h in 1:executed_hours
            global_hour = start_global + (h - 1)
            hour_dt = sim_start_dt + Hour(global_hour - 1)
            calendar_day = Date(hour_dt)

            if !haskey(daily, calendar_day)
                day_start_dt = DateTime(calendar_day)
                daily[calendar_day] = Dict{Symbol, Any}(
                    :calendar_day => calendar_day,
                    :start_datetime => day_start_dt,
                    :end_datetime => day_start_dt + Hour(23),
                    :price_sum => 0.0,
                    :price_count => 0,
                    :charge => 0.0,
                    :discharge => 0.0,
                    :wind_curtailment => 0.0,
                )
            end

            d = daily[calendar_day]
            d[:price_sum] += prices[h]
            d[:price_count] += 1
            d[:charge] += charging[h]
            d[:discharge] += discharging[h]

            if h == 1 && haskey(details, :wind_curtailment_h1)
                d[:wind_curtailment] += details[:wind_curtailment_h1]
            end
        end
    end

    metrics = [
        Dict(
            :calendar_day => day,
            :start_datetime => daily[day][:start_datetime],
            :end_datetime => daily[day][:end_datetime],
            :executed_hours => daily[day][:price_count],
            :avg_price => daily[day][:price_count] > 0 ? daily[day][:price_sum] / daily[day][:price_count] : 0.0,
            :charge => daily[day][:charge],
            :discharge => daily[day][:discharge],
            :net_storage_discharge => daily[day][:discharge] - daily[day][:charge],
            :wind_curtailment => daily[day][:wind_curtailment],
        ) for day in sort(collect(keys(daily)))
    ]

    # Keep only full 00:00-23:00 calendar days by default.
    return [m for m in metrics if m[:executed_hours] == 24]
end

function find_representative_day(all_results_a::Dict, all_results_b::Dict, cfg::Dict;
                                 label_a::String="Case A", label_b::String="Case B")
    daily_a = collect_daily_executed_metrics(all_results_a, cfg)
    daily_b = collect_daily_executed_metrics(all_results_b, cfg)

    n_days = min(length(daily_a), length(daily_b))
    n_days > 0 || error("No daily executed metrics available to compare.")

    price_diff = [daily_b[d][:avg_price] - daily_a[d][:avg_price] for d in 1:n_days]
    storage_diff = [daily_b[d][:net_storage_discharge] - daily_a[d][:net_storage_discharge] for d in 1:n_days]
    curtail_diff = [daily_b[d][:wind_curtailment] - daily_a[d][:wind_curtailment] for d in 1:n_days]

    med_price = median(price_diff)
    med_storage = median(storage_diff)
    med_curtail = median(curtail_diff)

    mad_price = max(median(abs.(price_diff .- med_price)), 1e-9)
    mad_storage = max(median(abs.(storage_diff .- med_storage)), 1e-9)
    mad_curtail = max(median(abs.(curtail_diff .- med_curtail)), 1e-9)

    scores = Float64[]
    for d in 1:n_days
        score =
            abs((price_diff[d] - med_price) / mad_price) +
            abs((storage_diff[d] - med_storage) / mad_storage) +
            abs((curtail_diff[d] - med_curtail) / mad_curtail)
        push!(scores, score)
    end

    rep_day_idx = argmin(scores)
    rep_a = daily_a[rep_day_idx]
    rep_b = daily_b[rep_day_idx]

    println()
    println("REPRESENTATIVE DAY SELECTION")
    println("-"^80)
    println("Rule: choose the day whose $(label_b)-minus-$(label_a) difference is closest")
    println("to the median daily difference across three metrics:")
    println("  average executed price, net storage discharge, and wind curtailment.")
    println()
    println("Selected calendar day: $(rep_a[:calendar_day])")
    println("Start: $(rep_a[:start_datetime]) | End: $(rep_a[:end_datetime])")
    println(@sprintf("Closeness score: %.3f", scores[rep_day_idx]))
    println()
    println(@sprintf("%-18s %-14s %-14s %-14s", "Metric", label_a, label_b, "$(label_b)-$(label_a)"))
    println(@sprintf("%-18s %-14.2f %-14.2f %-14.2f", "Avg Price", rep_a[:avg_price], rep_b[:avg_price], price_diff[rep_day_idx]))
    println(@sprintf("%-18s %-14.2f %-14.2f %-14.2f", "Net Storage", rep_a[:net_storage_discharge], rep_b[:net_storage_discharge], storage_diff[rep_day_idx]))
    println(@sprintf("%-18s %-14.2f %-14.2f %-14.2f", "Wind Curtail.", rep_a[:wind_curtailment], rep_b[:wind_curtailment], curtail_diff[rep_day_idx]))
    println()
    println(@sprintf("%-18s %-14s %-14s %-14s", "Median Diff", "", "", ""))
    println(@sprintf("%-18s %-14s %-14s %-14.2f", "Avg Price", "", "", med_price))
    println(@sprintf("%-18s %-14s %-14s %-14.2f", "Net Storage", "", "", med_storage))
    println(@sprintf("%-18s %-14s %-14s %-14.2f", "Wind Curtail.", "", "", med_curtail))
    println("-"^80)

    return Dict(
        :representative_day_index => rep_day_idx,
        :calendar_day => rep_a[:calendar_day],
        :start_datetime => rep_a[:start_datetime],
        :end_datetime => rep_a[:end_datetime],
        :score => scores[rep_day_idx],
        :case_a => rep_a,
        :case_b => rep_b,
        :median_differences => Dict(
            :avg_price => med_price,
            :net_storage_discharge => med_storage,
            :wind_curtailment => med_curtail,
        ),
        :all_scores => scores,
    )
end

println("Loaded representative-day analysis helpers.")
println("Use: find_representative_day(all_results_fixed, all_results_rolling, cfg; label_a=\"Fixed\", label_b=\"Rolling\")")

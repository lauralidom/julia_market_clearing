# check_data.jl
# ============================================================
# Standalone data inspection script – no model needed.
#
# For each data source it:
#   • Plots all 12 months as separate lines in one graph
#     (x-axis = hour index within the month)
#   • Prints the minimum and maximum value per month
#
# Edit the SHOW_* flags below to select which datasets to run.
# Plots are saved to Results/ and also displayed interactively.
# ============================================================

using CSV, DataFrames, Dates, Plots, Printf

# ---- Configuration: toggle what to inspect ----
SHOW_DEMAND  = true
SHOW_SOLAR   = true
SHOW_WINDON  = true
SHOW_WINDOFF = true

# Which months to include (1 = Jan … 12 = Dec).
# Use 1:12 for all months, or e.g. [5] for May only, or [1,2,3] for Q1.
SHOW_MONTHS = [5]

# Set to true to overlay all enabled datasets on one shared graph.
# Labels will read "Demand – May", "Solar – May", etc.
# Set to false for one separate graph per dataset (original behaviour).
COMBINE_PLOT = true

# -------------------------------------------------------
const DATA_DIR    = dirname(@__FILE__)
const RESULTS_DIR = joinpath(DATA_DIR, "Results")

MONTH_NAMES = ["Jan","Feb","Mar","Apr","May","Jun",
               "Jul","Aug","Sep","Oct","Nov","Dec"]

# -------------------------------------------------------
# Load a NED-style CSV.
#   Returns (Vector{DateTime}, Vector{Float64}) in MW
# -------------------------------------------------------
function load_ned_csv(filename::String)
    path = joinpath(DATA_DIR, "data", filename)
    df   = CSV.read(path, DataFrame)

    # Trim any surrounding whitespace / quotes that some CSV writers add
    raw = strip.(string.(df[!, "validfrom (UTC)"]))

    # Support both old and new provider timestamp formats.
    dates = try
        DateTime.(raw, dateformat"yyyy-mm-dd HH:MM:SS")
    catch
        try
            DateTime.(raw, dateformat"dd/mm/yyyy HH:MM")
        catch
            error("Could not parse 'validfrom (UTC)' in $filename. Supported formats: yyyy-mm-dd HH:MM:SS and dd/mm/yyyy HH:MM")
        end
    end

    values_mw = Float64.(df[!, "volume (kWh)"]) ./ 1000.0   # kW → MW
    return dates, values_mw
end

# Line styles cycled per dataset when combining multiple sources.
DATASET_STYLES = [:solid, :dash, :dot, :dashdot]

# -------------------------------------------------------
# Build (or add to) a plot with selected monthly lines and
# print min/max to the console.
#
#   p            – pass an existing plot to overlay onto it,
#                  or nothing to create a fresh one
#   label_prefix – prepended to month name in the legend,
#                  e.g. "Demand" → label reads "Demand – Jan"
#   style        – line style (:solid, :dash, etc.)
# -------------------------------------------------------
function plot_and_print(dates::Vector{DateTime},
                        values_mw::Vector{Float64},
                        title_str::String,
                        months = 1:12;
                        p = nothing,
                        label_prefix::String = "",
                        style::Symbol = :solid)

    if isnothing(p)
        p = plot(
            title    = title_str,
            xlabel   = "Hour of month",
            ylabel   = "Power (MW)",
            legend   = :outertopright,
            size     = (1300, 500),
            linewidth = 1.2,
            palette  = :tab20,
        )
    end

    println("\n" * "="^54)
    println("  $title_str")
    println("="^54)
    println(@sprintf("  %-6s  %13s  %13s", "Month", "Min (MW)", "Max (MW)"))
    println("  " * "-"^36)

    for m in months
        mask = (Dates.year.(dates)  .== 2025) .&
               (Dates.month.(dates) .== m)

        if !any(mask)
            println(@sprintf("  %-6s  %13s  %13s", MONTH_NAMES[m], "–", "–"))
            continue
        end

        sub_dates = dates[mask]
        sub_vals  = values_mw[mask]

        # Ensure chronological order within the month
        ord      = sortperm(sub_dates)
        sub_vals = sub_vals[ord]

        lbl = isempty(label_prefix) ? MONTH_NAMES[m] : "$(label_prefix) – $(MONTH_NAMES[m])"
        plot!(p, 1:length(sub_vals), sub_vals;
              label     = lbl,
              linestyle = style,
              alpha     = 0.80)

        println(@sprintf("  %-6s  %13.1f  %13.1f",
                MONTH_NAMES[m], minimum(sub_vals), maximum(sub_vals)))
    end

    return p
end

# -------------------------------------------------------
# Main
# -------------------------------------------------------
mkpath(RESULTS_DIR)

println("Loading CSV files …")

if SHOW_DEMAND
    demand_dates, demand_mw = load_ned_csv("demand_data_2025_ned2.csv")
end
if SHOW_SOLAR
    solar_dates,  solar_mw  = load_ned_csv("solar_data_2025_ned.csv")
end
if SHOW_WINDON
    windon_dates, windon_mw = load_ned_csv("windon_data_2025_ned.csv")
end
if SHOW_WINDOFF
    windoff_dates, windoff_mw = load_ned_csv("windoff_data_2025_ned.csv")
end

println("Done.\n")

if COMBINE_PLOT
    # ----------------------------------------------------------
    # Combined mode: all enabled datasets on one shared graph.
    # Each dataset gets a different line style; months get colors.
    # ----------------------------------------------------------
    enabled = Tuple{Vector{DateTime}, Vector{Float64}, String}[]
    SHOW_DEMAND  && push!(enabled, (demand_dates,  demand_mw,  "Demand"))
    SHOW_SOLAR   && push!(enabled, (solar_dates,   solar_mw,   "Solar"))
    SHOW_WINDON  && push!(enabled, (windon_dates,  windon_mw,  "Wind Onshore"))
    SHOW_WINDOFF && push!(enabled, (windoff_dates, windoff_mw, "Wind Offshore"))

    dataset_names = join([e[3] for e in enabled], " vs ")
    combined_title = "$dataset_names 2025"

    local p_combined = nothing
    for (i, (dates, vals, name)) in enumerate(enabled)
        style = DATASET_STYLES[mod1(i, length(DATASET_STYLES))]
        p_combined = plot_and_print(dates, vals, combined_title, SHOW_MONTHS;
                                    p = p_combined, label_prefix = name, style = style)
    end

    if !isnothing(p_combined)
        display(p_combined)
        fname = replace(lowercase(dataset_names), " " => "_") * ".png"
        savefig(p_combined, joinpath(RESULTS_DIR, "data_check_combined_" * fname))
    end
else
    # ----------------------------------------------------------
    # Separate mode: one graph per dataset.
    # ----------------------------------------------------------
    if SHOW_DEMAND
        p_demand = plot_and_print(demand_dates, demand_mw, "Demand 2025", SHOW_MONTHS)
        display(p_demand)
        savefig(p_demand, joinpath(RESULTS_DIR, "data_check_demand.png"))
    end

    if SHOW_SOLAR
        p_solar = plot_and_print(solar_dates, solar_mw, "Solar 2025", SHOW_MONTHS)
        display(p_solar)
        savefig(p_solar, joinpath(RESULTS_DIR, "data_check_solar.png"))
    end

    if SHOW_WINDON
        p_windon = plot_and_print(windon_dates, windon_mw, "Wind Onshore 2025", SHOW_MONTHS)
        display(p_windon)
        savefig(p_windon, joinpath(RESULTS_DIR, "data_check_windon.png"))
    end

    if SHOW_WINDOFF
        p_windoff = plot_and_print(windoff_dates, windoff_mw, "Wind Offshore 2025", SHOW_MONTHS)
        display(p_windoff)
        savefig(p_windoff, joinpath(RESULTS_DIR, "data_check_windoff.png"))
    end
end

println("\nAll plots saved to: $RESULTS_DIR")

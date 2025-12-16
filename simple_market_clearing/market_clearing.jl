using XLSX
using DataFrames
using JuMP
using HiGHS
using Plots

# Step 1: load Excel data
function load_input_data(path::String)
    xf = XLSX.readxlsx(path)

    # convert sheet to DataFrame
    function sheet_df(name::String)
        ws  = xf[name]
        tbl = XLSX.gettable(ws)
        return DataFrame(tbl)
    end

    # load all raw sheets
    system_df = sheet_df("System")
    gen_df    = sheet_df("Supply")
    dem_df    = sheet_df("Demand")
    ramp_df   = sheet_df("Ramping")

    # extract values from System sheet
    ind_T      = findfirst(system_df.Code .== "T")
    ind_rmp    = findfirst(system_df.Code .== "crt_rmp")
    T          = Int(system_df.Value[ind_T])
    constr_rmp = Int(system_df.Value[ind_rmp])

    # store everything in data dictionary
    data = Dict{Symbol,Any}()
    data[:system]     = system_df
    data[:gen]        = gen_df
    data[:dem]        = dem_df
    data[:ramp]       = ramp_df
    data[:T]          = T
    data[:constr_rmp] = constr_rmp

    return data
end


# Step 2a: create lists for the variables
function define_sets!(m::Model, data::Dict{Symbol,Any})
    m.ext[:sets] = Dict{Symbol,Any}()

    # clarity: extract needed tables
    gen_df = data[:gen]
    dem_df = data[:dem]
    T      = data[:T]

    # time periods
    m.ext[:sets][:JH] = 1:T

    # generators
    m.ext[:sets][:IG] = unique(gen_df.Player)

    # demands
    m.ext[:sets][:ID] = unique(dem_df.Player)

    return m
end


# Step 2b: process time-series data
function process_time_series_data!(m::Model, data::Dict{Symbol,Any})
    # clarity: extract relevant structures
    gen_df = data[:gen]
    dem_df = data[:dem]

    JH = m.ext[:sets][:JH]
    IG = m.ext[:sets][:IG]
    ID = m.ext[:sets][:ID]

    # create empty dictionaries
    Pr_gen  = Dict{Tuple{String,Int},Float64}()
    Max_gen = Dict{Tuple{String,Int},Float64}()

    # generator prices and max quantities
    for row in eachrow(gen_df)
        g = String(row.Player)
        h = Int(row.Hour)
        Pr_gen[(g,h)]  = float(row.Ps)
        Max_gen[(g,h)] = float(row.Ms)
    end

    # demand prices and max quantities
    Pr_dem  = Dict{Tuple{String,Int},Float64}()
    Max_dem = Dict{Tuple{String,Int},Float64}()

    for row in eachrow(dem_df)
        d = String(row.Player)
        h = Int(row.Hour)
        Pr_dem[(d,h)]  = float(row.Pd)
        Max_dem[(d,h)] = float(row.Md)
    end

    # store processed time series
    m.ext[:timeseries] = Dict{Symbol,Any}()
    m.ext[:timeseries][:Pr_gen]  = Pr_gen
    m.ext[:timeseries][:Max_gen] = Max_gen
    m.ext[:timeseries][:Pr_dem]  = Pr_dem
    m.ext[:timeseries][:Max_dem] = Max_dem

    return m
end



# Step 2c: scalar parameters (ramping)
function process_parameters!(m::Model, data::Dict{Symbol,Any})
    ramp_df = data[:ramp]
    IG      = m.ext[:sets][:IG]

    R_dw   = Dict{String,Float64}()
    R_up   = Dict{String,Float64}()
    G_init = Dict{String,Float64}()

    # loop through generators
    for g in IG
        ind = findfirst(==(g), ramp_df.ID)
        row = ramp_df[ind, :]
        R_dw[String(g)]   = float(row.RampDown)
        R_up[String(g)]   = float(row.RampUp)
        G_init[String(g)] = float(row.Initial)
    end

    m.ext[:parameters] = Dict{Symbol,Any}()
    m.ext[:parameters][:R_dw]      = R_dw
    m.ext[:parameters][:R_up]      = R_up
    m.ext[:parameters][:G_init]    = G_init
    m.ext[:parameters][:constr_rmp] = data[:constr_rmp]

    return m
end



# Step 3: build model
function build_market_clearing!(m::Model)
    m.ext[:variables]   = Dict()
    m.ext[:expressions] = Dict()
    m.ext[:constraints] = Dict()

    JH = m.ext[:sets][:JH]
    IG = m.ext[:sets][:IG]
    ID = m.ext[:sets][:ID]

    Pr_gen  = m.ext[:timeseries][:Pr_gen]
    Max_gen = m.ext[:timeseries][:Max_gen]
    Pr_dem  = m.ext[:timeseries][:Pr_dem]
    Max_dem = m.ext[:timeseries][:Max_dem]

    R_dw       = m.ext[:parameters][:R_dw]
    R_up       = m.ext[:parameters][:R_up]
    G_init     = m.ext[:parameters][:G_init]
    constr_rmp = m.ext[:parameters][:constr_rmp]

    # Define demand and generation variables
    Qd = m.ext[:variables][:Qd] = @variable(m, Qd[d in ID, h in JH] >= 0)
    Qg = m.ext[:variables][:Qg] = @variable(m, Qg[g in IG, h in JH] >= 0)

    # objective
    m.ext[:objective] = @objective(m, Max,
        sum(Pr_dem[(String(d),h)] * Qd[d,h] for d in ID, h in JH) -
        sum(Pr_gen[(String(g),h)] * Qg[g,h] for g in IG, h in JH)
    )

    # energy balance
    m.ext[:constraints][:energy_balance] = @constraint(
        m, [h in JH],
        sum(Qg[g,h] for g in IG) - sum(Qd[d,h] for d in ID) == 0
    )

    # limits
    m.ext[:constraints][:gen_limits] = @constraint(
        m, [g in IG, h in JH], Qg[g,h] <= Max_gen[(String(g),h)]
    )

    m.ext[:constraints][:dem_limits] = @constraint(
        m, [d in ID, h in JH], Qd[d,h] <= Max_dem[(String(d),h)]
    )

    # ramping
    if constr_rmp == 1
        m.ext[:constraints][:constr_rmp_down] = @constraint(
            m, [g in IG, h in JH; h > first(JH)],
            -R_dw[String(g)] - Qg[g,h] + Qg[g,h-1] <= 0
        )

        m.ext[:constraints][:constr_rmp_up] = @constraint(
            m, [g in IG, h in JH; h > first(JH)],
            Qg[g,h] - Qg[g,h-1] - R_up[String(g)] <= 0
        )

        m.ext[:constraints][:constr_rmp_down_h1] = @constraint(
            m, [g in IG],
            -R_dw[String(g)] - Qg[g,first(JH)] + G_init[String(g)] <= 0
        )

        m.ext[:constraints][:constr_rmp_up_h1] = @constraint(
            m, [g in IG],
            Qg[g,first(JH)] - G_init[String(g)] - R_up[String(g)] <= 0
        )
    end

    return m
end



# Step 4: solve
data = load_input_data("Input.xlsx")

m = Model(HiGHS.Optimizer)

define_sets!(m, data)
process_time_series_data!(m, data)
process_parameters!(m, data)

build_market_clearing!(m)
optimize!(m)

println("Termination status: ", termination_status(m))
println("Objective value: ", objective_value(m))

Qg_val = value.(m.ext[:variables][:Qg])
Qd_val = value.(m.ext[:variables][:Qd])

# Step 5: plot results
JH = m.ext[:sets][:JH]
λ  = dual.(m.ext[:constraints][:energy_balance])   # hourly prices

hours  = collect(JH)
prices = [λ[h] for h in JH]

plot(
    hours,
    prices,
    xlabel = "Hour",
    ylabel = "Price",
    title  = "Market-clearing price per hour",
    marker = :circle,
    legend = false,
)

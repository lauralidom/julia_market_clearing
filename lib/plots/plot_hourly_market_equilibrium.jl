module PlotHourlyMarketEquilibrium

using Plots
using JuMP
using Statistics

function plot(m::Model, h::Int)
    # Extract the necessary data
    Pr_gen = m.ext[:timeseries][:Pr_gen]
    Q_gen  = m.ext[:timeseries][:Q_gen]
    Pr_dem = m.ext[:timeseries][:Pr_dem]
    Q_dem  = m.ext[:timeseries][:Q_dem]
    
    IG = m.ext[:sets][:IG]
    ID = m.ext[:sets][:ID]

    # Collect generator (supply) data for hour h
    supply_prices = Float64[]
    supply_quantities = Float64[]
    for g in IG
        push!(supply_prices, Pr_gen[(g, h)])
        push!(supply_quantities, Q_gen[(g, h)])
    end

    # Collect demand data for hour h
    demand_prices = Float64[]
    demand_quantities = Float64[]
    for d in ID
        push!(demand_prices, Pr_dem[(d, h)])
        push!(demand_quantities, Q_dem[(d, h)])
    end

    # Sort supply by price (ascending - merit order)
    supply_order = sortperm(supply_prices)
    supply_prices = supply_prices[supply_order]
    supply_quantities = supply_quantities[supply_order]
    
    # Sort demand by price (descending)
    demand_order = sortperm(demand_prices, rev=true)
    demand_prices = demand_prices[demand_order]
    demand_quantities = demand_quantities[demand_order]
    
    # Create step functions for supply curve
    supply_x = Float64[]
    supply_y = Float64[]
    cumsum_q = 0.0
    for i in 1:length(supply_prices)
        # Horizontal line at current price level
        push!(supply_x, cumsum_q)
        push!(supply_y, supply_prices[i])
        cumsum_q += supply_quantities[i]
        push!(supply_x, cumsum_q)
        push!(supply_y, supply_prices[i])
    end
    
    # Create step functions for demand curve
    demand_x = Float64[]
    demand_y = Float64[]
    cumsum_q = 0.0
    for i in 1:length(demand_prices)
        # Horizontal line at current price level
        push!(demand_x, cumsum_q)
        push!(demand_y, demand_prices[i])
        cumsum_q += demand_quantities[i]
        push!(demand_x, cumsum_q)
        push!(demand_y, demand_prices[i])
    end
    
    # Plot
    p = Plots.plot(xlabel="Quantity (MW)", ylabel="Price (EUR/MWh)", 
             title="Market Equilibrium - Hour $h", legend=:best, 
             xlims = (0, maximum([supply_x; demand_x])), 
             ylims = (0, maximum([supply_y; demand_y]) * 1.05))
    
    Plots.plot!(p, supply_x, supply_y, label="Supply", color=:blue, linewidth=2)
    Plots.plot!(p, demand_x, demand_y, label="Demand", color=:red, linewidth=2)
    
    display(p)
    return p
end

end;
# MARKET CLEARING MODEL BUILDER
# 
# Rolling horizon intraday market with gate closure and flexibility provisions:
# - q_prev: financial position from previous clearing
# - q: adjustment in current clearing (can be negative to buy back)
# - g_planned: updated physical position = q_prev + q
# - Gate closure locks Base generators to q_prev
# - Peak generator remains flexible to balance wind forecast updates
# - Wind gets fresh forecasts every clearing (converging to reality at h=1)

using JuMP

function build_market_clearing!(m::Model)

    m.ext[:variables]   = Dict{Symbol,Any}()
    m.ext[:constraints] = Dict{Symbol,Any}()

    # Step 1: Load sets and data
    JH = m.ext[:sets][:JH]
    IG = m.ext[:sets][:IG]
    ID = m.ext[:sets][:ID]

    Pr_gen = m.ext[:timeseries][:Pr_gen]   # marginal generation cost (or offer) [€/MWh]
    Q_gen  = m.ext[:timeseries][:Q_gen]    # physical capacity upper bound [MW]
    Pr_dem = m.ext[:timeseries][:Pr_dem]   # demand value (bid) [€/MWh]
    Q_dem  = m.ext[:timeseries][:Q_dem]    # demand cap [MW]
    q_prev = m.ext[:timeseries][:Q_prev]   # FINANCIAL position from earlier trading [MW]

    # Step 2: Decision variables
    # Qd[d,h] = served demand of segment d in hour h [MW]
    Qd = m.ext[:variables][:Qd] = @variable(m, Qd[d in ID, h in JH] >= 0)

    # q[g,h] = generator adjustment trade relative to financial position q_prev [MW]
    # q < 0 means buy-back; q > 0 means sell more
    q = m.ext[:variables][:q] = @variable(m, q[g in IG, h in JH])

    # g_planned[g,h] = updated position (commitments + adjustment) [MW]
    g_planned = m.ext[:variables][:g_planned] = @variable(m, g_planned[g in IG, h in JH] >= 0)

    # Step 3: Storage parameters
    E_cap = m.ext[:parameters][:storage_energy_capacity]
    P_cap = m.ext[:parameters][:storage_power_capacity]
    η = m.ext[:parameters][:storage_efficiency]
    SOC_init = m.ext[:parameters][:storage_initial_soc]

    Qch = m.ext[:variables][:Qch]  = @variable(m, 0 <= Qch[h in JH]  <= P_cap)
    Qdis = m.ext[:variables][:Qdis] = @variable(m, 0 <= Qdis[h in JH] <= P_cap)
    SOC = m.ext[:variables][:SOC]  = @variable(m, 0 <= SOC[h in JH]  <= E_cap)

    # Step 4: Link financial positions after adjustment
    # Definition: g_planned = q_prev + q
    m.ext[:constraints][:link_positions] = @constraint(
        m, [g in IG, h in JH],
        g_planned[g,h] == q_prev[(String(g),h)] + q[g,h]
    )

    # Step 5: Physical generator limits (apply to g_planned)
    m.ext[:constraints][:gen_cap] = @constraint(
        m, [g in IG, h in JH],
        g_planned[g,h] <= Q_gen[(String(g),h)]
    )

    # Step 6: Buy-back / adjustment bounds implied by 0 <= g_planned <= Q_gen
    # -q_prev <= q <= Q_gen - q_prev
    # adjustment q can only buy back up to what you previously sold (-q_prev)
    # you can only sell more what you have remaining of your max capacity (Q_gen - q_prev)
    m.ext[:constraints][:q_lower] = @constraint(
        m, [g in IG, h in JH],
        q[g,h] >= -q_prev[(String(g),h)]
    )
    m.ext[:constraints][:q_upper] = @constraint(
        m, [g in IG, h in JH],
        q[g,h] <= Q_gen[(String(g),h)] - q_prev[(String(g),h)]
    )

    # Step 7: Demand limit
    m.ext[:constraints][:dem_limits] = @constraint(
        m, [d in ID, h in JH],
        Qd[d,h] <= Q_dem[(String(d),h)]
    )

    # Step 8: Physical energy balance
    m.ext[:constraints][:energy_balance] = @constraint(
        m, [h in JH],
        sum(g_planned[g,h] for g in IG) + Qdis[h] - Qch[h] - sum(Qd[d,h] for d in ID) == 0
    )

    # Step 9: Storage SOC dynamics
    m.ext[:constraints][:soc_h1] = @constraint(
        m, SOC[1] == SOC_init + η * Qch[1] - Qdis[1] / η
    )

    m.ext[:constraints][:soc_dyn] = @constraint(
        m, [h in JH; h > 1],
        SOC[h] == SOC[h-1] + η * Qch[h] - Qdis[h] / η
    )

    # Step 10: Rolling horizon gate closure constraints
    # Gate closure locks dispatchable generators except Peak
    # Peak remains flexible to balance demand/supply
    # Wind remains flexible because of stochastic forecast updates
    # q[g,h] = 0 means g_planned[g,h] = q_prev[g,h] (locked to previous commitment)
    gate_closure = m.ext[:parameters][:gate_closure]
    m.ext[:constraints][:no_trade_locked_hours] = @constraint(
        m, [g in IG, h in JH; h <= gate_closure && String(g) != "Peak" && String(g) != "Wind"],
        q[g,h] == 0
    )

    # Step 11: Welfare objective (physical costs and demand value only)
    m.ext[:objective] = @objective(m, Max,
        sum(Pr_dem[(String(d),h)] * Qd[d,h] for d in ID, h in JH) -
        sum(Pr_gen[(String(g),h)] * g_planned[g,h] for g in IG, h in JH)
    )

    return m
end

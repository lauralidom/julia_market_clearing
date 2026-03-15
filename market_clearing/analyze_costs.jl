# ANALYZE COSTS AND REVENUE FROM SIMULATION
# Run this after market_clearing_rolling.jl OR market_clearing_fixed.jl
# Works with all clearing modes (rolling horizon, fixed rolling, simple 24h)

using YAML
using Printf

include("src/costs.jl")

# Check if all_results exists in workspace
if !@isdefined(all_results)
    error("all_results not found. Please run a market clearing simulation first.")
end

if !@isdefined(cfg)
    println("Loading configuration...")
    cfg = YAML.load_file("input_data_rolling.yaml")
end

# Print summary and export to Excel
print_cost_summary(all_results, cfg)

excel_path = "economic_summary.xlsx"
saved_path = export_full_summary_to_excel(all_results, cfg; path=excel_path)
println("\nSaved summary to: $(saved_path)")

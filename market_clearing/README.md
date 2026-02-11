# Rolling Horizon Market Clearing Model

## Project Structure

28/12 Refactored project into a modular architecture for better code organisation.

simple_market_clearing/
├── market_clearing_rolling.jl          # Main entry point 
├── input_data_rolling.yaml             # Data file
│
└── src/                                # Source code modules
    ├── MarketClearing.jl               # Module definition (imports all submodules)
    ├── data_loading.jl                 # Data loading from YAML
    ├── model_setup.jl                  # Helper functions 
    ├── market_model.jl                 # JuMP model builder 
    └── visualization.jl                # Plotting functions

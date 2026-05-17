# Rolling Horizon Market Clearing Model

This repository contains the Julia code for a thesis model about electricity market clearing.

In simple words: the model clears an electricity market many times. At each clearing it decides how much electricity should come from generators, wind, solar, and a battery. It compares different market designs, especially:

- a fixed horizon market, where the market looks to a fixed end point;
- a rolling horizon market, where the look-ahead window moves forward;
- longer look-ahead windows, such as 36, 48, and 72 hours;
- normal storage and larger storage cases.

The main goal is to see how these choices affect welfare, prices, storage use, curtailment, imbalance, and computation time.

## How To Run

Use Julia from the repository root:

```powershell
julia --project=. run_thesis_cases.jl
```

The main switchboard is `run_thesis_cases.jl`.

At the top of that file you can choose:

- `RUN_SET = "baseline"` for Fixed 36h and Rolling 36h;
- `RUN_SET = "foresight"` for Rolling 36h, 48h, and 72h;
- `RUN_SET = "high_storage"` for the high-storage cases;
- `RUN_SET = "all"` for all main thesis cases;
- `RUN_SET = "custom"` if you only want selected case names.

Results are written to:

```text
Results/thesis_runs/
```

## Main Files

### `run_thesis_cases.jl`

This is the easiest file to start from. It chooses which cases to run and calls the runner in `src/thesis_runner.jl`.

This is also the file where you normally change the experiment setup. For example, you can choose whether to run the baseline cases, foresight cases, high-storage cases, all cases, or only a custom list.

### `input_data_rolling.yaml`

This is the main input file. It contains:

- simulation length and month;
- look-ahead window;
- reclearing frequency;
- gate closure;
- wind forecast noise settings;
- generator capacities and bid prices;
- battery size and efficiency;
- demand settings;
- paths to the input CSV data.

### `src/thesis_runner.jl`

This is the thesis workflow runner. It:

- loads the YAML input;
- applies case overrides;
- runs fixed and rolling cases;
- saves results;
- creates KPI summaries;
- creates thesis comparison figures;
- optionally runs daily-driver analysis.

### `market_clearing_rolling.jl`

This runs one rolling horizon case. The market is cleared repeatedly, and the look-ahead window moves forward through time.

### `market_clearing_fixed_continuous.jl`

This is the default fixed horizon case used by the thesis runner. It keeps physical storage state continuous while using fixed-horizon market logic.

### `market_clearing_fixed.jl`

This is an older fixed horizon variant. It can still be selected through `runner_variant = "original_24h"` in a case definition, but it is not the default path.

Most users can start with `run_thesis_cases.jl` and do not need to run the market-clearing scripts directly.

## Source Folder

### `src/model_setup.jl`

Loads input data, expands time series, applies simulation month settings, and creates wind forecast error scenarios.

### `src/market_model.jl`

Builds the JuMP optimisation model. This is where the market-clearing equations and constraints are created.

### `src/costs.jl`

Calculates welfare, costs, revenues, storage metrics, daily summaries, and Excel exports.

### `src/visualisation.jl`

Contains plotting and diagnostic helper functions.

## Data Folder

The `data/` folder contains the CSV input data used by the model:

- demand data;
- solar data;
- onshore wind data;
- offshore wind data;
- export data.

The YAML file points to the exact files used in the current model run.

## Analysis And Tests

### `further_analysis/`

These scripts are extra analysis scripts used after model runs. They are not all needed to run the core model. One important exception is:

```text
further_analysis/analyze_daily_driver_patterns.jl
```

This file is called by `src/thesis_runner.jl` when `RUN_DAILY_DRIVER_ANALYSIS = true`.

The other files in this folder are mainly for extra thesis checks, extra plots, and post-run explanation of specific results.

### `test/`

Small test files for important helper logic. Run them with:

```powershell
julia --project=. test/runtests.jl
```

### `scripts/`

Small helper scripts, currently mainly for generating wind forecast error CSV files.

## What Usually Should Not Go To GitHub

Generated outputs should usually stay out of GitHub:

- `Results/`, except shared input CSVs that are needed by the default config;
- `.julia_depot/`;
- root-level result images;
- root-level generated Excel files;
- temporary helper files.

The `.gitignore` file is set up to help with this.

## Suggested Repository Shape

A clean version of the repository should mainly contain:

```text
Project.toml
Manifest.toml
README.md
input_data_rolling.yaml
run_thesis_cases.jl
market_clearing_rolling.jl
market_clearing_fixed_continuous.jl
market_clearing_fixed.jl
src/
data/
scripts/
test/
further_analysis/
Results/thesis_runs/_shared_inputs/
```

The shared input folder is included because the default wind forecast noise settings point to CSV files there.

## Packages

The project uses the Julia environment files:

- `Project.toml`;
- `Manifest.toml`.

Keep both files if you want others to reproduce the same package versions.

# moonsweep

[![test](https://github.com/dunne67/moonsweep/actions/workflows/test.yml/badge.svg)](https://github.com/dunne67/moonsweep/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Lua](https://img.shields.io/badge/Lua-5.1%20%7C%205.2%20%7C%205.3%20%7C%205.4%20%7C%20LuaJIT-blue.svg)](https://www.lua.org)

Fast, exact-probability Minesweeper solver in pure Lua (5.1+ / LuaJIT), single file, zero dependencies.

Given any board position and total mine count, `moonsweep` computes the mathematically exact probability of every unknown tile being a mine by combining arc-consistency constraint reduction, frontier dynamic programming per independent cluster, and polynomial distribution convolution with unconstrained board tiles.

---

## Features

- **Exact probabilities**: Produces exact combinatorial probabilities (accounting for global mine count) whenever the frontier state cap is not exceeded.
- **8 board modes**:
  - `Regular`: Standard 8-neighbor Moore neighborhood.
  - `Large`: Extended 2-step radius (up to 24 neighbors).
  - `Cornerless`: 4 orthogonal neighbors (von Neumann neighborhood).
  - `Corners`: 4 diagonal-only neighbors.
  - `Knight`: Chess knight moves (up to 8 neighbors).
  - `Cross`: Orthogonal ray up to 2 steps (up to 8 neighbors).
  - `Wrap`: Toroidal wrapping grid (Regular offsets with cylindrical/toroidal edges).
  - `Calculative`: Clues encoded with modular arithmetic (quotient/remainder).
- **Deterministic by default**: Time limits are disabled by default so calculations produce identical results on any machine or CPU speed.
- **Incremental updates**: `SetCell` and `Reset` allow game engines and simulators to reveal tiles step-by-step without leftover state.
- **Status reporting**: Exposes `board.Status = "ok" | "contradiction" | "approximate"` and `board.Exact = true | false` so callers know when probabilities are exact, approximate, or mathematically contradictory.
- **Single file**: Entire engine contained in `moonsweep.lua` with zero external dependencies.

---

## Installation

### Direct Copy
Copy [`moonsweep.lua`](moonsweep.lua) into your project or module path:
```lua
local MS = require("moonsweep")
```

### LuaRocks (coming soon)
```bash
# Will be published upon v1.0.0 release
luarocks install moonsweep
```

---

## Quick Start

```lua
local MS = require("moonsweep")

-- Construct a 4x3 board with 3 total mines in standard mode
local board = MS.BuildBoard({
    "EE1?",
    "112?",
    "????",
}, 3, "Regular")

MS.Solve(board)

print(string.format("Status: %s (Exact: %s)", board.Status, tostring(board.Exact)))
print("\nBoard view:")
print(MS.Format(board))

print("\nProbabilities:")
print(MS.Format(board, true))

local bestTile, risk = MS.BestMove(board)
if bestTile then
    print(string.format("\nBest move: col %d, row %d (risk: %.1f%%)",
        bestTile.X, bestTile.Z, risk * 100))
end
```

### Output:
```
Status: ok (Exact: true)

Board view:
EE1?
112?
*ss*

Probabilities:
    E    E    1  50%
    1    1    2  50%
    *    s    s    *

Best move: col 2, row 3 (risk: 0.0%)
```

---

## Board Format & Coordinates

### Coordinates
- **`X`** = Column index from the left, starting at `1` to `width`.
- **`Z`** = Row index from the top, starting at `1` to `height`.

### Cell Representation
Rows can be passed as strings (one character per tile) or tables of cell values:
| Symbol | Meaning |
|---|---|
| `?` | Unknown unrevealed cell |
| `E`, `e`, `0`, `" "` | Revealed safe empty tile (clue `0`, all neighbors safe) |
| `1`..`9` | Revealed numbered clue |
| `M`, `m`, `F`, `f` | Confirmed/flagged mine |
| `.` | Void / no tile at this coordinate |
| Number `n` | Raw numerical clue (e.g. `> 9` in `Calculative` mode) |

---

## API Reference

### `MS.BuildBoard(rows, [totalMines], [modeName]) -> board`
Validates input and constructs a board object.
- `rows`: Array of strings or tables of cell values.
- `totalMines`: Total mines on the board (integer). If omitted, estimated via standard density rules.
- `modeName`: One of `"Regular"`, `"Large"`, `"Cornerless"`, `"Corners"`, `"Knight"`, `"Cross"`, `"Wrap"`, `"Calculative"`. Defaults to `"Regular"`.
- *Throws error on ragged rows, unknown characters, out-of-range clues, or invalid mine counts.*

### `MS.Solve(board, [maxPasses]) -> passes`
Clears previous solver outputs and runs deduction passes until convergence or `maxPasses` (default `50`). Updates `board.Status`, `board.Exact`, `board.Stats`, and sets `probability` and `predicted` on tiles.

### `MS.Run(board) -> madeProgress`
Runs a single pass of the solver without clearing previous solver output. Returns `true` if new safe/mine predictions were determined.

### `MS.BestMove(board) -> tile, probability`
Finds the unknown tile with the lowest mine probability (lowest risk guess). Returns `nil` if no unknown tiles remain.

### `MS.SetCell(board, x, z, cell)`
Updates a single tile at `(x, z)` with a new cell value, validates neighbor constraints, and resets solver state (`MS.Reset`).

### `MS.Reset(board)`
Clears solver predictions and probabilities, and updates frontier flags across all tiles.

### `MS.ClearSolverOutput(board)`
Clears `predicted`, `probability`, and `ProbabilityGeneration` flags on all tiles and resets `board.Stats`.

### `MS.Format(board, [showProbabilities]) -> string`
Returns an ASCII representation of the board:
- Symbols: `E` = empty, `1..9` = clue, `M` = mine, `*` = predicted mine, `s` = predicted safe, `?` = unknown.
- If `showProbabilities` is `true`, unknown cells print integer percentages (e.g. ` 25%`).

### `MS.EstimateTotalMines(width, height) -> integer`
Returns standard mine counts for known dimensions (9×9→10, 16×16→40, 30×16→99) or estimates using ~20.6% density.

---

## Tile and Board Structures

### Tile Fields
```lua
tile = {
    X = 1,                      -- Column (1..width)
    Z = 1,                      -- Row (1..height)
    Type = "unknown",           -- "unknown" | "safe_empty" | "safe_numbered" | "mine"
    Value = 1,                  -- Clue integer for safe_numbered, 0 for safe_empty
    probability = 0.125,        -- Computed mine probability (0.0 to 1.0)
    predicted = "safe",         -- "safe" (p < 1e-6) | "mine" (p > 1 - 1e-6) | nil
    IsFrontier = true,          -- true if unknown tile touches a revealed clue
    Neighbors = { ... },        -- Array of adjacent tile objects
}
```

### Board Fields
```lua
board = {
    Width = 9,
    Height = 9,
    TotalMines = 10,
    MinesConfirmed = 2,
    Status = "ok",              -- "ok" | "contradiction" | "approximate"
    Exact = true,               -- true if all clusters solved exactly with DP
    Stats = {
        ClusterCount = 1,       -- Total frontier clusters solved
        MaxCluster = 8,         -- Maximum cluster size in variables
        DPClusterCount = 1,     -- Clusters solved with frontier DP
        DPAbortCount = 0,       -- Clusters that exceeded StateCap
        DPMaxStates = 12,       -- Maximum simultaneous DP states
        DPMs = 0.45,            -- Time spent in DP (ms)
    }
}
```

---

## Configuration (`MS.Config`)

Settings can be inspected or modified via `MS.Config`:

```lua
MS.Config = {
    FrontierDP = {
        Enabled = true,
        StateCap = 50000,       -- Max active states in DP layer before aborting
        MaxClusterVars = 625,   -- Max variables in a single cluster
        TimeBudgetMs = nil,     -- nil = no time limit (deterministic)
    },
    Preprocess = {
        ArcProbeLimit = 16,     -- Max unit propagation probe tests
        ArcProbeTimeBudgetMs = nil, -- nil = no time limit (deterministic)
        ArcMinEquations = 6,    -- Minimum equation threshold to run arc probes
        ArcSmallVarSkip = 18,   -- Skip arc probes if cluster is small
        ArcSmallClusterSkip = 12,
    },
    MineCountOverrides = { ... },
    MaxSolvePasses = 50,
}
```

### Trade-offs:
- **`StateCap` (default `50000`)**: Controls memory and worst-case branch explosion on highly entangled clusters. If a frontier exceeds this cap, that cluster aborts and falls back to uniform density estimation (`board.Status = "approximate"`).
- **`TimeBudgetMs` (default `nil`)**: When `nil`, execution is completely deterministic and machine-independent. If set to a number (e.g. `50`), DP aborts early if time exceeds that budget.

---

## How It Works

1. **Equation Generation**: Revealed numbered clues and empty zero tiles generate linear equations over adjacent unknown cells:
   $$\sum_{v \in \text{Neighbors}(c)} x_v = \text{clue}(c) - \text{confirmed\_mines}(c)$$
2. **Arc-Consistency Preprocessing**: Propagates unit constraints ($k = 0 \implies \text{all safe}$, $k = n \implies \text{all mines}$) and runs bidirectional probing on high-degree variables to eliminate variables before clustering.
3. **Cluster Decomposition**: Connected components of overlapping equations are split into independent variable clusters using disjoint-set union.
4. **Frontier Dynamic Programming**: For each cluster, variables are ordered to minimize active equation frontiers. A forward/backward DP accumulates the exact integer count of valid assignments for every possible number of cluster mines:
   $$\text{ways}[m] = \text{number of valid assignments with } m \text{ mines}$$
   $$\text{hits}[v][m] = \text{number of valid assignments where variable } v \text{ is a mine}$$
5. **Global Convolution**: Clusters and unconstrained free cells are convolved into a global polynomial distribution. Each cell's final probability is computed by weighting valid cluster states against the remaining mine count possibilities across the rest of the board.

---

## Benchmarks & Verification

### 1. Accuracy vs. Brute-Force Enumeration
Accuracy was verified against an independent brute-force combinatorial engine ([`tests/bruteforce.lua`](tests/bruteforce.lua)) that enumerates every possible valid mine placement. Across thousands of randomly generated boards across all 7 non-calculative modes:
- **Accuracy**: **100% exact match** (absolute error $< 10^{-9}$) whenever the frontier state cap is not exceeded.
- Calculative mode is verified against hand-checked modular arithmetic test cases in [`tests/run.lua`](tests/run.lua).
- Reproduce:
  ```bash
  lua tests/bruteforce.lua 200 1
  ```

### 2. Autoplay Win Rates & Speed
Benchmarked with [`bench/bench.lua`](bench/bench.lua) under standard guaranteed opening zero rules:
- **First-click rule**: The solver starts by revealing the center cell, guaranteed to be an opening zero (the center cell and all its neighbors have 0 mines, opening an initial safe region via flood-fill). Other solvers using different first-click rules (e.g. single safe cell without guaranteed zero) achieve lower win rates.
- **Seed reproducibility**: Pseudo-random sequences are reproducible per interpreter (`--seed 1`). Note that Lua 5.1 and LuaJIT use distinct internal PRNG algorithms, producing different board sequences for the same seed.
- **Safety integrity**: Across all benchmark games, **0 cells predicted as safe were ever mines**.

#### Performance Summary (AMD Ryzen 7 5800U @ 1.9–4.4 GHz, Windows 11)

| Difficulty | Grid | Mines | Interpreter | Games | Win Rate | False Safes | Avg Game | Worst Game | Avg Solve | Worst Solve |
|---|---|---|---|---|---|---|---|---|---|---|
| **Beginner** | 9×9 | 10 | LuaJIT 2.1 | 10,000 | **96.58%** | 0 | 4.41 ms | 92.0 ms | 1.027 ms | 18.0 ms |
| **Beginner** | 9×9 | 10 | Lua 5.1 | 500 | **96.20%** | 0 | 5.59 ms | 71.0 ms | 0.882 ms | 14.0 ms |
| **Intermediate** | 16×16 | 40 | LuaJIT 2.1 | 5,000 | **87.70%** | 0 | 31.93 ms | 722.0 ms | 3.124 ms | 279.0 ms |
| **Intermediate** | 16×16 | 40 | Lua 5.1 | 200 | **88.50%** | 0 | 59.57 ms | 232.0 ms | 4.445 ms | 46.0 ms |
| **Expert** | 30×16 | 99 | LuaJIT 2.1 | 1,000 | **51.20%** | 0 | 205.32 ms | 748.0 ms | 8.813 ms | 130.0 ms |
| **Expert** | 30×16 | 99 | Lua 5.1 | 50 | **46.00%** | 0 | 428.54 ms | 1016.0 ms | 18.385 ms | 83.0 ms |

Reproduce locally:
```bash
# Run benchmark on LuaJIT:
luajit bench/bench.lua --seed 1 --games 1000 --difficulty intermediate

# Run benchmark on plain Lua 5.1:
lua bench/bench.lua --seed 1 --games 500 --difficulty beginner
```

---

## Limitations

- **Risk-minimizing heuristic**: `MS.BestMove` selects the cell with the lowest mine probability. It does not perform multi-turn lookahead or weigh information gain (e.g. clicking a slightly riskier cell that is guaranteed to open a large area).
- **State cap fallbacks**: On astronomically large, tangled frontiers exceeding `StateCap`, clusters drop to uniform density estimation (`board.Status = "approximate"`).

---

## Origin

`moonsweep` began as the probability core for a Roblox Minesweeper assistant. It was extracted, stripped of all game-specific automation and platform dependencies, and refactored into a general-purpose, high-performance pure Lua library.

---

## License

MIT License. Copyright (c) 2026 [dunne67](https://github.com/dunne67). See [LICENSE](LICENSE) for details.

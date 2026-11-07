# moonsweep

Fast, exact-probability Minesweeper solver in pure Lua (5.1+ / LuaJIT), single file, no dependencies.

## Features
- 8 board modes (Regular, Large, Cornerless, Corners, Knight, Cross, Wrap, Calculative).
- Global mine-count weighting.
- Frontier DP per cluster.
- Arc-consistency preprocessing.
- Uniform-density fallback when limits are hit.

## Installation
Copy `moonsweep.lua` into your project.

## Quick start
```lua
local MS = require("moonsweep")
local board = MS.BuildBoard({
    "EE1?",
    "112?",
    "????",
}, 3, "Regular")
MS.Solve(board)
print(MS.Format(board))
```

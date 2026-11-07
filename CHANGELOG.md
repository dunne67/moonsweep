# Changelog

All notable changes to `moonsweep` will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-07

### Added
- Pure Lua 5.1+ / LuaJIT Minesweeper exact probability solver engine in a single file (`moonsweep.lua`).
- 8 board modes: `Regular`, `Large`, `Cornerless`, `Corners`, `Knight`, `Cross`, `Wrap`, and `Calculative`.
- Arc-consistency preprocessing and unit constraint propagation.
- Frontier dynamic programming per cluster with forward/backward counting.
- Polynomial distribution convolution connecting frontier clusters with unconstrained free tiles.
- Input validation on board construction (`BuildBoard`), cell updates (`SetCell`), and total mine count with clear error messages.
- Full board status reporting: `board.Status = "ok" | "contradiction" | "approximate"` and `board.Exact = true | false`.
- Deterministic solving by default (time limits disabled by default, bounded by state cap).
- Incremental board modification (`SetCell`) and solver state reset (`Reset`, `ClearSolverOutput`).
- Command-line example scripts: `examples/basic.lua` and `examples/autoplay.lua`.
- Test suite with 29 automated tests covering patterns, modes, validation, and contradictions (`tests/run.lua`).
- Exact brute-force combinatorial verification suite (`tests/bruteforce.lua`).
- Win-rate and performance benchmark suite (`bench/bench.lua`).
- GitHub Actions CI workflow testing Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.

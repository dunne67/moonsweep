-- bench/bench.lua
-- Speed and win-rate benchmark for moonsweep.
--
-- Benchmark rules:
--   - First-click rule: Guaranteed opening zero at the board center (no adjacent mines).
--   - Seed portability: Pseudo-random sequences are reproducible per interpreter.
--     Lua 5.1 and LuaJIT use distinct PRNG implementations.
--   - Verification: Tracks any false-safe determinations (if a cell predicted safe
--     turns out to be a mine).
--
-- Usage:
--   lua bench/bench.lua [--seed N] [--games N] [--difficulty beginner|intermediate|expert|all]

package.path = "./?.lua;" .. package.path
local MS = require("moonsweep")

local function parseArgs(args)
    local opts = {
        seed = 1,
        games = 1000, -- default 1,000 games per difficulty (pass --games 10000 for high-sample runs)
        difficulty = "all",
        mode = "Regular"
    }
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--seed" then opts.seed = tonumber(args[i + 1]) or opts.seed; i = i + 1
        elseif a == "--games" or a == "-n" then opts.games = tonumber(args[i + 1]) or opts.games; i = i + 1
        elseif a == "--difficulty" or a == "-d" then opts.difficulty = args[i + 1] or opts.difficulty; i = i + 1
        elseif a == "--mode" or a == "-m" then opts.mode = args[i + 1] or opts.mode; i = i + 1
        end
        i = i + 1
    end
    return opts
end

local function generateBoard(W, H, numMines, modeName, startX, startZ)
    local totalCells = W * H
    local dummyRows = {}
    for z = 1, H do dummyRows[z] = string.rep("?", W) end
    local probe = MS.BuildBoard(dummyRows, numMines, modeName)

    local function cellId(x, z) return (z - 1) * W + x end
    local neighbors = {}
    for _, t in ipairs(probe.Tiles) do
        local list = {}
        for _, n in ipairs(t.Neighbors) do
            list[#list + 1] = cellId(n.X, n.Z)
        end
        neighbors[cellId(t.X, t.Z)] = list
    end

    -- First-click opening rule: starting cell and its neighbors have 0 mines
    local forbidden = {}
    local startId = cellId(startX, startZ)
    forbidden[startId] = true
    for _, nid in ipairs(neighbors[startId] or {}) do
        forbidden[nid] = true
    end

    local pool = {}
    for i = 1, totalCells do
        if not forbidden[i] then pool[#pool + 1] = i end
    end
    if #pool < numMines then
        pool = {}
        forbidden = { [startId] = true }
        for i = 1, totalCells do
            if not forbidden[i] then pool[#pool + 1] = i end
        end
    end

    local mines = {}
    for i = 1, numMines do
        local pick = math.random(i, #pool)
        pool[i], pool[pick] = pool[pick], pool[i]
        mines[pool[i]] = true
    end

    local clues = {}
    for i = 1, totalCells do
        local c = 0
        for _, nid in ipairs(neighbors[i] or {}) do
            if mines[nid] then c = c + 1 end
        end
        clues[i] = c
    end

    return {
        W = W,
        H = H,
        mines = mines,
        clues = clues,
        neighbors = neighbors,
        cellId = cellId
    }
end

local function simulateGame(W, H, numMines, modeName, gameSeed)
    math.randomseed(gameSeed)
    local startX = math.floor(W / 2)
    local startZ = math.floor(H / 2)

    local hidden = generateBoard(W, H, numMines, modeName, startX, startZ)
    local rows = {}
    for z = 1, H do rows[z] = string.rep("?", W) end
    local board = MS.BuildBoard(rows, numMines, modeName)

    local revealed = {}
    local revealedCount = 0
    local targetSafeCount = (W * H) - numMines

    local function revealCell(x, z)
        local id = hidden.cellId(x, z)
        if revealed[id] then return true end
        if hidden.mines[id] then return false end

        local queue = { id }
        while #queue > 0 do
            local currId = table.remove(queue, 1)
            if not revealed[currId] then
                revealed[currId] = true
                revealedCount = revealedCount + 1
                local cx = ((currId - 1) % W) + 1
                local cz = math.floor((currId - 1) / W) + 1
                local c = hidden.clues[currId]
                local symbol = (c == 0) and "E" or tostring(c)
                MS.SetCell(board, cx, cz, symbol)

                if c == 0 then
                    for _, nid in ipairs(hidden.neighbors[currId] or {}) do
                        if not revealed[nid] and not hidden.mines[nid] then
                            queue[#queue + 1] = nid
                        end
                    end
                end
            end
        end
        return true
    end

    revealCell(startX, startZ)
    local solveCount = 0
    local solveTimeTotal = 0
    local maxSolveTime = 0

    while revealedCount < targetSafeCount do
        local t0 = os.clock()
        MS.Solve(board)
        local dt = (os.clock() - t0) * 1000
        solveCount = solveCount + 1
        solveTimeTotal = solveTimeTotal + dt
        if dt > maxSolveTime then maxSolveTime = dt end

        local safeClicks = {}
        for _, t in ipairs(board.Tiles) do
            local id = hidden.cellId(t.X, t.Z)
            if t.Type == "unknown" and not revealed[id] and t.predicted == "safe" then
                safeClicks[#safeClicks + 1] = t
            end
        end

        if #safeClicks > 0 then
            for _, t in ipairs(safeClicks) do
                local ok = revealCell(t.X, t.Z)
                if not ok then
                    -- Cell predicted safe was actually a mine!
                    return false, solveCount, solveTimeTotal, maxSolveTime, true
                end
                if revealedCount >= targetSafeCount then break end
            end
        else
            local bestTile = MS.BestMove(board)
            if not bestTile then break end
            local ok = revealCell(bestTile.X, bestTile.Z)
            if not ok then
                -- Lowest-probability guess hit a mine (normal loss)
                return false, solveCount, solveTimeTotal, maxSolveTime, false
            end
        end
    end

    local won = (revealedCount >= targetSafeCount)
    return won, solveCount, solveTimeTotal, maxSolveTime, false
end

local function runBenchmark(name, W, H, numMines, numGames, baseSeed, modeName)
    print(string.format("Running %s benchmark (%dx%d, %d mines) - %d games...",
        name, W, H, numMines, numGames, baseSeed))

    local wins = 0
    local falseSafes = 0
    local totalGameTime = 0
    local maxGameTime = 0
    local totalSolves = 0
    local totalSolveTime = 0
    local worstSolveTime = 0

    local benchStart = os.clock()

    for g = 1, numGames do
        local gameSeed = baseSeed + (g * 1009)
        local g0 = os.clock()
        local won, solves, solveTime, maxSolve, isFalseSafe = simulateGame(W, H, numMines, modeName, gameSeed)
        local gTime = (os.clock() - g0) * 1000

        if won then wins = wins + 1 end
        if isFalseSafe then falseSafes = falseSafes + 1 end
        totalGameTime = totalGameTime + gTime
        if gTime > maxGameTime then maxGameTime = gTime end
        totalSolves = totalSolves + solves
        totalSolveTime = totalSolveTime + solveTime
        if maxSolve > worstSolveTime then worstSolveTime = maxSolve end
    end

    local totalWallSec = os.clock() - benchStart
    local winRate = (wins / numGames) * 100
    local avgGameMs = totalGameTime / numGames
    local avgSolveMs = totalSolves > 0 and (totalSolveTime / totalSolves) or 0

    return {
        name = name,
        dimensions = string.format("%dx%d", W, H),
        mines = numMines,
        games = numGames,
        wins = wins,
        falseSafes = falseSafes,
        winRate = winRate,
        avgGameMs = avgGameMs,
        maxGameMs = maxGameTime,
        avgSolveMs = avgSolveMs,
        maxSolveMs = worstSolveTime,
        wallSec = totalWallSec
    }
end

local opts = parseArgs(arg or {})

local difficulties = {
    beginner = { name = "Beginner", W = 9, H = 9, M = 10 },
    intermediate = { name = "Intermediate", W = 16, H = 16, M = 40 },
    expert = { name = "Expert", W = 30, H = 16, M = 99 },
}

local queue = {}
if opts.difficulty == "all" then
    queue[#queue + 1] = difficulties.beginner
    queue[#queue + 1] = difficulties.intermediate
    queue[#queue + 1] = difficulties.expert
else
    local d = difficulties[opts.difficulty:lower()]
    if not d then
        error("Unknown difficulty: " .. tostring(opts.difficulty))
    end
    queue[#queue + 1] = d
end

local interpreter = (jit and jit.version) or _VERSION
print(string.format("=== moonsweep benchmark (%s) ===", interpreter))
print(string.format("Settings: seed=%d, games/difficulty=%d, first-click=opening zero\n",
    opts.seed, opts.games))

local results = {}
for _, d in ipairs(queue) do
    results[#results + 1] = runBenchmark(d.name, d.W, d.H, d.M, opts.games, opts.seed, opts.mode)
end

print("\n### Benchmark Summary")
print("| Difficulty | Dimensions | Mines | Games | Wins | Win Rate | False Safes | Avg Game (ms) | Worst Game (ms) | Avg Solve (ms) | Worst Solve (ms) |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for _, r in ipairs(results) do
    print(string.format("| %s | %s | %d | %d | %d | %.2f%% | %d | %.2f ms | %.2f ms | %.3f ms | %.2f ms |",
        r.name, r.dimensions, r.mines, r.games, r.wins, r.winRate, r.falseSafes,
        r.avgGameMs, r.maxGameMs, r.avgSolveMs, r.maxSolveMs))
end

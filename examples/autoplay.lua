-- examples/autoplay.lua
-- Plays simulated Minesweeper games using moonsweep.
--
-- Usage:
--   lua examples/autoplay.lua [--seed N] [--mode MODE] [--width W] [--height H] [--mines M] [--verbose]

package.path = "./?.lua;" .. package.path
local MS = require("moonsweep")

local function parseArgs(args)
    local opts = {
        seed = 1,
        mode = "Regular",
        width = 9,
        height = 9,
        mines = 10,
        verbose = false
    }
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--seed" then opts.seed = tonumber(args[i + 1]) or opts.seed; i = i + 1
        elseif a == "--mode" then opts.mode = args[i + 1] or opts.mode; i = i + 1
        elseif a == "--width" or a == "-w" then opts.width = tonumber(args[i + 1]) or opts.width; i = i + 1
        elseif a == "--height" or a == "-h" then opts.height = tonumber(args[i + 1]) or opts.height; i = i + 1
        elseif a == "--mines" or a == "-m" then opts.mines = tonumber(args[i + 1]) or opts.mines; i = i + 1
        elseif a == "--verbose" or a == "-v" then opts.verbose = true
        elseif a == "--beginner" then opts.width, opts.height, opts.mines = 9, 9, 10
        elseif a == "--intermediate" then opts.width, opts.height, opts.mines = 16, 16, 40
        elseif a == "--expert" then opts.width, opts.height, opts.mines = 30, 16, 99
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

    -- First click rule: startX, startZ and all its neighbors must be free of mines (safe opening zero)
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

    -- If board is very small and forbidden leaves too few cells, relax to just starting cell
    if #pool < numMines then
        pool = {}
        forbidden = { [startId] = true }
        for i = 1, totalCells do
            if not forbidden[i] then pool[#pool + 1] = i end
        end
    end

    -- Shuffle and place mines
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

local function playGame(opts)
    math.randomseed(opts.seed)
    local W, H, numMines = opts.width, opts.height, opts.mines
    local startX = math.floor(W / 2)
    local startZ = math.floor(H / 2)

    local hidden = generateBoard(W, H, numMines, opts.mode, startX, startZ)

    -- Player board starts fully unrevealed
    local rows = {}
    for z = 1, H do rows[z] = string.rep("?", W) end
    local board = MS.BuildBoard(rows, numMines, opts.mode)

    local revealed = {}
    local revealedCount = 0
    local targetSafeCount = (W * H) - numMines

    local function revealCell(x, z)
        local id = hidden.cellId(x, z)
        if revealed[id] then return true end
        if hidden.mines[id] then return false end

        -- Flood fill on 0 (empty) cells
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

    -- First click
    revealCell(startX, startZ)
    local turns = 1
    local totalSolves = 0

    while revealedCount < targetSafeCount do
        totalSolves = totalSolves + 1
        MS.Solve(board)

        -- First check if solver confirmed deterministic safe cells
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
                    return false, turns, totalSolves, "hit_mine", board
                end
                if revealedCount >= targetSafeCount then break end
            end
        else
            -- If no deterministic safe cells, pick lowest probability guess
            local bestTile, bestP = MS.BestMove(board)
            if not bestTile then
                break
            end
            if opts.verbose then
                print(string.format("Turn %d: guessing (%d,%d) with risk %.4f",
                    turns, bestTile.X, bestTile.Z, bestP))
            end
            local ok = revealCell(bestTile.X, bestTile.Z)
            if not ok then
                return false, turns, totalSolves, "hit_mine", board
            end
        end
        turns = turns + 1
    end

    local won = (revealedCount >= targetSafeCount)
    return won, turns, totalSolves, won and "win" or "stuck", board
end

local opts = parseArgs(arg or {})
print(string.format("Playing Minesweeper [%s %dx%d, %d mines] (seed=%d)...",
    opts.mode, opts.width, opts.height, opts.mines, opts.seed))

local won, turns, solves, result, board = playGame(opts)
print(string.format("Result: %s | Turns: %d | Solves: %d", string.upper(result), turns, solves))
print("\nFinal board state:")
print(MS.Format(board))

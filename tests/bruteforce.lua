-- tests/bruteforce.lua
-- Independent exact enumeration brute-force checker for moonsweep.
--
-- For small boards (up to ~18 unknown cells), enumerates every valid mine
-- assignment that satisfies all revealed clues and the global mine count,
-- computing the exact probability for every unknown cell.

local MS = require("moonsweep")

local M = {}

function M.RunBruteForceTest(numTrials, seed, verbose)
    seed = seed or 1
    numTrials = numTrials or 100
    math.randomseed(seed)

    local modes = { "Regular", "Large", "Cornerless", "Corners", "Knight", "Cross", "Wrap" }
    local checked, skipped, fails = 0, 0, 0

    for trial = 1, numTrials do
        local modeName = modes[((trial - 1) % #modes) + 1]
        local W = math.random(3, 5)
        local H = math.random(3, 5)
        local maxMines = math.max(2, math.floor(W * H / 3))
        local numMines = math.random(2, maxMines)

        -- Build hidden mine layout
        local mine = {}
        local cells = {}
        for i = 1, W * H do cells[i] = i end
        for i = 1, numMines do
            local j = math.random(i, W * H)
            cells[i], cells[j] = cells[j], cells[i]
            mine[cells[i]] = true
        end

        -- Query neighbor topology from moonsweep
        local dummyRows = {}
        for z = 1, H do dummyRows[z] = string.rep("?", W) end
        local probe = MS.BuildBoard(dummyRows, numMines, modeName)
        local function cellId(t) return (t.Z - 1) * W + t.X end
        local nb = {}
        for _, t in ipairs(probe.Tiles) do
            local list = {}
            for _, n in ipairs(t.Neighbors) do
                list[#list + 1] = cellId(n)
            end
            nb[cellId(t)] = list
        end

        -- Compute neighbor mine counts for each cell
        local neighborMineCount = {}
        for i = 1, W * H do
            local c = 0
            for _, n in ipairs(nb[i]) do
                if mine[n] then c = c + 1 end
            end
            neighborMineCount[i] = c
        end

        -- Reveal some non-mine cells with flood-fill on zero cells
        local revealed = {}
        local stack = {}
        for i = 1, W * H do
            if not mine[i] and math.random() < 0.35 then
                stack[#stack + 1] = i
            end
        end
        while #stack > 0 do
            local i = table.remove(stack)
            if not revealed[i] then
                revealed[i] = true
                if neighborMineCount[i] == 0 then
                    for _, n in ipairs(nb[i]) do
                        if not revealed[n] then
                            stack[#stack + 1] = n
                        end
                    end
                end
            end
        end

        -- Format rows for moonsweep
        local rows = {}
        for z = 1, H do
            local r = {}
            for x = 1, W do
                local i = (z - 1) * W + x
                if revealed[i] then
                    local c = neighborMineCount[i]
                    r[x] = (c == 0) and "E" or tostring(c)
                else
                    r[x] = "?"
                end
            end
            rows[z] = table.concat(r)
        end

        -- List remaining unknowns
        local unk = {}
        for i = 1, W * H do
            if not revealed[i] then
                unk[#unk + 1] = i
            end
        end

        -- Only run brute-force if search space is reasonable (<= 18 unknowns)
        if #unk > 18 or #unk < numMines then
            skipped = skipped + 1
        else
            local totalValid = 0
            local mineHits = {}
            local assignment = {}

            local function satisfiesClues()
                for i = 1, W * H do
                    if revealed[i] then
                        local c = 0
                        for _, n in ipairs(nb[i]) do
                            if assignment[n] then c = c + 1 end
                        end
                        if c ~= neighborMineCount[i] then
                            return false
                        end
                    end
                end
                return true
            end

            local function enumerate(k, minesLeft)
                if k > #unk then
                    if minesLeft == 0 and satisfiesClues() then
                        totalValid = totalValid + 1
                        for _, u in ipairs(unk) do
                            if assignment[u] then
                                mineHits[u] = (mineHits[u] or 0) + 1
                            end
                        end
                    end
                    return
                end
                if (#unk - k + 1) < minesLeft then return end
                local u = unk[k]
                if minesLeft > 0 then
                    assignment[u] = true
                    enumerate(k + 1, minesLeft - 1)
                end
                assignment[u] = nil
                enumerate(k + 1, minesLeft)
            end

            enumerate(1, numMines)

            if totalValid > 0 then
                local board = MS.BuildBoard(rows, numMines, modeName)
                MS.Run(board)
                checked = checked + 1

                for _, t in ipairs(board.Tiles) do
                    if t.Type == "unknown" then
                        local exactProb = (mineHits[cellId(t)] or 0) / totalValid
                        local gotProb = t.probability
                        if t.predicted == "mine" then
                            gotProb = 1
                        elseif t.predicted == "safe" and gotProb == nil then
                            gotProb = 0
                        end

                        if gotProb == nil or math.abs(gotProb - exactProb) > 1e-9 then
                            fails = fails + 1
                            if verbose or fails <= 5 then
                                print(string.format(
                                    "FAIL [%s %dx%d m=%d] cell (%d,%d) exact=%.8f got=%s predicted=%s",
                                    modeName, W, H, numMines, t.X, t.Z,
                                    exactProb, tostring(gotProb), tostring(t.predicted)
                                ))
                                for _, r in ipairs(rows) do
                                    print("   " .. r)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return {
        checked = checked,
        skipped = skipped,
        fails = fails
    }
end

if arg and arg[0] and string.find(arg[0], "bruteforce") then
    local trials = tonumber(arg[1]) or 200
    local seed = tonumber(arg[2]) or 1
    print(string.format("Running brute-force verification: %d trials (seed=%d)...", trials, seed))
    local res = M.RunBruteForceTest(trials, seed, true)
    print(string.format("Results: checked=%d skipped=%d failures=%d", res.checked, res.skipped, res.fails))
    if res.fails > 0 then
        os.exit(1)
    end
end

return M

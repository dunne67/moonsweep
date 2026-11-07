-- moonsweep.lua
-- Standalone Minesweeper probability solver (pure Lua 5.1+ / LuaJIT).
--
-- Usage:
--   local MS = require("moonsweep")
--   local board = MS.BuildBoard({
--       "EE1?",
--       "112?",
--       "????",
--   }, 3, "Regular")
--   MS.Solve(board)
--   print(MS.Format(board))
--   for _, t in ipairs(board.Tiles) do
--       if t.Type == "unknown" then print(t.X, t.Z, t.predicted, t.probability) end
--   end
--
-- Cell characters (rows are strings, one char per cell; or tables of cells):
--   "?"      unknown
--   "E"/"0"  revealed empty
--   "1".."9" revealed clue (raw value, decoded by the mode)
--   "M"/"F"  known mine
--   "."      no tile at this position
-- Table rows may also contain numbers (raw clue values, e.g. >9 for Calculative).
-- Row index = Z (1..height), column index = X (1..width).

local M = {}
M._VERSION = "1.0.0"

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
M.Config = {
    FrontierDP = {
        Enabled = true,
        StateCap = 50000,
        MaxClusterVars = 625,
        TimeBudgetMs = nil -- Default: no time limit, only state cap
    },
    Preprocess = {
        ArcProbeLimit = 16,
        ArcProbeTimeBudgetMs = 4,
        ArcMinEquations = 6,
        ArcSmallVarSkip = 18,
        ArcSmallClusterSkip = 12
    },
    MineCountOverrides = {
        ["9x9"] = 10,
        ["16x16"] = 40,
        ["16x30"] = 99,
        ["25x25"] = 100,
        ["30x16"] = 99
    },
    MaxSolvePasses = 50
}
local CONFIG = M.Config

local function Round(x)
    return math.floor(x + 0.5)
end

---------------------------------------------------------------------------
-- Modes / neighbors
---------------------------------------------------------------------------
local REGULAR_NEIGHBOR_OFFSETS = {
    { 1, 1 }, { 1, 0 }, { 1, -1 }, { 0, 1 }, { 0, -1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }
}
local CORNERLESS_NEIGHBOR_OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local CORNERS_NEIGHBOR_OFFSETS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local KNIGHT_NEIGHBOR_OFFSETS = {
    { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 }
}
local CROSS_NEIGHBOR_OFFSETS = {
    { 1, 0 }, { 2, 0 }, { -1, 0 }, { -2, 0 }, { 0, 1 }, { 0, 2 }, { 0, -1 }, { 0, -2 }
}

local function WrapGridIndex(value, limit)
    return ((value - 1) % limit) + 1
end

local function DecodeRegularClue(rawNumber)
    if rawNumber > 0 then
        return rawNumber
    elseif rawNumber == 0 then
        return 0
    end
    return nil
end

local function DecodeCalculativeClue(rawNumber)
    local quotient = math.floor(rawNumber / 8)
    local remainder = rawNumber - quotient * 8
    if remainder == 0 then
        return 8
    end
    return remainder
end

local function GetOffsetNeighbors(grid, x, z, width, height, offsets, wrap)
    local neighbors = {}
    for _, offset in ipairs(offsets) do
        local nx = x + offset[1]
        local nz = z + offset[2]
        if wrap then
            nx = WrapGridIndex(nx, width)
            nz = WrapGridIndex(nz, height)
        end
        if nx >= 1 and nx <= width and nz >= 1 and nz <= height and not (nx == x and nz == z) then
            local neighbor = grid[nx][nz]
            if neighbor then
                neighbors[#neighbors + 1] = neighbor
            end
        end
    end
    return neighbors
end

local function GetRadiusNeighbors(grid, x, z, width, height, radius)
    local neighbors = {}
    for dx = -radius, radius do
        for dz = -radius, radius do
            if not (dx == 0 and dz == 0) then
                local nx, nz = x + dx, z + dz
                if nx >= 1 and nx <= width and nz >= 1 and nz <= height then
                    local neighbor = grid[nx][nz]
                    if neighbor then
                        neighbors[#neighbors + 1] = neighbor
                    end
                end
            end
        end
    end
    return neighbors
end

local function OffsetMode(offsets, wrap, decode)
    return {
        DecodeClue = decode or DecodeRegularClue,
        GetNeighbors = function(grid, x, z, width, height)
            return GetOffsetNeighbors(grid, x, z, width, height, offsets, wrap)
        end
    }
end

M.Modes = {
    Regular = OffsetMode(REGULAR_NEIGHBOR_OFFSETS, false),
    Calculative = OffsetMode(REGULAR_NEIGHBOR_OFFSETS, false, DecodeCalculativeClue),
    Large = {
        DecodeClue = DecodeRegularClue,
        GetNeighbors = function(grid, x, z, width, height)
            return GetRadiusNeighbors(grid, x, z, width, height, 2)
        end
    },
    Cornerless = OffsetMode(CORNERLESS_NEIGHBOR_OFFSETS, false),
    Corners = OffsetMode(CORNERS_NEIGHBOR_OFFSETS, false),
    Knight = OffsetMode(KNIGHT_NEIGHBOR_OFFSETS, false),
    Cross = OffsetMode(CROSS_NEIGHBOR_OFFSETS, false),
    Wrap = OffsetMode(REGULAR_NEIGHBOR_OFFSETS, true)
}

---------------------------------------------------------------------------
-- Board construction
---------------------------------------------------------------------------
function M.EstimateTotalMines(width, height)
    local direct = CONFIG.MineCountOverrides[tostring(width) .. "x" .. tostring(height)]
    if direct then return direct end
    local swapped = CONFIG.MineCountOverrides[tostring(height) .. "x" .. tostring(width)]
    if swapped then return swapped end
    local area = width * height
    if area <= 81 then
        return 10
    elseif area <= 256 then
        return 40
    elseif area <= 480 then
        return 99
    end
    return Round(area * 0.206)
end

local function ParseCell(cell, mode)
    if cell == nil or cell == "." then return nil end
    if type(cell) == "number" then
        local decoded = mode.DecodeClue(cell)
        if decoded and decoded > 0 then return "safe_numbered", decoded end
        if decoded == 0 then return "safe_empty", 0 end
        return "unknown", nil
    end
    cell = tostring(cell)
    if cell == "?" then return "unknown", nil end
    if cell == "E" or cell == "e" or cell == " " or cell == "" then return "safe_empty", 0 end
    if cell == "M" or cell == "m" or cell == "F" or cell == "f" then return "mine", nil end
    local num = tonumber(cell)
    if num then return ParseCell(num, mode) end
    return "unknown", nil
end

local function SplitRow(row)
    if type(row) == "table" then return row end
    local cells = {}
    for i = 1, #row do
        cells[i] = string.sub(row, i, i)
    end
    return cells
end

-- rows: array of strings/tables (row index = Z). totalMines optional.
-- modeName: key of M.Modes (default "Regular").
function M.BuildBoard(rows, totalMines, modeName)
    local mode = M.Modes[modeName or "Regular"]
    if not mode then
        error("unknown mode: " .. tostring(modeName))
    end
    local parsedRows = {}
    local width = 0
    for z = 1, #rows do
        parsedRows[z] = SplitRow(rows[z])
        if #parsedRows[z] > width then width = #parsedRows[z] end
    end
    local height = #rows
    local grid = {}
    for x = 1, width do grid[x] = {} end
    local tiles = {}
    for z = 1, height do
        local row = parsedRows[z]
        for x = 1, width do
            local tileType, value = ParseCell(row[x], mode)
            if tileType then
                local tile = {
                    X = x,
                    Z = z,
                    Type = tileType,
                    Value = value,
                    predicted = nil,
                    probability = nil,
                    ProbabilityGeneration = nil,
                    IsFrontier = false,
                    Neighbors = {}
                }
                grid[x][z] = tile
                tiles[#tiles + 1] = tile
            end
        end
    end
    for x = 1, width do
        for z = 1, height do
            local tile = grid[x][z]
            if tile then
                tile.Neighbors = mode.GetNeighbors(grid, x, z, width, height)
            end
        end
    end
    for _, tile in ipairs(tiles) do
        local frontier = false
        if tile.Type == "unknown" then
            for _, n in ipairs(tile.Neighbors) do
                if n.Type == "safe_numbered" then frontier = true break end
            end
        end
        tile.IsFrontier = frontier
    end
    return {
        Mode = mode,
        ModeName = modeName or "Regular",
        Tiles = tiles,
        Grid = grid,
        Width = width,
        Height = height,
        TotalMines = totalMines or M.EstimateTotalMines(width, height),
        MinesConfirmed = 0,
        SolveGeneration = 0,
        Stats = {
            LastClusterCount = 0,
            LastMaxCluster = 0,
            LastDPClusterCount = 0,
            LastDPAbortCount = 0,
            LastDPMaxStates = 0,
            LastDPMs = 0
        }
    }
end

-- Clears all predictions/probabilities (e.g. after changing TotalMines).
function M.ClearSolverOutput(board)
    board.SolveGeneration = board.SolveGeneration + 1
    board.MinesConfirmed = 0
    for _, tile in ipairs(board.Tiles) do
        tile.predicted = nil
        tile.probability = nil
        tile.ProbabilityGeneration = nil
    end
end

---------------------------------------------------------------------------
-- Combinatorics
---------------------------------------------------------------------------
local LnFact = { [0] = 0 }
local LnFactMax = 0
local function EnsureLnFact(n)
    if n <= LnFactMax then return end
    for i = LnFactMax + 1, n do
        LnFact[i] = LnFact[i - 1] + math.log(i)
    end
    LnFactMax = n
end

local function LogChoose(n, k)
    if k < 0 or k > n then return -math.huge end
    EnsureLnFact(n)
    return LnFact[n] - LnFact[k] - LnFact[n - k]
end

local function Choose(n, k)
    local logValue = LogChoose(n, k)
    if logValue == -math.huge then return 0 end
    return math.exp(logValue)
end

local function ConvolveMineDistributions(a, b, maxMines)
    local out = {}
    for ma, wa in pairs(a) do
        for mb, wb in pairs(b) do
            local sum = ma + mb
            if sum <= maxMines then
                out[sum] = (out[sum] or 0) + (wa * wb)
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Arc-consistency preprocess
---------------------------------------------------------------------------
local function SortAndUniq(vars)
    table.sort(vars)
    local out = {}
    local last = nil
    for i = 1, #vars do
        local v = vars[i]
        if v ~= last then out[#out + 1] = v; last = v end
    end
    return out
end

local function NormalizeEquations(localEqs)
    local normalized = {}
    local byVarSet = {}
    for _, eq in ipairs(localEqs) do
        local rawVars = {}
        for _, varId in ipairs(eq.vars) do rawVars[#rawVars + 1] = varId end
        local vars = SortAndUniq(rawVars)
        if eq.needed < 0 or eq.needed > #vars then
            return nil, "contradiction"
        end
        if #vars > 0 then
            local key = table.concat(vars, ",")
            if byVarSet[key] == nil then
                byVarSet[key] = eq.needed
                normalized[#normalized + 1] = { needed = eq.needed, vars = vars }
            elseif byVarSet[key] ~= eq.needed then
                return nil, "contradiction"
            end
        elseif eq.needed ~= 0 then
            return nil, "contradiction"
        end
    end
    return normalized, "ok"
end

local function PropagateArcUnits(equations, resolved, maxPasses)
    local current, status = NormalizeEquations(equations)
    if not current then return nil, status end
    for _ = 1, (maxPasses or 20) do
        local changed = false
        local nextEqs = {}
        for _, eq in ipairs(current) do
            local vars = {}
            local removedMines = 0
            for _, varId in ipairs(eq.vars) do
                local val = resolved[varId]
                if val == nil then
                    vars[#vars + 1] = varId
                else
                    removedMines = removedMines + val
                end
            end
            local needed = eq.needed - removedMines
            if needed < 0 or needed > #vars then
                return nil, "contradiction"
            end
            if #vars > 0 then
                if needed == 0 or needed == #vars then
                    local val = (needed == #vars) and 1 or 0
                    for _, varId in ipairs(vars) do
                        if resolved[varId] == nil then
                            resolved[varId] = val
                            changed = true
                        elseif resolved[varId] ~= val then
                            return nil, "contradiction"
                        end
                    end
                else
                    nextEqs[#nextEqs + 1] = { needed = needed, vars = vars }
                end
            elseif needed ~= 0 then
                return nil, "contradiction"
            end
        end
        current, status = NormalizeEquations(nextEqs)
        if not current then return nil, status end
        if not changed then return current, "ok" end
    end
    return current, "ok"
end

local function BuildPreprocessShape(equations, varCount, resolved)
    local remainingVars = 0
    for varId = 1, varCount do
        if resolved[varId] == nil then remainingVars = remainingVars + 1 end
    end
    local parent, rank = {}, {}
    local eqCount, edgeCount = 0, 0
    for varId = 1, varCount do
        if resolved[varId] == nil then
            parent[varId] = varId
            rank[varId] = 0
        end
    end
    local function Find(x)
        local p = parent[x]
        if p ~= x then
            p = Find(p)
            parent[x] = p
        end
        return p
    end
    local function Union(a, b)
        local ra, rb = Find(a), Find(b)
        if ra == rb then return end
        if rank[ra] < rank[rb] then
            parent[ra] = rb
        elseif rank[ra] > rank[rb] then
            parent[rb] = ra
        else
            parent[rb] = ra
            rank[ra] = rank[ra] + 1
        end
    end
    for _, eq in ipairs(equations or {}) do
        if #eq.vars > 0 then
            eqCount = eqCount + 1
            edgeCount = edgeCount + #eq.vars
            local first = nil
            for _, varId in ipairs(eq.vars) do
                if parent[varId] then
                    if first then Union(first, varId) else first = varId end
                end
            end
        end
    end
    local componentSizes = {}
    local maxCluster = remainingVars > 0 and 1 or 0
    for varId = 1, varCount do
        if parent[varId] then
            local root = Find(varId)
            local size = (componentSizes[root] or 0) + 1
            componentSizes[root] = size
            if size > maxCluster then maxCluster = size end
        end
    end
    return {
        remainingVars = remainingVars,
        eqCount = eqCount,
        edgeCount = edgeCount,
        avgDegree = remainingVars > 0 and (edgeCount / remainingVars) or 0,
        maxCluster = maxCluster
    }
end

local function ShouldRunArcProbes(shape)
    local cfg = CONFIG.Preprocess
    if shape.remainingVars <= 0 then return false end
    if shape.eqCount < (cfg.ArcMinEquations or 6) then return false end
    if shape.remainingVars < (cfg.ArcSmallVarSkip or 18) and shape.maxCluster < (cfg.ArcSmallClusterSkip or 12) then
        return false
    end
    return true
end

local function RunArcConsistencyPreprocess(equations, varCount)
    local startClock = os.clock()
    local stats = { ms = 0, arcProbes = 0, arcSkipped = 0 }
    local resolved = {}
    local reduced, status = PropagateArcUnits(equations, resolved, 20)
    if not reduced then
        stats.ms = (os.clock() - startClock) * 1000
        return nil, nil, status, stats
    end
    local shape = BuildPreprocessShape(reduced, varCount, resolved)
    if not ShouldRunArcProbes(shape) then
        stats.arcSkipped = 1
        stats.ms = (os.clock() - startClock) * 1000
        return reduced, resolved, "ok", stats
    end
    local degree = {}
    for i = 1, varCount do degree[i] = 0 end
    for _, eq in ipairs(reduced) do
        for _, varId in ipairs(eq.vars) do
            degree[varId] = (degree[varId] or 0) + 1
        end
    end
    local vars = {}
    for i = 1, varCount do vars[#vars + 1] = i end
    table.sort(vars, function(a, b)
        if (degree[a] or 0) ~= (degree[b] or 0) then
            return (degree[a] or 0) > (degree[b] or 0)
        end
        return a < b
    end)
    local probes = 0
    local probeLimit = CONFIG.Preprocess.ArcProbeLimit or 16
    local timeBudget = (CONFIG.Preprocess.ArcProbeTimeBudgetMs or 4) / 1000
    local probeStartClock = os.clock()
    for _, varId in ipairs(vars) do
        if probes >= probeLimit then break end
        if (os.clock() - probeStartClock) >= timeBudget then
            stats.arcSkipped = 1
            break
        end
        if resolved[varId] == nil then
            local possible = {}
            for value = 0, 1 do
                local assumed = {}
                for k, v in pairs(resolved) do assumed[k] = v end
                assumed[varId] = value
                local probeResult = PropagateArcUnits(equations, assumed, 8)
                possible[value] = probeResult ~= nil
                probes = probes + 1
                stats.arcProbes = probes
            end
            if possible[0] and not possible[1] then
                resolved[varId] = 0
            elseif possible[1] and not possible[0] then
                resolved[varId] = 1
            elseif not possible[0] and not possible[1] then
                stats.ms = (os.clock() - startClock) * 1000
                return nil, nil, "contradiction", stats
            end
        end
    end
    reduced, status = PropagateArcUnits(equations, resolved, 20)
    stats.ms = (os.clock() - startClock) * 1000
    if not reduced then return nil, nil, status, stats end
    return reduced, resolved, "ok", stats
end

---------------------------------------------------------------------------
-- Frontier DP helpers
---------------------------------------------------------------------------
local function BuildFrontierDPPlan(nVars, localEqs, order)
    local posOfVar = {}
    for idx, varId in ipairs(order) do
        posOfVar[varId] = idx
    end
    local starts, ends, incident, eqPositions = {}, {}, {}, {}
    for i = 1, nVars do
        starts[i] = {}
        ends[i] = {}
        incident[i] = {}
    end
    for eqIdx, eq in ipairs(localEqs) do
        local positions = {}
        for _, varId in ipairs(eq.vars) do
            positions[#positions + 1] = posOfVar[varId]
            incident[varId][#incident[varId] + 1] = eqIdx
        end
        table.sort(positions)
        eqPositions[eqIdx] = positions
        if #positions > 0 then
            local s = starts[positions[1]]
            s[#s + 1] = eqIdx
            local e = ends[positions[#positions]]
            e[#e + 1] = eqIdx
        end
    end
    local activeAfter = {}
    local activeSet = {}
    for idx = 1, nVars do
        for _, eqIdx in ipairs(starts[idx]) do
            activeSet[eqIdx] = true
        end
        for _, eqIdx in ipairs(ends[idx]) do
            activeSet[eqIdx] = nil
        end
        local active = {}
        for eqIdx in pairs(activeSet) do
            active[#active + 1] = eqIdx
        end
        table.sort(active)
        activeAfter[idx] = active
    end
    return eqPositions, starts, ends, incident, activeAfter
end

local function AddDist(target, source, mineOffset, weightMultiplier)
    for mines, weight in pairs(source) do
        local key = mines + mineOffset
        target[key] = (target[key] or 0) + (weight * (weightMultiplier or 1))
    end
end

local function BuildOptimizedDPPlan(nVars, localEqs, order)
    local eqPositions, starts, _ends, incident, activeAfter = BuildFrontierDPPlan(nVars, localEqs, order)
    local activeMeta, transitionData = {}, {}
    for idx = 0, nVars do
        local active = (idx == 0) and {} or activeAfter[idx]
        local multipliers, product, safe = {}, 1, true
        for pos, eqIdx in ipairs(active) do
            multipliers[pos] = product
            product = product * ((localEqs[eqIdx].needed or 0) + 2)
            if product > 900000000000000 then safe = false end
        end
        activeMeta[idx] = { active = active, multipliers = multipliers, safe = safe }
    end
    local activeIndex = {}
    for idx = 0, nVars do
        local index = {}
        for pos, eqIdx in ipairs(activeMeta[idx].active) do index[eqIdx] = pos end
        activeIndex[idx] = index
    end
    for idx = 1, nVars do
        local prevActive = activeMeta[idx - 1].active
        local validateSet = {}
        for _, eqIdx in ipairs(prevActive) do validateSet[eqIdx] = true end
        for _, eqIdx in ipairs(starts[idx]) do validateSet[eqIdx] = true end
        local validate, future, incidentMap = {}, {}, {}
        for eqIdx in pairs(validateSet) do
            validate[#validate + 1] = eqIdx
            local remaining = 0
            for _, pos in ipairs(eqPositions[eqIdx]) do
                if pos > idx then remaining = remaining + 1 end
            end
            future[eqIdx] = remaining
        end
        table.sort(validate)
        for _, eqIdx in ipairs(incident[order[idx]]) do incidentMap[eqIdx] = true end
        transitionData[idx] = {
            varId = order[idx],
            prevIndex = activeIndex[idx - 1],
            nextActive = activeMeta[idx].active,
            nextMeta = activeMeta[idx],
            validate = validate,
            future = future,
            incident = incidentMap
        }
    end
    return transitionData
end

local function PackOptimizedCounts(counts, meta)
    if #counts == 0 then return 0 end
    if meta.safe then
        local key = 0
        for i = 1, #counts do
            key = key + (counts[i] or 0) * meta.multipliers[i]
        end
        return key
    end
    return table.concat(counts, "#")
end

local function OptimizedDPTransition(td, prevCounts, value, localEqs)
    for _, eqIdx in ipairs(td.validate) do
        local pos = td.prevIndex[eqIdx]
        local current = pos and (prevCounts[pos] or 0) or 0
        if td.incident[eqIdx] then current = current + value end
        local eq = localEqs[eqIdx]
        if current > eq.needed or current + td.future[eqIdx] < eq.needed then
            return nil, nil
        end
    end
    local nextCounts = {}
    for pos, eqIdx in ipairs(td.nextActive) do
        local prevPos = td.prevIndex[eqIdx]
        local current = prevPos and (prevCounts[prevPos] or 0) or 0
        if td.incident[eqIdx] then current = current + value end
        nextCounts[pos] = current
    end
    return PackOptimizedCounts(nextCounts, td.nextMeta), nextCounts
end

local function SolveClusterFrontierDP(cluster, localEqs, unknownList)
    if not CONFIG.FrontierDP.Enabled then return nil, nil, "disabled", 0, 0 end
    local nVars = #cluster.vars
    if nVars > CONFIG.FrontierDP.MaxClusterVars then return nil, nil, "var_cap", 0, 0 end
    local startClock = os.clock()
    local timeBudget = (CONFIG.FrontierDP.TimeBudgetMs or 6) / 1000
    local function TimedOut()
        return (os.clock() - startClock) >= timeBudget
    end
    local function Elapsed()
        return (os.clock() - startClock) * 1000
    end
    local degree = {}
    for i = 1, nVars do degree[i] = 0 end
    for _, eq in ipairs(localEqs) do
        for _, varId in ipairs(eq.vars) do
            degree[varId] = (degree[varId] or 0) + 1
        end
    end
    local order = {}
    for i = 1, nVars do order[i] = i end
    table.sort(order, function(a, b)
        local ta = unknownList[cluster.vars[a]]
        local tb = unknownList[cluster.vars[b]]
        if ta.Z ~= tb.Z then return ta.Z < tb.Z end
        if ta.X ~= tb.X then return ta.X < tb.X end
        return (degree[a] or 0) > (degree[b] or 0)
    end)
    if #localEqs == 0 then
        local ways = {}
        local hits = {}
        for i = 1, nVars do hits[i] = {} end
        for mines = 0, nVars do
            ways[mines] = Choose(nVars, mines)
        end
        for i = 1, nVars do
            for mines = 1, nVars do
                hits[i][mines] = Choose(nVars - 1, mines - 1)
            end
        end
        return ways, hits, "ok", 1, Elapsed()
    end
    local transitionData = BuildOptimizedDPPlan(nVars, localEqs, order)
    local stateCap = CONFIG.FrontierDP.StateCap or 512
    local forwardLayers = { [1] = { [0] = { counts = {}, dist = { [0] = 1 } } } }
    local maxStates = 1
    for idx = 1, nVars do
        if TimedOut() then return nil, nil, "timeout", maxStates, Elapsed() end
        local td = transitionData[idx]
        local nextLayer = {}
        for _, node in pairs(forwardLayers[idx]) do
            for value = 0, 1 do
                local nextKey, nextCounts = OptimizedDPTransition(td, node.counts, value, localEqs)
                if nextKey ~= nil then
                    local out = nextLayer[nextKey]
                    if not out then
                        out = { counts = nextCounts, dist = {} }
                        nextLayer[nextKey] = out
                    end
                    AddDist(out.dist, node.dist, value)
                end
            end
        end
        local stateCount = 0
        for _ in pairs(nextLayer) do stateCount = stateCount + 1 end
        if stateCount == 0 then return nil, nil, "empty", maxStates, Elapsed() end
        if stateCount > stateCap then return nil, nil, "state_cap", stateCount, Elapsed() end
        if stateCount > maxStates then maxStates = stateCount end
        forwardLayers[idx + 1] = nextLayer
    end
    local finalNode = forwardLayers[nVars + 1][0]
    if not finalNode then return nil, nil, "no_ways", maxStates, Elapsed() end
    local ways = finalNode.dist
    local backwardLayers = {}
    backwardLayers[nVars + 1] = { [0] = { [0] = 1 } }
    for idx = nVars, 1, -1 do
        if TimedOut() then return nil, nil, "timeout", maxStates, Elapsed() end
        local td = transitionData[idx]
        local layer = {}
        for prevKey, node in pairs(forwardLayers[idx]) do
            local out = {}
            for value = 0, 1 do
                local nextKey = OptimizedDPTransition(td, node.counts, value, localEqs)
                if nextKey ~= nil then
                    local suffix = backwardLayers[idx + 1][nextKey]
                    if suffix then
                        AddDist(out, suffix, value)
                    end
                end
            end
            if next(out) ~= nil then
                layer[prevKey] = out
            end
        end
        backwardLayers[idx] = layer
    end
    local hits = {}
    for i = 1, nVars do hits[i] = {} end
    for idx = 1, nVars do
        if TimedOut() then return nil, nil, "timeout", maxStates, Elapsed() end
        local td = transitionData[idx]
        local varId = td.varId
        for _, node in pairs(forwardLayers[idx]) do
            local nextKey = OptimizedDPTransition(td, node.counts, 1, localEqs)
            if nextKey ~= nil then
                local suffix = backwardLayers[idx + 1][nextKey]
                if suffix then
                    local hitMap = hits[varId]
                    for leftMines, leftWeight in pairs(node.dist) do
                        for rightMines, rightWeight in pairs(suffix) do
                            local mines = leftMines + 1 + rightMines
                            hitMap[mines] = (hitMap[mines] or 0) + (leftWeight * rightWeight)
                        end
                    end
                end
            end
        end
    end
    return ways, hits, "ok", maxStates, Elapsed()
end

---------------------------------------------------------------------------
-- Solver pass
---------------------------------------------------------------------------
local function GetTileConstraintState(tile)
    local unknowns = {}
    local foundMines = 0
    for _, neighbor in ipairs(tile.Neighbors) do
        if neighbor.Type == "mine" or neighbor.predicted == "mine" then
            foundMines = foundMines + 1
        elseif neighbor.Type == "unknown" and neighbor.predicted ~= "safe" then
            unknowns[#unknowns + 1] = neighbor
        end
    end
    return unknowns, foundMines
end

local function ApplyDeterministicPrediction(tile, probability)
    if probability < 1e-6 then
        if tile.predicted ~= "safe" then
            tile.predicted = "safe"
            return true
        end
    elseif probability > 1 - 1e-6 then
        if tile.predicted ~= "mine" then
            tile.predicted = "mine"
            return true
        end
    end
    return false
end

local function Clamp01(p)
    if p < 0 then return 0 end
    if p > 1 then return 1 end
    return p
end

-- Runs one solver pass. Returns true if new safe/mine predictions were made.
function M.Run(board)
    local tiles = board.Tiles
    local solveMaxCluster = 0
    local solveClusterCount = 0
    local solveDPClusterCount = 0
    local solveDPAbortCount = 0
    local solveDPMaxStates = 0
    local solveDPMs = 0
    local solveGeneration = board.SolveGeneration + 1
    local assignedOutputs = 0

    local function SetProbability(tile, probability)
        probability = Clamp01(probability)
        tile.probability = probability
        tile.ProbabilityGeneration = solveGeneration
        assignedOutputs = assignedOutputs + 1
        return probability
    end
    local function CountState()
        local confirmed, active = 0, 0
        for _, t in ipairs(tiles) do
            if t.Type == "mine" or t.predicted == "mine" then
                confirmed = confirmed + 1
            elseif t.Type == "unknown" and t.predicted == nil then
                active = active + 1
            end
        end
        return confirmed, active
    end
    local function UniformProbability(minesRemaining, activeUnknowns)
        if activeUnknowns <= 0 then return 0 end
        return Clamp01(minesRemaining / activeUnknowns)
    end
    local function SetFallbackProbability(tile, fallbackProbability)
        local probability = tile.probability
        if probability == nil then
            probability = fallbackProbability
        end
        SetProbability(tile, probability)
    end
    local function IsFrontierUnknown(tile)
        if tile.Type ~= "unknown" or tile.predicted ~= nil then return false end
        for _, neighbor in ipairs(tile.Neighbors) do
            if neighbor.Type == "safe_numbered" then return true end
        end
        return false
    end
    local function EnsureFrontierOutputs(fallbackProbability)
        for _, tile in ipairs(tiles) do
            if IsFrontierUnknown(tile) and tile.ProbabilityGeneration ~= solveGeneration then
                SetFallbackProbability(tile, fallbackProbability)
            end
        end
    end
    local function Finish(result)
        if assignedOutputs > 0 then
            board.SolveGeneration = solveGeneration
        end
        board.MinesConfirmed = (CountState())
        local s = board.Stats
        s.LastClusterCount = solveClusterCount
        s.LastMaxCluster = solveMaxCluster
        s.LastDPClusterCount = solveDPClusterCount
        s.LastDPAbortCount = solveDPAbortCount
        s.LastDPMaxStates = solveDPMaxStates
        s.LastDPMs = solveDPMs
        return result
    end
    local function SolveUniform()
        local confirmed, active = CountState()
        local remaining = board.TotalMines - confirmed
        if remaining < 0 then remaining = 0 end
        local probability = UniformProbability(remaining, active)
        local progress = false
        for _, tile in ipairs(tiles) do
            if tile.Type == "unknown" and tile.predicted == nil then
                SetProbability(tile, probability)
                if ApplyDeterministicPrediction(tile, probability) then
                    progress = true
                end
            end
        end
        return progress, probability
    end

    local confirmedMines = CountState()
    board.MinesConfirmed = confirmedMines
    local minesRemaining = board.TotalMines - confirmedMines
    if minesRemaining < 0 then minesRemaining = 0 end

    -- Build equations from numbered tiles.
    local unknownMap = {}
    local unknownList = {}
    local equations = {}
    for _, tile in ipairs(tiles) do
        if tile.Type == "safe_numbered" and tile.Value then
            local unknowns, foundMines = GetTileConstraintState(tile)
            local needed = tile.Value - foundMines
            if #unknowns > 0 and needed >= 0 then
                local eqVars = {}
                for _, uTile in ipairs(unknowns) do
                    if not unknownMap[uTile] then
                        unknownList[#unknownList + 1] = uTile
                        unknownMap[uTile] = #unknownList
                    end
                    eqVars[#eqVars + 1] = unknownMap[uTile]
                end
                equations[#equations + 1] = { needed = needed, vars = eqVars }
            end
        end
    end

    local madeProgress = false
    if #unknownList == 0 then
        local progress, probability = SolveUniform()
        EnsureFrontierOutputs(probability)
        return Finish(progress)
    end

    local reducedEqs, resolvedValues = RunArcConsistencyPreprocess(equations, #unknownList)
    if not reducedEqs then
        local _, active = CountState()
        local fallbackProbability = UniformProbability(minesRemaining, active)
        for _, tile in ipairs(unknownList) do
            if tile.Type == "unknown" and tile.predicted == nil then
                SetFallbackProbability(tile, fallbackProbability)
            end
        end
        EnsureFrontierOutputs(fallbackProbability)
        return Finish(false)
    end

    for varId, value in pairs(resolvedValues) do
        local tile = unknownList[varId]
        if tile and tile.Type == "unknown" then
            SetProbability(tile, value)
            if value == 0 and tile.predicted ~= "safe" then
                tile.predicted = "safe"
                madeProgress = true
            elseif value == 1 and tile.predicted ~= "mine" then
                tile.predicted = "mine"
                madeProgress = true
            end
        end
    end

    -- Remap remaining variables.
    local activeVars = {}
    local oldToNew = {}
    for varId = 1, #unknownList do
        if resolvedValues[varId] == nil then
            activeVars[#activeVars + 1] = unknownList[varId]
            oldToNew[varId] = #activeVars
        end
    end
    local remappedEqs = {}
    for _, eq in ipairs(reducedEqs) do
        local newVars = {}
        local valid = true
        for _, varId in ipairs(eq.vars) do
            local newId = oldToNew[varId]
            if newId then
                newVars[#newVars + 1] = newId
            else
                valid = false
                break
            end
        end
        if valid and #newVars > 0 then
            remappedEqs[#remappedEqs + 1] = { needed = eq.needed, vars = newVars }
        end
    end
    unknownList = activeVars
    reducedEqs = remappedEqs

    if #unknownList == 0 then
        local progress = SolveUniform()
        return Finish(madeProgress or progress)
    end

    -- Split into independent clusters.
    local varToEqIndex = {}
    for i = 1, #unknownList do varToEqIndex[i] = {} end
    for eqIdx, eq in ipairs(reducedEqs) do
        for _, varId in ipairs(eq.vars) do
            local list = varToEqIndex[varId]
            if list then list[#list + 1] = eqIdx end
        end
    end
    local visitedVars = {}
    local clusters = {}
    for i = 1, #unknownList do
        if not visitedVars[i] then
            local clusterVars = {}
            local clusterEqs = {}
            local queue = { i }
            visitedVars[i] = true
            local processedEqs = {}
            local head = 1
            while head <= #queue do
                local currVar = queue[head]
                head = head + 1
                clusterVars[#clusterVars + 1] = currVar
                for _, eqIdx in ipairs(varToEqIndex[currVar] or {}) do
                    if not processedEqs[eqIdx] then
                        processedEqs[eqIdx] = true
                        clusterEqs[#clusterEqs + 1] = reducedEqs[eqIdx]
                        for _, neighborVar in ipairs(reducedEqs[eqIdx].vars) do
                            if not visitedVars[neighborVar] then
                                visitedVars[neighborVar] = true
                                queue[#queue + 1] = neighborVar
                            end
                        end
                    end
                end
            end
            clusters[#clusters + 1] = { vars = clusterVars, eqs = clusterEqs }
        end
    end
    solveClusterCount = #clusters
    for _, cluster in ipairs(clusters) do
        if #cluster.vars > solveMaxCluster then
            solveMaxCluster = #cluster.vars
        end
    end

    local currentConfirmedMines, totalActiveUnknowns = CountState()
    local updatedMinesRemaining = board.TotalMines - currentConfirmedMines
    if updatedMinesRemaining < 0 then updatedMinesRemaining = 0 end
    local fallbackProbability = UniformProbability(updatedMinesRemaining, totalActiveUnknowns)

    local function SetFallbackForCluster(cluster)
        for _, globId in ipairs(cluster.vars) do
            local tile = unknownList[globId]
            if tile and tile.Type == "unknown" and tile.predicted == nil then
                SetFallbackProbability(tile, fallbackProbability)
            end
        end
    end
    local function BuildLocalClusterEquations(cluster)
        local globalToLocal = {}
        for locIdx, globId in ipairs(cluster.vars) do
            globalToLocal[globId] = locIdx
        end
        local localEqs = {}
        for _, eq in ipairs(cluster.eqs) do
            local vars = {}
            for _, globId in ipairs(eq.vars) do
                local localId = globalToLocal[globId]
                if localId then
                    vars[#vars + 1] = localId
                end
            end
            if #vars > 0 then
                localEqs[#localEqs + 1] = { needed = eq.needed, vars = vars }
            end
        end
        return localEqs
    end

    -- Solve each cluster with frontier DP.
    local solvedClusters = {}
    local solvedClusterVarCount = 0
    for _, cluster in ipairs(clusters) do
        local localEqs = BuildLocalClusterEquations(cluster)
        local dpWays, dpHits, dpStatus, dpStates, dpMs = SolveClusterFrontierDP(cluster, localEqs, unknownList)
        if dpStates > solveDPMaxStates then solveDPMaxStates = dpStates end
        solveDPMs = solveDPMs + dpMs
        if dpWays and dpHits and next(dpWays) ~= nil then
            solvedClusters[#solvedClusters + 1] = {
                orderedVars = cluster.vars,
                ways = dpWays,
                hits = dpHits,
                nVars = #cluster.vars
            }
            solvedClusterVarCount = solvedClusterVarCount + #cluster.vars
            solveDPClusterCount = solveDPClusterCount + 1
        else
            if dpStatus ~= "disabled" then
                solveDPAbortCount = solveDPAbortCount + 1
            end
            SetFallbackForCluster(cluster)
        end
    end

    -- Combine clusters with the unconstrained ("free") tiles via total mine count.
    local freeUnknowns = totalActiveUnknowns - solvedClusterVarCount
    if freeUnknowns < 0 then freeUnknowns = 0 end
    local maxMines = updatedMinesRemaining
    local freeDist = {}
    for m = 0, math.min(freeUnknowns, maxMines) do
        local w = Choose(freeUnknowns, m)
        if w > 0 then freeDist[m] = w end
    end
    local prefix = { [0] = { [0] = 1 } }
    for i = 1, #solvedClusters do
        prefix[i] = ConvolveMineDistributions(prefix[i - 1], solvedClusters[i].ways, maxMines)
    end

    local exactFreeTiles = {}
    for _, tile in ipairs(tiles) do
        if tile.Type == "unknown" and tile.predicted == nil and unknownMap[tile] == nil then
            exactFreeTiles[#exactFreeTiles + 1] = tile
        end
    end
    if freeUnknowns > 0 and #exactFreeTiles == freeUnknowns and solveDPAbortCount == 0 then
        local constrainedDist = prefix[#solvedClusters] or { [0] = 1 }
        local totalWeight = 0
        local hitWeight = 0
        for constrainedMines, constrainedWeight in pairs(constrainedDist) do
            local freeMines = maxMines - constrainedMines
            if freeMines >= 0 and freeMines <= freeUnknowns then
                totalWeight = totalWeight + (constrainedWeight * Choose(freeUnknowns, freeMines))
                if freeMines > 0 then
                    hitWeight = hitWeight + (constrainedWeight * Choose(freeUnknowns - 1, freeMines - 1))
                end
            end
        end
        if totalWeight > 0 then
            local freeProbability = Clamp01(hitWeight / totalWeight)
            for _, tile in ipairs(exactFreeTiles) do
                SetProbability(tile, freeProbability)
                if ApplyDeterministicPrediction(tile, freeProbability) then
                    madeProgress = true
                end
            end
        end
    end

    local suffix = {}
    suffix[#solvedClusters + 1] = { [0] = 1 }
    for i = #solvedClusters, 1, -1 do
        suffix[i] = ConvolveMineDistributions(solvedClusters[i].ways, suffix[i + 1], maxMines)
    end
    for clusterIdx, data in ipairs(solvedClusters) do
        local outside = ConvolveMineDistributions(prefix[clusterIdx - 1], suffix[clusterIdx + 1], maxMines)
        outside = ConvolveMineDistributions(outside, freeDist, maxMines)
        local totalWeight = 0
        for m, count in pairs(data.ways) do
            local outsideWeight = outside[maxMines - m] or 0
            totalWeight = totalWeight + (count * outsideWeight)
        end
        if totalWeight > 0 then
            for locIdx, globId in ipairs(data.orderedVars) do
                local tile = unknownList[globId]
                local weightedHits = 0
                for m, count in pairs(data.hits[locIdx]) do
                    local outsideWeight = outside[maxMines - m] or 0
                    weightedHits = weightedHits + (count * outsideWeight)
                end
                local prob = SetProbability(tile, weightedHits / totalWeight)
                if ApplyDeterministicPrediction(tile, prob) then
                    madeProgress = true
                end
            end
        else
            for _, globId in ipairs(data.orderedVars) do
                local tile = unknownList[globId]
                if tile and tile.Type == "unknown" and tile.predicted == nil then
                    SetFallbackProbability(tile, fallbackProbability)
                end
            end
        end
    end
    EnsureFrontierOutputs(fallbackProbability)
    return Finish(madeProgress)
end

-- Runs solver passes until no new deductions (like the live loop re-solving
-- after each change). Returns the number of passes run.
function M.Solve(board, maxPasses)
    maxPasses = maxPasses or CONFIG.MaxSolvePasses or 50
    local passes = 0
    repeat
        passes = passes + 1
        local progress = M.Run(board)
    until not progress or passes >= maxPasses
    return passes
end

---------------------------------------------------------------------------
-- Output helpers
---------------------------------------------------------------------------
-- Returns the unknown tile with the lowest mine probability (best guess/move).
function M.BestMove(board)
    local best = nil
    for _, tile in ipairs(board.Tiles) do
        if tile.Type == "unknown" and tile.predicted ~= "mine" then
            local p = tile.predicted == "safe" and 0
                or (tile.ProbabilityGeneration == board.SolveGeneration and tile.probability)
                or 1
            if not best or p < best.p then
                best = { tile = tile, p = p }
            end
        end
    end
    return best and best.tile, best and best.p
end

local function CellSymbol(tile, board)
    if not tile then return "." end
    if tile.Type == "safe_empty" then return "E" end
    if tile.Type == "safe_numbered" then return tostring(tile.Value or 0) end
    if tile.Type == "mine" then return "M" end
    if tile.predicted == "mine" then return "*" end
    if tile.predicted == "safe" then return "s" end
    return "?"
end

-- Grid view: E/digit revealed, M mine, * predicted mine, s predicted safe, ? undetermined.
-- With showProbabilities, undetermined cells are printed as integer percentages.
function M.Format(board, showProbabilities)
    local lines = {}
    for z = 1, board.Height do
        local row = {}
        for x = 1, board.Width do
            local tile = board.Grid[x][z]
            local sym = CellSymbol(tile, board)
            if showProbabilities then
                if sym == "?" and tile.probability and tile.ProbabilityGeneration == board.SolveGeneration then
                    sym = tostring(Round(tile.probability * 100)) .. "%"
                end
                row[x] = string.format("%5s", sym)
            else
                row[x] = sym
            end
        end
        lines[#lines + 1] = table.concat(row)
    end
    return table.concat(lines, "\n")
end

return M

-- tests/run.lua
-- Self-contained test suite for moonsweep.
-- Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MS = require("moonsweep")
local Bruteforce = require("bruteforce")

local totalTests = 0
local totalPassed = 0

local function test(name, fn)
    totalTests = totalTests + 1
    io.write("  " .. name .. " ... ")
    io.flush()
    local ok, err = pcall(fn)
    if ok then
        totalPassed = totalPassed + 1
        print("PASS")
    else
        print("FAIL")
        print("    " .. tostring(err))
        error("Test suite failed at: " .. name)
    end
end

local function assert_eq(got, expected, msg)
    if got ~= expected then
        error(string.format("assertion failed: got %s, expected %s (%s)",
            tostring(got), tostring(expected), msg or ""), 2)
    end
end

local function assert_near(got, expected, eps, msg)
    eps = eps or 1e-6
    if math.abs(got - expected) > eps then
        error(string.format("assertion failed: got %.8f, expected %.8f (|diff|=%.8f > eps=%.8f) (%s)",
            got, expected, math.abs(got - expected), eps, msg or ""), 2)
    end
end

local function assert_error(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then
        error(string.format("expected error containing '%s', but function succeeded (%s)",
            pattern, msg or ""), 2)
    end
    if pattern and not string.find(tostring(err), pattern, 1, true) then
        error(string.format("expected error containing '%s', but got '%s' (%s)",
            pattern, tostring(err), msg or ""), 2)
    end
end

print("=== moonsweep test suite ===")

-- -------------------------------------------------------------------------
-- Group 1: Known tactical patterns
-- -------------------------------------------------------------------------
print("\n[Group 1: Known tactical patterns]")

test("1-2-1 pattern deduction", function()
    -- Classic 1-2-1 against an open wall:
    -- Clues: 1, 2, 1 at row 1
    -- Unknowns: ?, ?, ? at row 2
    -- In standard minesweeper, the 1-2-1 forces mines at positions 1 and 3,
    -- and a safe cell at position 2.
    local board = MS.BuildBoard({
        "121",
        "???",
    }, 2, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok", "status should be ok")
    assert_eq(board.Exact, true, "exact should be true")

    local t1 = board.Grid[1][2]
    local t2 = board.Grid[2][2]
    local t3 = board.Grid[3][2]

    assert_eq(t1.predicted, "mine", "cell (1,2) must be mine")
    assert_near(t1.probability, 1.0, 1e-6, "cell (1,2) p=1.0")

    assert_eq(t2.predicted, "safe", "cell (2,2) must be safe")
    assert_near(t2.probability, 0.0, 1e-6, "cell (2,2) p=0.0")

    assert_eq(t3.predicted, "mine", "cell (3,2) must be mine")
    assert_near(t3.probability, 1.0, 1e-6, "cell (3,2) p=1.0")
end)

test("1-2-2-1 pattern deduction", function()
    -- 1-2-2-1 pattern on a flat frontier:
    -- Clues: 1, 2, 2, 1
    -- Unknowns: 4 cells underneath
    -- Forces safe at outer cells, mines at middle two cells.
    local board = MS.BuildBoard({
        "1221",
        "????",
    }, 2, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok")
    assert_eq(board.Grid[1][2].predicted, "safe")
    assert_eq(board.Grid[2][2].predicted, "mine")
    assert_eq(board.Grid[3][2].predicted, "mine")
    assert_eq(board.Grid[4][2].predicted, "safe")
end)

test("Corner deduction", function()
    -- Corner 1 touching a single unknown cell:
    -- 1 .
    -- 1 ?
    -- Cell (1,1) has clue 1 and only one unknown neighbor (2,2).
    -- Therefore, (2,2) must be a mine.
    local board = MS.BuildBoard({
        "1.",
        "1?"
    }, 1, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok")
    assert_eq(board.Grid[2][2].predicted, "mine")
    assert_near(board.Grid[2][2].probability, 1.0, 1e-6)
end)

test("Solved endgame", function()
    local board = MS.BuildBoard({
        "E1M",
        "E11",
        "EEE"
    }, 1, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok")
    assert_eq(board.Exact, true)
    local bestTile = MS.BestMove(board)
    assert_eq(bestTile, nil, "no moves left in solved board")
end)

-- -------------------------------------------------------------------------
-- Group 2: Mine count and unconstrained tiles
-- -------------------------------------------------------------------------
print("\n[Group 2: Mine count and unconstrained tiles]")

test("Board with no clues (uniform prior)", function()
    local board = MS.BuildBoard({
        "?????",
        "?????",
        "?????",
        "?????",
    }, 4, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok")
    assert_eq(board.Exact, true)
    -- 20 tiles, 4 mines -> exactly 0.20 for all
    for _, tile in ipairs(board.Tiles) do
        assert_near(tile.probability, 0.20, 1e-6, "uniform probability")
    end
end)

test("Zero mines remaining", function()
    local board = MS.BuildBoard({
        "M1?",
        "11?",
        "???"
    }, 1, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok")
    -- The single mine is already confirmed at (1,1). All other unknowns must be safe!
    for _, tile in ipairs(board.Tiles) do
        if tile.Type == "unknown" then
            assert_eq(tile.predicted, "safe", "all remaining must be safe")
            assert_near(tile.probability, 0.0, 1e-6)
        end
    end
end)

test("All remaining unknowns are mines", function()
    local board = MS.BuildBoard({
        "???",
        "???"
    }, 6, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok")
    for _, tile in ipairs(board.Tiles) do
        assert_eq(tile.predicted, "mine")
        assert_near(tile.probability, 1.0, 1e-6)
    end
end)

test("Independent clusters with global mine count", function()
    -- Two disconnected components: each needs 1 mine out of 2 cells.
    -- Total mines = 2.
    local board = MS.BuildBoard({
        "11....",
        "??....",
        "....11",
        "....??"
    }, 2, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok")
    assert_eq(board.Exact, true)
    assert_near(board.Grid[1][2].probability, 0.50, 1e-6)
    assert_near(board.Grid[2][2].probability, 0.50, 1e-6)
    assert_near(board.Grid[5][4].probability, 0.50, 1e-6)
    assert_near(board.Grid[6][4].probability, 0.50, 1e-6)
end)

-- -------------------------------------------------------------------------
-- Group 3: Contradictions and edge cases
-- -------------------------------------------------------------------------
print("\n[Group 3: Contradictions and edge cases]")

test("Contradictory clues flag status", function()
    -- E next to 1s forcing 2 mines, but center clue is 1:
    local board = MS.BuildBoard({
        "E1?",
        "11?",
        "???"
    }, 3, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "contradiction", "conflicting clues must report contradiction")
    assert_eq(board.Exact, false, "exact must be false on contradiction")
end)

test("Clue exceeds total remaining mines", function()
    -- Clue 2 in corner needs 2 mines, but board only has 1 mine total:
    local board = MS.BuildBoard({
        "2?",
        "??"
    }, 1, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "contradiction")
    assert_eq(board.Exact, false)
end)

test("More confirmed mines than TotalMines", function()
    local board = MS.BuildBoard({
        "MM",
        "??"
    }, 1, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "contradiction")
    assert_eq(board.Exact, false)
end)

-- -------------------------------------------------------------------------
-- Group 4: Input validation
-- -------------------------------------------------------------------------
print("\n[Group 4: Input validation]")

test("Ragged rows raise clear error", function()
    assert_error(function()
        MS.BuildBoard({ "1??", "?" }, 2)
    end, "moonsweep: row length mismatch")
end)

test("Unknown characters raise clear error", function()
    assert_error(function()
        MS.BuildBoard({ "1x?", "???" }, 2)
    end, "moonsweep: unknown cell character 'x'")
end)

test("Empty board raises clear error", function()
    assert_error(function()
        MS.BuildBoard({}, 1)
    end, "moonsweep: rows must be a non-empty table")
end)

test("Total mines exceeds tile count raises clear error", function()
    assert_error(function()
        MS.BuildBoard({ "1??", "???" }, 99)
    end, "moonsweep: totalMines (99) exceeds tile count (6)")
end)

test("Unknown mode raises clear error", function()
    assert_error(function()
        MS.BuildBoard({ "1??", "???" }, 2, "Nope")
    end, "moonsweep: unknown mode 'Nope'")
end)

test("Clue exceeding neighbor count raises clear error", function()
    -- In Cornerless mode, corner cell has only 2 neighbors (up/down/left/right)
    assert_error(function()
        MS.BuildBoard({ "3?", "??" }, 3, "Cornerless")
    end, "moonsweep: clue 3 exceeds neighbor count 2")
end)

-- -------------------------------------------------------------------------
-- Group 5: Board reset and incremental updates (SetCell)
-- -------------------------------------------------------------------------
print("\n[Group 5: Board reset and incremental updates]")

test("SetCell updates cell and resets solver state", function()
    local board = MS.BuildBoard({
        "???",
        "???"
    }, 1, "Regular")
    MS.Solve(board)
    assert_eq(board.Status, "ok")
    assert_near(board.Grid[1][1].probability, 1/6, 1e-6)

    -- Now reveal (1,1) as an empty cell (0 mines)
    MS.SetCell(board, 1, 1, "E")
    assert_eq(board.Grid[1][1].Type, "safe_empty")
    -- Because solver output is reset:
    assert_eq(board.Grid[2][2].predicted, nil)

    -- Re-solve: all neighbors of E should now be safe!
    MS.Solve(board)
    assert_eq(board.Grid[2][1].predicted, "safe")
    assert_eq(board.Grid[1][2].predicted, "safe")
    assert_eq(board.Grid[2][2].predicted, "safe")
end)

test("Out of bounds SetCell raises clear error", function()
    local board = MS.BuildBoard({ "??", "??" }, 1)
    assert_error(function()
        MS.SetCell(board, 5, 5, "1")
    end, "moonsweep: coordinates out of bounds")
end)

-- -------------------------------------------------------------------------
-- Group 6: Board modes
-- -------------------------------------------------------------------------
print("\n[Group 6: Board modes]")

local allModes = { "Regular", "Large", "Cornerless", "Corners", "Knight", "Cross", "Wrap", "Calculative" }
for _, modeName in ipairs(allModes) do
    test("Mode " .. modeName .. " builds and solves cleanly", function()
        local rows
        if modeName == "Calculative" then
            -- Calculative mode: clue 9 encodes quotient 1, remainder 1 -> effective clue 1
            rows = {
                { "?", "?", "?", "?", "?" },
                { "?", "?", "?", "?", "?" },
                { "?", "?", 9,   "?", "?" },
                { "?", "?", "?", "?", "?" },
                { "?", "?", "?", "?", "?" }
            }
        else
            rows = {
                "?????",
                "?????",
                "??1??",
                "?????",
                "?????"
            }
        end
        local board = MS.BuildBoard(rows, 1, modeName)
        local passes = MS.Solve(board)
        assert_eq(type(passes), "number")
        assert_eq(board.Status, "ok")
    end)
end

-- -------------------------------------------------------------------------
-- Group 7: Brute-force verification
-- -------------------------------------------------------------------------
print("\n[Group 7: Brute-force exact probability comparison]")

test("Brute-force comparison on 50 random positions", function()
    local res = Bruteforce.RunBruteForceTest(50, 12345, false)
    assert_eq(res.fails, 0, "brute force comparison must have 0 failures")
    assert_eq(res.checked > 0, true, "checked boards must be > 0")
end)

print(string.format("\nAll %d tests passed successfully!", totalPassed))

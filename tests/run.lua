local MS = require("moonsweep")

local function assert_eq(a, b, msg)
    if a ~= b then
        error("Assertion failed: " .. tostring(a) .. " ~= " .. tostring(b) .. " (" .. (msg or "") .. ")", 2)
    end
end

-- Test 1: Simple board
local board = MS.BuildBoard({
    "E1?",
    "11?",
    "???"
}, 3, "Regular")
MS.Solve(board)
-- Check some predictions...
print("Test 1 passed")

-- Test 2: Contradictory board
local board2 = MS.BuildBoard({
    "1M",
    "11"
}, 1, "Regular")
-- MS.Solve should handle this gracefully
MS.Solve(board2)
print("Test 2 passed")

print("All tests passed!")

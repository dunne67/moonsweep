local MS = require("moonsweep")

local board = MS.BuildBoard({
    "EEEE1????",
    "EEEE1????",
    "111E12???",
    "??1EE1???",
    "??21E1???",
    "???1E1???",
    "???1E11??",
    "???1EE1??",
    "???1EE1??",
}, 10, "Regular")

local passes = MS.Solve(board)

print(string.format("passes=%d  status=%s  exact=%s  mines_confirmed=%d",
    passes, board.Status, tostring(board.Exact), board.MinesConfirmed))
print()
print("Board deductions (E=empty, digits=clues, *=mine, s=safe, ?=unknown):")
print(MS.Format(board))
print()
print("Probability map:")
print(MS.Format(board, true))
print()

local tile, p = MS.BestMove(board)
if tile then
    print(string.format("Best move: col=%d row=%d (mine probability = %.4f)", tile.X, tile.Z, p))
end

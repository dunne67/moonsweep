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
print(string.format("passes=%d clusters=%d dp=%d aborts=%d",
    passes, board.Stats.LastClusterCount, board.Stats.LastDPClusterCount, board.Stats.LastDPAbortCount))
print(MS.Format(board))
print()
print(MS.Format(board, true))
local tile, p = MS.BestMove(board)
if tile then
    print(string.format("best move: x=%d z=%d p=%.4f", tile.X, tile.Z, p))
end

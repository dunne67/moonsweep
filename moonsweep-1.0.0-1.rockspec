package = "moonsweep"
version = "1.0.0-1"
source = {
   url = "git+https://github.com/dunne67/moonsweep.git",
   tag = "v1.0.0"
}
description = {
   summary = "Fast, exact-probability Minesweeper solver in pure Lua (5.1+ / LuaJIT).",
   detailed = [[
      A standalone, single-file Minesweeper probability solver supporting
      8 board modes, arc-consistency preprocessing, frontier dynamic
      programming per cluster, and global mine-count convolution.
   ]],
   homepage = "https://github.com/dunne67/moonsweep",
   license = "MIT"
}
dependencies = {
   "lua >= 5.1"
}
build = {
   type = "builtin",
   modules = {
      moonsweep = "moonsweep.lua"
   }
}

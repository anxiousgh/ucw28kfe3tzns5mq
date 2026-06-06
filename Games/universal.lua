-- ============================================================
--  witherhook // Games/universal.lua
--  Fallback for games NOT in the games list. The universal feature
--  set lives in main.lua, so just load that.
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

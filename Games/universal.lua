-- ============================================================
--  witherhook // Games/universal.lua
--  Default menu shell, loaded when no game-specific module exists.
--  Functions stripped for now: every callback is an empty stub and
--  no :AddKeybind() chains (the library's AddKeybind crashes in some
--  games by touching PlayerGui.Chat).
-- ============================================================
local ctx     = ({ ... })[1]
local library = ctx.library
local Window  = ctx.window

-- ============================================================
--  COMBAT
-- ============================================================
local Combat = Window:NewTab("Combat")
Combat:NewSection("Aim")

Combat:NewToggle("Silent aim", false, function() end)
Combat:NewToggle("Triggerbot", false, function() end)
Combat:NewToggle("Team check", true, function() end)
Combat:NewSelector("Hit part", "Head", { "Head", "HumanoidRootPart", "UpperTorso", "Random" }, function() end)
Combat:NewSlider("FOV radius", "", true, "/", { min = 1, max = 1000, default = 120 }, function() end)
Combat:NewSlider("Hit chance", "%", true, "/", { min = 0, max = 100, default = 100 }, function() end)

-- ============================================================
--  VISUALS
-- ============================================================
local Visuals = Window:NewTab("Visuals")
Visuals:NewSection("ESP")

Visuals:NewToggle("Enabled", false, function() end)
Visuals:NewToggle("Boxes", true, function() end)
Visuals:NewToggle("Names", true, function() end)
Visuals:NewToggle("Health bars", true, function() end)
Visuals:NewToggle("Tracers", false, function() end)

Visuals:NewSection("World")
Visuals:NewToggle("Fullbright", false, function() end)
Visuals:NewSlider("FOV", "", true, "/", { min = 30, max = 120, default = 70 }, function() end)

-- ============================================================
--  MOVEMENT
-- ============================================================
local Movement = Window:NewTab("Movement")
Movement:NewSection("Speed")

Movement:NewToggle("Fly", false, function() end)
Movement:NewSlider("Fly speed", "", true, "/", { min = 5, max = 500, default = 50 }, function() end)
Movement:NewToggle("Walkspeed", false, function() end)
Movement:NewSlider("Walkspeed value", "", true, "/", { min = 16, max = 500, default = 50 }, function() end)
Movement:NewToggle("Bunnyhop", false, function() end)
Movement:NewToggle("Infinite jump", false, function() end)
Movement:NewToggle("Noclip", false, function() end)

-- ============================================================
--  MISC
-- ============================================================
local Misc = Window:NewTab("Misc")
Misc:NewSection("Utility")

Misc:NewButton("Rejoin server", function() end)
Misc:NewButton("Copy username", function() end)
Misc:NewToggle("Anti-AFK", false, function() end)
Misc:NewTextbox("Chat spam text", "", "spam", "all", "medium", true, false, function() end)

-- ============================================================
--  SETTINGS
-- ============================================================
local Settings = Window:NewTab("Settings")
Settings:NewSection("Menu")

Settings:NewLabel("witherhook v" .. library.version, "center")
Settings:NewLabel("logged in as " .. library:GetUsername(), "center")
Settings:NewButton("Unload witherhook", function() end)

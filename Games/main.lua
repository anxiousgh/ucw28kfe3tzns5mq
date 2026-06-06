-- ============================================================
--  witherhook // Games/main.lua
--  Shared feature set for EVERY game: Movement, Misc, Settings, Config.
--  Wired to the decay backend (functions.lua -> hook).
-- ============================================================
local ctx     = ({ ... })[1]
local library = ctx.library
local Window  = ctx.window
local Notif   = ctx.notif

local HttpService = game:GetService("HttpService")

local function notify(text, dur, kind)
    if Notif then pcall(function() Notif:Notify(text, dur or 4, kind or "information") end) end
end

-- ---------- backend ----------
local hook
do
    local ok, res = pcall(function() return ctx.load("functions.lua")() end)
    if not ok or type(res) ~= "table" then
        notify("witherhook: backend failed to load (see console)", 6, "error")
        warn("[witherhook/main] functions.lua failed: " .. tostring(res))
        return
    end
    hook = res
end

-- ============================================================
--  PERSISTENCE (executor file API, all guarded)
-- ============================================================
local hasFS = (typeof(writefile) == "function")
    and (typeof(readfile) == "function") and (typeof(isfile) == "function")

local ROOT      = "witherhook"
local CFG_ROOT  = ROOT .. "/configs"
local UNI_DIR   = CFG_ROOT .. "/universal"
local placeId   = tostring(ctx.gameKey or "0")
local GAME_DIR  = CFG_ROOT .. "/games/" .. placeId
local SETTINGS_PATH = ROOT .. "/settings.json"
local AUTOLOAD_PATH = ROOT .. "/autoload.json"

-- Supported games: PlaceId (string) -> display name. A game is "supported"
-- (gets its OWN config system named after it) only if listed here.
-- Every other game uses the universal config system. The two never mix.
local GAMES = {
    -- ["2788229376"] = "Hood Customs",
    -- ["155615604"]  = "Prison Life",
    -- ["286090429"]  = "Minesweeper",
}
local supportedName = GAMES[placeId]   -- nil => unsupported => universal configs

local function ensureFolder(path)
    if typeof(makefolder) == "function" and typeof(isfolder) == "function" then
        if not isfolder(path) then pcall(makefolder, path) end
    end
end
local function writeJSON(path, tbl)
    if not hasFS then return false end
    local ok, enc = pcall(function() return HttpService:JSONEncode(tbl) end)
    if not ok then return false end
    return (pcall(writefile, path, enc))
end
local function readJSON(path)
    if not hasFS or not isfile(path) then return nil end
    local ok, data = pcall(readfile, path)
    if not ok then return nil end
    local ok2, dec = pcall(function() return HttpService:JSONDecode(data) end)
    if ok2 then return dec end
    return nil
end
local function listConfigs(folder)
    local names = {}
    if typeof(listfiles) == "function" and typeof(isfolder) == "function" and isfolder(folder) then
        for _, f in ipairs(listfiles(folder)) do
            local name = f:match("([^/\\]+)%.json$")
            if name then table.insert(names, name) end
        end
    end
    table.sort(names)
    return names
end

if hasFS then
    ensureFolder(ROOT); ensureFolder(CFG_ROOT); ensureFolder(UNI_DIR)
    ensureFolder(CFG_ROOT .. "/games"); ensureFolder(GAME_DIR)
end

-- ============================================================
--  FLAG REGISTRY (config save/load operates on these)
-- ============================================================
local flags    = {}   -- key -> current value
local controls = {}   -- key -> { set = fn(value) }

-- Everything currently switched ON, with the function that turns it back
-- off. A module is added when its toggle goes on and removed when it goes
-- off, so on unload we can stop every still-active module cleanly.
local activeStoppers = {}   -- key -> fn() that stops that module

local function stopAllActive()
    local fns = {}
    for _, fn in pairs(activeStoppers) do fns[#fns + 1] = fn end
    for _, fn in ipairs(fns) do pcall(fn) end   -- snapshot first: each call mutates activeStoppers
    activeStoppers = {}
end

local function regToggle(tab, key, text, default, cb)
    flags[key] = default
    local h = tab:NewToggle(text, default, function(v)
        flags[key] = v
        if v then activeStoppers[key] = function() h:Set(false) end
        else activeStoppers[key] = nil end
        if cb then cb(v) end
    end)
    controls[key] = { set = function(v) h:Set(v and true or false) end }
    return h
end
local function regSlider(tab, key, text, suffix, vals, cb)
    flags[key] = vals.default
    local h = tab:NewSlider(text, suffix, false, "/", vals,
        function(v) flags[key] = v; if cb then cb(v) end end)
    -- Slider:Value only updates visuals, so re-fire the callback on apply
    controls[key] = { set = function(v) h:Value(v); flags[key] = v; if cb then cb(v) end end }
    return h
end
local function regDropdown(tab, key, text, default, list, multi, cb)
    flags[key] = default
    local h = tab:NewDropdown(text, default, list, multi,
        function(v) flags[key] = v; if cb then cb(v) end end)
    controls[key] = { set = function(v) h:Set(v) end }   -- Dropdown:Set fires cb
    return h
end

-- Expose backend + registry helpers so universal / per-game modules can add
-- tabs that integrate with configs, autoload and unload (active-tracking).
ctx.api = {
    hook        = hook,
    notify      = notify,
    regToggle   = regToggle,
    regSlider   = regSlider,
    regDropdown = regDropdown,
}

-- ============================================================
--  MOVEMENT
-- ============================================================
local Movement = Window:NewTab("Movement")

Movement:NewSection("Movement")
regToggle(Movement, "Fly", "Fly", false, function(v) if v then hook.fly.start() else hook.fly.stop() end end)
regSlider(Movement, "FlySpeed", "Fly speed", "", { min = 5, max = 3000, default = hook.fly.getSpeed() or 60 },
    function(v) hook.fly.setSpeed(v) end)

regToggle(Movement, "Walkspeed", "Walkspeed", false, function(v) if v then hook.walkspeed.start() else hook.walkspeed.stop() end end)
regSlider(Movement, "WalkspeedValue", "Walkspeed value", "", { min = 8, max = 1000, default = hook.walkspeed.getValue() or 50 },
    function(v) hook.walkspeed.setValue(v) end)

regToggle(Movement, "JumpPower", "Jump power", false, function(v) if v then hook.jumpPower.start() else hook.jumpPower.stop() end end)
regSlider(Movement, "JumpPowerValue", "Jump power value", "", { min = 0, max = 2000, default = hook.jumpPower.getValue() or 50 },
    function(v) hook.jumpPower.setValue(v) end)

regToggle(Movement, "CFrameSpeed", "CFrame speed", false,
    function(v) if v then hook.cframeSpeed.start(hook.cframeSpeed.getMultiplier()) else hook.cframeSpeed.stop() end end)
regSlider(Movement, "CFrameMult", "CFrame speed multiplier", "x", { min = 1, max = 100, default = hook.cframeSpeed.getMultiplier() or 2 },
    function(v) hook.cframeSpeed.setMultiplier(v) end)

regToggle(Movement, "AllowJump", "Allow jump", false, function(v) if v then hook.forceJump.start() else hook.forceJump.stop() end end)

-- ---------- CSGO HVH movement ----------
Movement:NewSection("CSGO HVH movement")
regToggle(Movement, "HVH", "HVH enabled", false, function(v) if v then hook.hvhMovement.start() else hook.hvhMovement.stop() end end)
regSlider(Movement, "HVHAmtMin", "Jiggle amount min", " deg", { min = 0, max = 180, default = 15 }, function(v) hook.hvhMovement.setJiggleAmountMin(v) end)
regSlider(Movement, "HVHAmtMax", "Jiggle amount max", " deg", { min = 0, max = 180, default = 35 }, function(v) hook.hvhMovement.setJiggleAmountMax(v) end)
regSlider(Movement, "HVHFreqMin", "Jiggle freq min", " Hz", { min = 1, max = 30, default = 1 }, function(v) hook.hvhMovement.setJiggleFreqMin(v) end)
regSlider(Movement, "HVHFreqMax", "Jiggle freq max", " Hz", { min = 1, max = 30, default = 3 }, function(v) hook.hvhMovement.setJiggleFreqMax(v) end)

-- ---------- Extras ----------
Movement:NewSection("Extras")
regToggle(Movement, "Spin", "Spin", false, function(v) if v then hook.spin.start() else hook.spin.stop() end end)
regSlider(Movement, "SpinSpeed", "Spin speed", "", { min = 1, max = 1000, default = 50 }, function(v) hook.spin.setSpeed(v) end)

-- Upside down / Tilt are mutually exclusive
local flipT, tiltT
flipT = regToggle(Movement, "UpsideDown", "Upside down", false, function(v)
    if v then if tiltT then tiltT:Set(false) end; hook.flip.start() else hook.flip.stop() end
end)
tiltT = regToggle(Movement, "TiltSideways", "Tilt sideways", false, function(v)
    if v then if flipT then flipT:Set(false) end; hook.tilt.start() else hook.tilt.stop() end
end)

regToggle(Movement, "IceSlide", "Ice slide", false, function(v) if v then hook.ice.start() else hook.ice.stop() end end)
regSlider(Movement, "IceFriction", "Slide friction", "%", { min = 50, max = 99, default = 98 }, function(v) hook.ice.setSlide(v / 100) end)

-- ---------- Desync ----------
Movement:NewSection("Desync")
local desyncMode, desyncOn = "Void", false
local desyncMin, desyncMax = 5000, 20000
local desyncEnableT
local MODE_START = {
    Void     = function() hook.desync.startVoid()     return true end,
    Sky      = function() hook.desync.startSky()      return true end,
    Spin     = function() hook.desync.startSpin()     return true end,
    Velocity = function() hook.desync.startVelocity() return true end,
    Raknet   = function()
        local ok = hook.desync.startRaknet()
        if not ok then notify("Raknet desync unavailable: executor doesn't expose `raknet`", 5, "error") end
        return ok
    end,
}
regDropdown(Movement, "DesyncMode", "Desync mode", "Void", { "Void", "Sky", "Spin", "Velocity", "Raknet" }, false, function(v)
    desyncMode = v
    if desyncOn then
        hook.desync.stop()
        local starter = MODE_START[v]
        if not starter or not starter() then if desyncEnableT then desyncEnableT:Set(false) end end
    end
end)
desyncEnableT = regToggle(Movement, "DesyncEnabled", "Enable desync", false, function(v)
    desyncOn = v
    if v then
        local starter = MODE_START[desyncMode]
        if not starter or not starter() then if desyncEnableT then desyncEnableT:Set(false) end end
    else
        hook.desync.stop()
    end
end)
regSlider(Movement, "DesyncMin", "Void min distance", "", { min = 500, max = 100000, default = 5000 },
    function(v) desyncMin = v; hook.desync.setRange(desyncMin, desyncMax) end)
regSlider(Movement, "DesyncMax", "Void max distance", "", { min = 500, max = 100000, default = 20000 },
    function(v) desyncMax = v; hook.desync.setRange(desyncMin, desyncMax) end)
regSlider(Movement, "DesyncSpinSpeed", "Spin speed (deg/frame)", "", { min = 1, max = 360, default = 47 }, function(v) hook.desync.setSpinSpeed(v) end)
regSlider(Movement, "DesyncVelMag", "Velocity magnitude", "", { min = 100, max = 100000, default = 16384 }, function(v) hook.desync.setVelocityMag(v) end)
regSlider(Movement, "DesyncSkyHeight", "Sky height", "", { min = 50, max = 100000, default = 5000 }, function(v) hook.desync.setSkyHeight(v) end)

-- ============================================================
--  MISC
-- ============================================================
local Misc = Window:NewTab("Misc")
Misc:NewSection("Anti-fling")
regToggle(Misc, "AntiFling", "Anti-fling", false, function(v) if v then hook.antiFling.start() else hook.antiFling.stop() end end)
regSlider(Misc, "AntiFlingCap", "Velocity cap", " stud/sec", { min = 100, max = 50000, default = 5000 }, function(v) hook.antiFling.setCap(v) end)

Misc:NewSection("Enable chat")
regToggle(Misc, "ForceChat", "Re-enable chat", false, function(v) if v then hook.forceChat.start() else hook.forceChat.stop() end end)

Misc:NewSection("Proximity prompts")
regToggle(Misc, "PromptInstant", "Instant activation", false, function(v) if v then hook.prompts.instantActivation.start() else hook.prompts.instantActivation.stop() end end)
regToggle(Misc, "PromptRange",   "Unlimited range",   false, function(v) if v then hook.prompts.unlimitedRange.start()  else hook.prompts.unlimitedRange.stop()  end end)
regToggle(Misc, "PromptWalls",   "Through walls",     false, function(v) if v then hook.prompts.throughWalls.start()    else hook.prompts.throughWalls.stop()    end end)
regToggle(Misc, "PromptAutoFire","Auto-fire",         false, function(v) if v then hook.prompts.autoFire.start()        else hook.prompts.autoFire.stop()        end end)

-- ============================================================
--  SETTINGS  (universal GUI prefs, autosaved, NOT part of configs)
-- ============================================================
local settings = readJSON(SETTINGS_PATH) or {}
local function saveSettings() writeJSON(SETTINGS_PATH, settings) end

local Settings = Window:NewTab("Settings")
Settings:NewSection("Appearance (universal, autosaved)")

local themeNames = {}
for name in pairs(library.themes) do table.insert(themeNames, name) end
table.sort(themeNames)

Settings:NewDropdown("Theme", settings.theme or "Witherhook", themeNames, false, function(v)
    local c = library.themes[v]
    if c then library:SetAccent(c); settings.theme = v; saveSettings() end
end)

local fontNames = { "Code", "Gotham", "GothamBold", "GothamBlack", "SourceSans", "SourceSansBold",
    "Roboto", "RobotoMono", "Arcade", "Fantasy", "Antique", "Michroma", "Ubuntu" }
Settings:NewDropdown("Font", settings.font or "Code", fontNames, false, function(v)
    library:SetFont(v); settings.font = v; saveSettings()
end)

Settings:NewSlider("UI scale", "%", false, "/", { min = 50, max = 150, default = settings.scale or 100 }, function(v)
    library:SetScale(v / 100); settings.scale = v; saveSettings()
end)

Settings:NewSection("Menu")
Settings:NewButton("Unload witherhook", function()
    stopAllActive()      -- stop every still-active module first
    library:Remove()
end)

-- ============================================================
--  CONFIG  (universal + per-game, save/load/delete/autoload)
-- ============================================================
local autoload = readJSON(AUTOLOAD_PATH) or { universal = false, games = {} }
autoload.games = autoload.games or {}
local function saveAutoload() writeJSON(AUTOLOAD_PATH, autoload) end

local function snapshot()
    local s = {}
    for k, v in pairs(flags) do s[k] = v end
    return s
end
local function applyConfig(data)
    if type(data) ~= "table" then return end
    for k, v in pairs(data) do
        if controls[k] then pcall(controls[k].set, v) end
    end
end
local function saveConfig(dir, name)
    if not name or name == "" then return notify("Enter a config name first", 3, "alert") end
    if not hasFS then return notify("No file API in this executor", 4, "error") end
    ensureFolder(dir)
    if writeJSON(dir .. "/" .. name .. ".json", snapshot()) then
        notify("Saved config: " .. name, 3, "success")
    else
        notify("Save failed", 4, "error")
    end
end
local function loadConfig(dir, name)
    if not name or name == "" then return notify("Select a config first", 3, "alert") end
    local data = readJSON(dir .. "/" .. name .. ".json")
    if data then applyConfig(data); notify("Loaded config: " .. name, 3, "success")
    else notify("Config not found: " .. tostring(name), 3, "error") end
end
local function deleteConfig(dir, name)
    if not name or name == "" then return end
    if typeof(delfile) == "function" and isfile(dir .. "/" .. name .. ".json") then
        pcall(delfile, dir .. "/" .. name .. ".json")
        notify("Deleted config: " .. name, 3, "success")
    end
end

local Config = Window:NewTab("Config")

-- One config system, chosen by support status:
--   supported game  -> game configs (named after the game), no universal
--   unsupported     -> universal configs only
local CFG_DIR, sectionTitle, getAuto, setAuto, clearAuto
if supportedName then
    CFG_DIR      = GAME_DIR
    sectionTitle = supportedName .. " — Configs"
    getAuto      = function() return autoload.games[placeId] end
    setAuto      = function(n) autoload.games[placeId] = n end
    clearAuto    = function() autoload.games[placeId] = false end
else
    CFG_DIR      = UNI_DIR
    sectionTitle = "Universal Configs (unsupported game)"
    getAuto      = function() return autoload.universal end
    setAuto      = function(n) autoload.universal = n end
    clearAuto    = function() autoload.universal = false end
end

Config:NewSection(sectionTitle)
local cfgNameVal, cfgSel = "", nil
Config:NewTextbox("New config name", "", "name", "all", "medium", true, false, function(v) cfgNameVal = v end)
local cfgListD   = Config:NewDropdown("Saved configs", "—", listConfigs(CFG_DIR), false, function(v) cfgSel = v end)
local cfgAutoLbl = Config:NewLabel("Autoload: " .. tostring(getAuto() or "none"), "left")

local function refreshCfg()
    local list = listConfigs(CFG_DIR)
    if #list == 0 then list = { "—" } end
    cfgListD:SetOptions(list)
    cfgAutoLbl:Text("Autoload: " .. tostring(getAuto() or "none"))
end

Config:NewButton("Save", function() saveConfig(CFG_DIR, cfgNameVal); refreshCfg() end)
:AddButton("Load", function() loadConfig(CFG_DIR, cfgSel) end)
Config:NewButton("Delete", function() deleteConfig(CFG_DIR, cfgSel); refreshCfg() end)
:AddButton("Refresh", function() refreshCfg() end)
Config:NewButton("Set autoload", function()
    if cfgSel and cfgSel ~= "—" then setAuto(cfgSel); saveAutoload(); refreshCfg(); notify("Autoload set: " .. cfgSel, 3, "success") end
end)
:AddButton("Clear autoload", function()
    clearAuto(); saveAutoload(); refreshCfg(); notify("Autoload cleared", 3, "information")
end)

-- ============================================================
--  APPLY universal settings, then autoload a config
-- ============================================================
library:SetAccent(library.themes[settings.theme or "Witherhook"] or library.themes.Witherhook)
library:SetFont(settings.font or "Code")
library:SetScale((settings.scale or 100) / 100)

task.defer(function()
    local n = getAuto()
    if n and n ~= false then loadConfig(CFG_DIR, n) end
end)

notify("witherhook ready", 3, "success")

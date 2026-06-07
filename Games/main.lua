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

local muteNotifs = false   -- toggled in Settings; set from saved settings on load
local function notify(text, dur, kind)
    if muteNotifs then return end
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
local SETTINGS_PATH = ROOT .. "/settings.json"
local AUTOLOAD_PATH = ROOT .. "/autoload.json"

-- Supported games: PlaceId (string) -> display name. A game is "supported"
-- (gets its OWN config system named after it) only if listed here.
-- Every other game uses the universal config system. The two never mix.
local GAMES = {
    ["155615604"]     = "Prison Life",
    ["142823291"]     = "Murder Mystery 2",
    ["138995385694035"] = "Hood Customs",
    ["9825515356"]      = "Hood Customs",
}
local supportedName = GAMES[placeId]   -- nil => unsupported => universal configs

-- Supported games share their config folder by NAME, so e.g. Hood Customs'
-- two PlaceIds use the SAME configs. (Unsupported games use universal, not
-- GAME_DIR.)
local cfgKey   = supportedName and supportedName:gsub("[^%w]+", "_") or placeId
local GAME_DIR = CFG_ROOT .. "/games/" .. cfgKey

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

-- colour presets + colour-picker / decimal-slider helpers
local COLORS = {
    White  = Color3.fromRGB(255, 255, 255), Red    = Color3.fromRGB(255, 60, 60),
    Green  = Color3.fromRGB(80, 255, 80),   Blue   = Color3.fromRGB(80, 150, 255),
    Purple = Color3.fromRGB(232, 158, 255), Cyan   = Color3.fromRGB(90, 230, 230),
    Yellow = Color3.fromRGB(255, 230, 90),  Orange = Color3.fromRGB(255, 150, 70),
    Gray   = Color3.fromRGB(120, 120, 120), Black  = Color3.fromRGB(0, 0, 0),
}
-- HSV colour picker (NewColorpicker); config-saved as a hex string.
-- `default` may be a Color3 or a COLORS preset name.
local function regColor(tab, key, text, default, apply)
    local defaultColor = (typeof(default) == "Color3") and default or (COLORS[default] or COLORS.White)
    flags[key] = defaultColor:ToHex()
    local h = tab:NewColorpicker(text, defaultColor, function(c)
        flags[key] = c:ToHex()
        apply(c)
    end)
    controls[key] = { set = function(hex)
        if type(hex) ~= "string" then return end
        local ok, col = pcall(Color3.fromHex, hex)
        if ok and typeof(col) == "Color3" then flags[key] = hex; h:Set(col) end
    end }
    return h
end
-- Xsx slider is integer-only; present an int range, apply value/scale.
local function regDecimal(tab, key, text, suffix, dmin, dmax, ddefault, scale, apply)
    regSlider(tab, key, text, suffix,
        { min = math.floor(dmin * scale), max = math.floor(dmax * scale), default = math.floor(ddefault * scale) },
        function(v) apply(v / scale) end)
end

-- Expose backend + registry helpers so universal / per-game modules can add
-- tabs that integrate with configs, autoload and unload (active-tracking).
ctx.api = {
    hook        = hook,
    notify      = notify,
    regToggle   = regToggle,
    regSlider   = regSlider,
    regDropdown = regDropdown,
    regColor    = regColor,
    regDecimal  = regDecimal,
}

-- The shared tabs (Movement/Misc/Settings/Config) build ON DEMAND so a
-- game/universal module can add ITS tabs first (keeping them at the top),
-- then call ctx.api.buildShared() to append these below.
local _builtShared = false
local function buildShared()
    if _builtShared then return end
    _builtShared = true

-- ============================================================
--  MOVEMENT
-- ============================================================
local Movement = Window:NewTab("Movement")

Movement:NewSection("Movement")
regToggle(Movement, "Fly", "Fly", false, function(v) if v then hook.fly.start() else hook.fly.stop() end end)
    :AddKeybind(Enum.KeyCode.Z, "Fly")
regSlider(Movement, "FlySpeed", "Fly speed", "", { min = 5, max = 3000, default = hook.fly.getSpeed() or 60 },
    function(v) hook.fly.setSpeed(v) end)

regToggle(Movement, "Walkspeed", "Walkspeed", false, function(v) if v then hook.walkspeed.start() else hook.walkspeed.stop() end end)
    :AddKeybind(Enum.KeyCode.X, "Walkspeed")
regSlider(Movement, "WalkspeedValue", "Walkspeed value", "", { min = 8, max = 1000, default = hook.walkspeed.getValue() or 50 },
    function(v) hook.walkspeed.setValue(v) end)

regToggle(Movement, "JumpPower", "Jump power", false, function(v) if v then hook.jumpPower.start() else hook.jumpPower.stop() end end)
    :AddKeybind(Enum.KeyCode.V, "Jump Power")
regSlider(Movement, "JumpPowerValue", "Jump power value", "", { min = 0, max = 2000, default = hook.jumpPower.getValue() or 50 },
    function(v) hook.jumpPower.setValue(v) end)

regToggle(Movement, "CFrameSpeed", "CFrame speed", false,
    function(v) if v then hook.cframeSpeed.start(hook.cframeSpeed.getMultiplier()) else hook.cframeSpeed.stop() end end)
    :AddKeybind(Enum.KeyCode.B, "CFrame Speed")
regSlider(Movement, "CFrameMult", "CFrame speed multiplier", "x", { min = 1, max = 100, default = hook.cframeSpeed.getMultiplier() or 2 },
    function(v) hook.cframeSpeed.setMultiplier(v) end)

regToggle(Movement, "AllowJump", "Allow jump", false, function(v) if v then hook.forceJump.start() else hook.forceJump.stop() end end)
regToggle(Movement, "Noclip", "Noclip", false, function(v) if v then hook.noclip.start() else hook.noclip.stop() end end)
regToggle(Movement, "ClickTp", "Click teleport", false, function(v) if v then hook.clickTp.start() else hook.clickTp.stop() end end)

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

-- ============================================================
--  DESYNC  (own tab)
-- ============================================================
local Desync = Window:NewTab("Desync")
Desync:NewSection("Desync")
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
regDropdown(Desync, "DesyncMode", "Desync mode", "Void", { "Void", "Sky", "Spin", "Velocity", "Raknet" }, false, function(v)
    desyncMode = v
    if desyncOn then
        hook.desync.stop()
        local starter = MODE_START[v]
        if not starter or not starter() then if desyncEnableT then desyncEnableT:Set(false) end end
    end
end)
desyncEnableT = regToggle(Desync, "DesyncEnabled", "Enable desync", false, function(v)
    desyncOn = v
    if v then
        local starter = MODE_START[desyncMode]
        if not starter or not starter() then if desyncEnableT then desyncEnableT:Set(false) end end
    else
        hook.desync.stop()
    end
end)
desyncEnableT:AddKeybind(Enum.KeyCode.G, "Desync Toggle")
regSlider(Desync, "DesyncMin", "Void min distance", "", { min = 500, max = 100000, default = 5000 },
    function(v) desyncMin = v; hook.desync.setRange(desyncMin, desyncMax) end)
regSlider(Desync, "DesyncMax", "Void max distance", "", { min = 500, max = 100000, default = 20000 },
    function(v) desyncMax = v; hook.desync.setRange(desyncMin, desyncMax) end)
regSlider(Desync, "DesyncSpinSpeed", "Spin speed (deg/frame)", "", { min = 1, max = 360, default = 47 }, function(v) hook.desync.setSpinSpeed(v) end)
regSlider(Desync, "DesyncVelMag", "Velocity magnitude", "", { min = 100, max = 100000, default = 16384 }, function(v) hook.desync.setVelocityMag(v) end)
regSlider(Desync, "DesyncSkyHeight", "Sky height", "", { min = 50, max = 100000, default = 5000 }, function(v) hook.desync.setSkyHeight(v) end)

-- (regColor / regDecimal are defined at top level and exposed via ctx.api)

-- ============================================================
--  PLAYERS
-- ============================================================
local PlayersTab = Window:NewTab("Players")
PlayersTab:NewSection("Players")

local LocalPlr = game:GetService("Players").LocalPlayer
local function playerNameList()
    local names = {}
    for _, p in ipairs(hook.players.list()) do
        if p ~= LocalPlr then names[#names + 1] = p.Name end
    end
    if #names == 0 then names = { "(none)" } end
    return names
end
local plrSel = nil
local plrDrop = PlayersTab:NewDropdown("Player", "(none)", playerNameList(), false, function(v) plrSel = v end)

-- rebuild the option list but keep the current pick selected if they're still
-- here (SetOptions clears the selection, which was un-choosing players on every
-- join/leave)
local Players = game:GetService("Players")
local function refreshPlayerList()
    if library.Unloaded then return end
    local prev  = plrSel
    local names = playerNameList()
    plrDrop:SetOptions(names)
    if prev and prev ~= "(none)" then
        for _, n in ipairs(names) do
            if n == prev then plrDrop:Set(prev); break end
        end
    end
end
PlayersTab:NewButton("Refresh players", refreshPlayerList)

-- auto-refresh the list when players join/leave
Players.PlayerAdded:Connect(function() task.defer(refreshPlayerList) end)
Players.PlayerRemoving:Connect(function() task.defer(refreshPlayerList) end)

local function selectedPlayer()
    if not plrSel or plrSel == "(none)" then notify("Select a player first", 2, "alert"); return nil end
    local p = hook.players.find(plrSel)
    if not p then notify("Player not found: " .. tostring(plrSel), 2, "error") end
    return p
end

PlayersTab:NewButton("Follow", function() local p = selectedPlayer(); if p then hook.players.follow(p) end end)
    :AddButton("Unfollow", function() hook.players.followStop() end)
PlayersTab:NewButton("View", function() local p = selectedPlayer(); if p then hook.players.view(p) end end)
    :AddButton("Goto", function() local p = selectedPlayer(); if p then hook.players["goto"](p) end end)
PlayersTab:NewButton("Fling", function() local p = selectedPlayer(); if p then hook.players.fling(p) end end)
    :AddButton("Sync emote", function()
        local p = selectedPlayer(); if not p then return end
        if hook.stickyEmote and hook.stickyEmote.syncWith(p) then
            notify("Synced emote with " .. p.Name, 2, "success")
        else
            notify("No emote playing on " .. (p and p.Name or "?"), 2, "alert")
        end
    end)

-- ============================================================
--  VISUALS
-- ============================================================
local Visuals = Window:NewTab("Visuals")

Visuals:NewSection("ESP")
regToggle(Visuals, "EspEnabled", "Enabled", false, function(v) if v then hook.esp.start() else hook.esp.stop() end end)
    :AddKeybind(Enum.KeyCode.M, "ESP Toggle")

-- all the on/off ESP elements collapsed into one multi-select dropdown
local ESP_ELEMENTS = {
    { "Boxes",         hook.esp.setBox },
    { "Names",         hook.esp.setNames },
    { "Health bars",   hook.esp.setHealth },
    { "Health number", hook.esp.setHealthNum },
    { "Distance",      hook.esp.setDistance },
    { "Tracers",       hook.esp.setTracer },
    { "Skeleton",      hook.esp.setSkeleton },
    { "Held item",     hook.esp.setHeldItem },
    { "Team colors",   hook.esp.setTeamCheck },
    { "Chams",         hook.esp.setChams },
    { "Self ESP",      hook.esp.setSelf },
}
local ESP_NAMES = {}
for _, e in ipairs(ESP_ELEMENTS) do ESP_NAMES[#ESP_NAMES + 1] = e[1] end
regDropdown(Visuals, "EspElements", "ESP elements", nil, ESP_NAMES, true, function(picked)
    local sel = {}
    if type(picked) == "table" then for _, n in ipairs(picked) do sel[n] = true end end
    for _, e in ipairs(ESP_ELEMENTS) do e[2](sel[e[1]] == true) end
end)

-- style sub-options (not on/off, so kept as their own dropdowns)
regDropdown(Visuals, "EspBoxStyle", "Box style", "Corners", { "Corners", "Full" }, false, function(v) hook.esp.setBoxStyle(v) end)
regDropdown(Visuals, "EspTracerOrigin", "Tracer origin", "Bottom", { "Bottom", "Center", "Top", "Mouse" }, false, function(v) hook.esp.setTracerOrigin(v) end)
regDropdown(Visuals, "EspChamsStyle", "Chams style", "Overlay", { "Overlay", "Occluded", "Outline" }, false, function(v) hook.esp.setChamsStyle(v) end)

Visuals:NewSection("ESP colors")
regColor(Visuals, "EspEnemyColor",   "Enemy",         "Red",    function(c) hook.esp.setEnemyColor(c) end)
regColor(Visuals, "EspTeamColor",    "Team",          "Green",  function(c) hook.esp.setTeamColor(c) end)
regColor(Visuals, "EspNeutralColor", "Neutral",       "Yellow", function(c) hook.esp.setNeutralColor(c) end)
regColor(Visuals, "EspTracerColor",  "Tracer",        "White",  function(c) hook.esp.setTracerColor(c) end)
regColor(Visuals, "EspChamsFill",    "Chams fill",    "Purple", function(c) hook.esp.setChamsFill(c) end)
regColor(Visuals, "EspChamsOutline", "Chams outline", "White",  function(c) hook.esp.setChamsOutline(c) end)

Visuals:NewSection("Tool material")
regToggle(Visuals, "ToolMaterial", "Enabled", false, function(v) if v then hook.toolMaterial.start() else hook.toolMaterial.stop() end end)
regDropdown(Visuals, "ToolMaterialKind", "Material", "Neon", { "Neon", "ForceField" }, false, function(v) hook.toolMaterial.setMaterial(v) end)
regColor(Visuals, "ToolMaterialColor", "Color", "Red", function(c) hook.toolMaterial.setColor(c) end)
regDecimal(Visuals, "ToolMaterialTransp", "Transparency", "%", 0, 1, 0, 100, function(v) hook.toolMaterial.setTransparency(v) end)

Visuals:NewSection("Body material")
regToggle(Visuals, "BodyMaterial", "Enabled", false, function(v) if v then hook.bodyMaterial.start() else hook.bodyMaterial.stop() end end)
regDropdown(Visuals, "BodyMaterialKind", "Material", "Neon", { "Neon", "ForceField" }, false, function(v) hook.bodyMaterial.setMaterial(v) end)
regColor(Visuals, "BodyMaterialColor", "Color", "Red", function(c) hook.bodyMaterial.setColor(c) end)
regDecimal(Visuals, "BodyMaterialTransp", "Transparency", "%", 0, 1, 0, 100, function(v) hook.bodyMaterial.setTransparency(v) end)

Visuals:NewSection("Camera")
regToggle(Visuals, "UnlockZoom", "Unlock zoom", false, function(v) if v then hook.zoom.start() else hook.zoom.stop() end end)

-- Server position visualizer: a ForceField clone of your character parked
-- where the SERVER thinks you are. The position comes from hook.serverPos
-- (a RakNet observer hook on physics packet 0x1B): it tracks your real
-- position normally, and freezes at the last server-received spot whenever
-- a position spoof is blocking replication (desync/invisible/lagswitch).
-- So with a spoof on, the clone sits at your server position; with none,
-- it sits on you.
Visuals:NewSection("Server position")
do
    local RunSvc = game:GetService("RunService")
    local serverVizOn = false
    local clone

    local function destroyClone()
        if clone then clone:Destroy(); clone = nil end
    end
    local function buildClone()
        destroyClone()
        local char = LocalPlr.Character
        if not char then return end
        local ok, c = pcall(function() return char:Clone() end)
        if not ok or not c then return end
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("BasePart") then
                d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CastShadow = false
                d.Material = Enum.Material.ForceField
            elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Humanoid") then
                pcall(function() d:Destroy() end)
            end
        end
        c.Name = "_wh_serverpos"
        c.Parent = workspace
        clone = c
    end

    regToggle(Visuals, "ServerPosViz", "Server position visualizer", false, function(v)
        serverVizOn = v
        if v then
            if hook.serverPos and not hook.serverPos.start() then
                notify("Server pos needs a RakNet-capable executor", 4, "alert")
            end
            buildClone()
        else
            destroyClone()
        end
    end)
    LocalPlr.CharacterAdded:Connect(function()
        if serverVizOn then task.wait(0.4); if serverVizOn then buildClone() end end
    end)
    RunSvc.Heartbeat:Connect(function()
        if library.Unloaded then destroyClone(); return end
        if not serverVizOn then return end
        local char = LocalPlr.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        if not clone or not clone.Parent then buildClone() end
        -- server position from the RakNet tracker; fall back to live HRP
        -- until the first 0x1B packet is observed
        local cf = (hook.serverPos and hook.serverPos.getCFrame()) or hrp.CFrame
        if clone then pcall(function() clone:PivotTo(cf) end) end
    end)
end

-- ============================================================
--  WORLD
-- ============================================================
local Lighting = game:GetService("Lighting")
local LIGHT_DEFAULTS = {
    Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
    ExposureCompensation = Lighting.ExposureCompensation,
    Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
    FogStart = Lighting.FogStart, FogEnd = Lighting.FogEnd, FogColor = Lighting.FogColor,
    GlobalShadows = Lighting.GlobalShadows,
}
local function fxInstance(class, name)
    local ex = Lighting:FindFirstChild(name)
    if ex and ex:IsA(class) then return ex end
    local inst = Instance.new(class); inst.Name = name; inst.Enabled = false; inst.Parent = Lighting
    return inst
end
local CC      = fxInstance("ColorCorrectionEffect", "_wh_cc")
local Bloom   = fxInstance("BloomEffect",           "_wh_bloom")
local Blur    = fxInstance("BlurEffect",            "_wh_blur")
local SunRays = fxInstance("SunRaysEffect",         "_wh_sunrays")

local World = Window:NewTab("World")

World:NewSection("Lighting")
regToggle(World, "Fullbright", "Fullbright", false, function(v) if v then hook.fullbright.start() else hook.fullbright.stop() end end)
regToggle(World, "GlobalShadows", "Global shadows", Lighting.GlobalShadows, function(v) Lighting.GlobalShadows = v end)
regSlider(World, "LightBrightness", "Brightness", "", { min = 0, max = 10, default = math.floor(Lighting.Brightness) }, function(v) Lighting.Brightness = v end)
regSlider(World, "LightClockTime", "Time of day", "", { min = 0, max = 24, default = math.floor(math.clamp(Lighting.ClockTime, 0, 24)) }, function(v) Lighting.ClockTime = v end)
regSlider(World, "LightExposure", "Exposure", "", { min = -5, max = 5, default = math.floor(Lighting.ExposureCompensation) }, function(v) Lighting.ExposureCompensation = v end)
regColor(World, "LightAmbient", "Ambient", "Gray", function(c) Lighting.Ambient = c end)
regColor(World, "LightOutdoor", "Outdoor ambient", "Gray", function(c) Lighting.OutdoorAmbient = c end)
World:NewButton("Restore default lighting", function()
    for k, v in pairs(LIGHT_DEFAULTS) do pcall(function() Lighting[k] = v end) end
    notify("Lighting restored", 2, "information")
end)

World:NewSection("Atmosphere")
regSlider(World, "FogStart", "Fog start", "", { min = 0, max = 5000, default = math.floor(math.min(Lighting.FogStart, 5000)) }, function(v) Lighting.FogStart = v end)
regSlider(World, "FogEnd", "Fog end", "", { min = 0, max = 50000, default = math.floor(math.min(Lighting.FogEnd, 50000)) }, function(v) Lighting.FogEnd = v end)
regColor(World, "FogColor", "Fog color", "Gray", function(c) Lighting.FogColor = c end)
World:NewButton("Clear fog", function() Lighting.FogStart = 0; Lighting.FogEnd = 100000 end)

World:NewSection("Post FX - Color correction")
regToggle(World, "CCEnabled", "Enabled", false, function(v) CC.Enabled = v end)
regDecimal(World, "CCBrightness", "Brightness", "%", -1, 1, 0, 100, function(v) CC.Brightness = v end)
regDecimal(World, "CCContrast", "Contrast", "%", -1, 1, 0, 100, function(v) CC.Contrast = v end)
regDecimal(World, "CCSaturation", "Saturation", "%", -1, 5, 0, 100, function(v) CC.Saturation = v end)
regColor(World, "CCTint", "Tint", "White", function(c) CC.TintColor = c end)

World:NewSection("Post FX - Bloom")
regToggle(World, "BloomEnabled", "Enabled", false, function(v) Bloom.Enabled = v end)
regDecimal(World, "BloomIntensity", "Intensity", "", 0, 5, 0.4, 10, function(v) Bloom.Intensity = v end)
regSlider(World, "BloomThreshold", "Threshold", "", { min = 0, max = 10, default = 2 }, function(v) Bloom.Threshold = v end)
regSlider(World, "BloomSize", "Size", "", { min = 0, max = 64, default = 24 }, function(v) Bloom.Size = v end)

World:NewSection("Post FX - Blur")
regToggle(World, "BlurEnabled", "Enabled", false, function(v) Blur.Enabled = v end)
regSlider(World, "BlurSize", "Size", "", { min = 0, max = 56, default = 12 }, function(v) Blur.Size = v end)

World:NewSection("Post FX - Sun rays")
regToggle(World, "SunRaysEnabled", "Enabled", false, function(v) SunRays.Enabled = v end)
regDecimal(World, "SunRaysIntensity", "Intensity", "%", 0, 1, 0.25, 100, function(v) SunRays.Intensity = v end)
regDecimal(World, "SunRaysSpread", "Spread", "%", 0, 1, 1, 100, function(v) SunRays.Spread = v end)

World:NewSection("Camera")
regToggle(World, "Freecam", "Freecam", false, function(v) if v then hook.freecam.start() else hook.freecam.stop() end end)
    :AddKeybind(Enum.KeyCode.L, "Freecam Toggle")
regSlider(World, "Fov", "FOV", "", { min = 30, max = 120, default = math.floor(hook.fov.get() or 70) }, function(v) hook.fov.set(v) end)

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

Misc:NewSection("Respawn")
-- resets your character but respawns at where you triggered it (decay F.respawn)
Misc:NewButton("Respawn", function() hook.respawn.fire() end)
Misc:NewKeybind("Respawn key", Enum.KeyCode.T, function() hook.respawn.fire() end)

Misc:NewSection("Emotes")
-- ON: emotes keep playing while you move. OFF: they stop when you move (vanilla)
regToggle(Misc, "StickyEmotes", "Emotes stay while moving", false, function(v)
    if hook.stickyEmote then
        if v then hook.stickyEmote.start() else hook.stickyEmote.stop() end
    end
end)

-- ============================================================
--  SETTINGS  (universal GUI prefs, autosaved, NOT part of configs)
-- ============================================================
local settings = readJSON(SETTINGS_PATH) or {}
local function saveSettings() writeJSON(SETTINGS_PATH, settings) end
muteNotifs = settings.muteNotifs == true

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

Settings:NewSlider("Background transparency", "%", false, "/", { min = 0, max = 100, default = math.floor((settings.bgTransparency or 0) * 100) }, function(v)
    library:SetBackgroundTransparency(v / 100); settings.bgTransparency = v / 100; saveSettings()
end)
Settings:NewToggle("Watermark", settings.watermark ~= false, function(v)
    library:SetWatermarkVisible(v); settings.watermark = v; saveSettings()
end)
Settings:NewToggle("Keybind list", settings.keybinds ~= false, function(v)
    library:SetKeybindListVisible(v); settings.keybinds = v; saveSettings()
end)
Settings:NewToggle("Mute notifications", settings.muteNotifs == true, function(v)
    muteNotifs = v; settings.muteNotifs = v; saveSettings()
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
    -- save keybinds (toggle + standalone) by name
    local kb = {}
    for _, b in ipairs(library.keybinds or {}) do
        if b.getKey then kb[b.name] = b.getKey() end
    end
    s.__keybinds = kb
    return s
end
local function applyConfig(data)
    if type(data) ~= "table" then return end
    for k, v in pairs(data) do
        if k ~= "__keybinds" and controls[k] then pcall(controls[k].set, v) end
    end
    -- restore keybinds by name
    if type(data.__keybinds) == "table" then
        for _, b in ipairs(library.keybinds or {}) do
            local k = data.__keybinds[b.name]
            if b.setKey and k ~= nil then pcall(b.setKey, k) end
        end
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
    getAuto      = function() return autoload.games[cfgKey] end
    setAuto      = function(n) autoload.games[cfgKey] = n end
    clearAuto    = function() autoload.games[cfgKey] = false end
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
Config:NewButton("Overwrite selected", function()
    if cfgSel and cfgSel ~= "—" then saveConfig(CFG_DIR, cfgSel); refreshCfg()
    else notify("Select a config to overwrite", 3, "alert") end
end)
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
library:SetBackgroundTransparency(settings.bgTransparency or 0)
library:SetWatermarkVisible(settings.watermark ~= false)
library:SetKeybindListVisible(settings.keybinds ~= false)

task.defer(function()
    local n = getAuto()
    if n and n ~= false then loadConfig(CFG_DIR, n) end
end)

-- on-screen keybind list (left-middle); auto-includes universal tab keybinds
library:CreateKeybindList("witherhook")

notify("witherhook ready", 3, "success")
end   -- buildShared

ctx.api.buildShared = buildShared

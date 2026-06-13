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
    ["7871169780"]      = "Blockerman's Minesweeper",
    ["106131416903029"] = "Cook & Sell!",
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
-- much slower range now (0.1-30 deg/frame) so the spin is actually visible
regDecimal(Desync, "DesyncSpinSpeed", "Spin speed (deg/frame)", "", 0.1, 30, 2, 10, function(v) hook.desync.setSpinSpeed(v) end)
regSlider(Desync, "DesyncVelMag", "Velocity magnitude", "", { min = 100, max = 100000, default = 16384 }, function(v) hook.desync.setVelocityMag(v) end)
regSlider(Desync, "DesyncSkyHeight", "Sky height", "", { min = 50, max = 100000, default = 5000 }, function(v) hook.desync.setSkyHeight(v) end)

-- ---- fake lag (in the Desync tab, below the desync section, no keybind) ----
Desync:NewSection("Fake lag")
local fakeLagT
fakeLagT = regToggle(Desync, "FakeLagEnabled", "Enable fake lag", false, function(v)
    if v then
        if not hook.fakeLag.start() then
            notify("Fake lag unavailable: executor doesn't expose `raknet`", 5, "error")
            if fakeLagT then fakeLagT:Set(false) end
            return
        end
        -- watch the safety bail: if our re-sent packets don't round-trip on this
        -- executor the backend disables itself before it can crash. Reflect that
        -- in the UI instead of leaving a dead toggle on.
        task.spawn(function()
            while flags["FakeLagEnabled"] do
                if hook.fakeLag.didOverflow and hook.fakeLag.didOverflow() then
                    notify("Fake lag isn't supported on this executor (it would crash) - disabled", 6, "error")
                    if fakeLagT then fakeLagT:Set(false) end
                    return
                end
                task.wait(0.5)
            end
        end)
    else
        hook.fakeLag.stop()
    end
end)
-- bindable keybind, but no default key (Unknown => "None")
fakeLagT:AddKeybind(Enum.KeyCode.Unknown, "Fake Lag Toggle")
-- how big the lag is: ms each position update is delayed before it's re-sent
regSlider(Desync, "FakeLagAmount", "Lag amount", " ms", { min = 20, max = 1000, default = hook.fakeLag.getAmount() },
    function(v) hook.fakeLag.setAmount(v) end)
Desync:NewLabel("Delays your movement, not blocks it. Higher = further in the past.", "left")

-- (regColor / regDecimal are defined at top level and exposed via ctx.api)

-- ============================================================
--  PLAYERS
-- ============================================================
local PlayersTab = Window:NewTab("Players")
PlayersTab:NewSection("Players")

local LocalPlr = game:GetService("Players").LocalPlayer
local labelToPlayer = {}   -- "Display name (@username)" -> Player
local function dispName(p)
    local d = p.DisplayName
    return (d and d ~= "" and d) or p.Name
end
local function fmtLabel(p)
    return string.format("%s (@%s)", dispName(p), p.Name)
end
-- options shown as "Display name (@username)", sorted A-Z by display name
local function playerNameList()
    local plrs = {}
    for _, p in ipairs(hook.players.list()) do
        if p ~= LocalPlr then plrs[#plrs + 1] = p end
    end
    table.sort(plrs, function(a, b)
        local da, db = dispName(a):lower(), dispName(b):lower()
        if da == db then return a.Name:lower() < b.Name:lower() end
        return da < db
    end)
    labelToPlayer = {}
    local names = {}
    for _, p in ipairs(plrs) do
        local label = fmtLabel(p)
        names[#names + 1] = label
        labelToPlayer[label] = p
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
    local p = labelToPlayer[plrSel]
    if not p or not p.Parent then
        -- fallback: pull the @username out of the label and look it up
        p = hook.players.find(plrSel:match("@([%w_]+)%)%s*$") or plrSel)
    end
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
    local pingHist = {}        -- { {t=, cf=}, ... } recent real root CFrames (marker lookback)
    local poseHist = {}        -- { {t=, poses={cf_i}}, ... } recent full poses (delayed animation)
    -- on top of raw ping, Roblox processes/interpolates replicated character
    -- movement ~100ms behind. Without this the clone sits right on you at low
    -- ping; with it the offset matches where the server actually has you.
    local REPL_BUFFER = 0.10
    local clone, rootPart, baseCF, hl
    local cloneParts   = {}    -- { { real = <BasePart>, fake = <BasePart> }, ... }
    local structConns  = {}
    local rebuildQueued = false
    local lastBuild     = 0    -- rate-limit rebuilds so a vanished clone can't
    local BUILD_COOLDOWN = 0.5 -- re-clone the whole rig every frame -> freeze

    -- appearance (user-configurable)
    local MATERIALS = {
        Neon       = Enum.Material.Neon,
        ForceField = Enum.Material.ForceField,
        Glass      = Enum.Material.Glass,
    }
    local vizColor    = Color3.fromRGB(0, 200, 255)
    local vizMaterial = "ForceField"
    local vizTransp   = 0.4

    -- park the clone under the Camera, not workspace: it still renders in 3D
    -- but game scripts/anticheats that sweep workspace children for stray
    -- models won't find (and delete) it -> no per-frame rebuild freeze.
    local function vizParent() return workspace.CurrentCamera or workspace end
    -- random instance name so disguised clone parts don't match Head/Torso/etc
    local function randName()
        local s = ""
        for _ = 1, math.random(6, 10) do s = s .. string.char(math.random(97, 122)) end
        return s
    end

    local function clearStructConns()
        for _, c in ipairs(structConns) do pcall(function() c:Disconnect() end) end
        structConns = {}
    end
    local function destroyClone()
        clearStructConns()
        cloneParts = {}
        poseHist   = {}   -- poses are indexed by cloneParts -> stale after a rebuild
        if clone then clone:Destroy(); clone = nil end
        rootPart, baseCF, hl = nil, nil, nil
    end
    local function highlight(model)
        local h = Instance.new("Highlight")
        h.FillColor           = vizColor
        h.OutlineColor        = Color3.fromRGB(255, 255, 255)
        h.FillTransparency    = 0.5
        h.OutlineTransparency = 0
        h.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop  -- visible through walls
        h.Adornee             = model
        h.Parent              = model
        return h
    end
    -- push color / material / transparency onto the live clone
    local function applyAppearance()
        if not clone then return end
        local mat = MATERIALS[vizMaterial] or Enum.Material.ForceField
        if #cloneParts > 0 then
            for _, p in ipairs(cloneParts) do
                local part = p.fake
                if part then
                    part.Material = mat; part.Color = vizColor; part.Transparency = vizTransp
                end
            end
        elseif clone:IsA("BasePart") then
            clone.Material = mat; clone.Color = vizColor; clone.Transparency = vizTransp
        end
        if hl then
            hl.FillColor = vizColor
            -- neon is self-lit and bright; the highlight fill just paints over it,
            -- so turn the overlay off for neon and let the raw material show
            hl.Enabled = (vizMaterial ~= "Neon")
        end
    end
    -- first person ~ camera sitting inside the head
    local camera = workspace.CurrentCamera
    local function isFirstPerson()
        camera = workspace.CurrentCamera or camera
        if not camera then return false end
        -- locked first person (some games force this)
        if LocalPlr.CameraMode == Enum.CameraMode.LockFirstPerson then return true end
        local char = LocalPlr.Character
        local head = char and char:FindFirstChild("Head")
        -- Roblox blanks the head in first person -> a reliable signal
        if head and head.LocalTransparencyModifier >= 1 then return true end
        local ref = head or (char and char:FindFirstChild("HumanoidRootPart"))
        if not ref then return false end
        -- otherwise fall back to camera-near-head distance (head sits ~1.5 over HRP)
        local limit = head and 2.5 or 3.5
        return (camera.CFrame.Position - ref.Position).Magnitude < limit
    end
    -- relative name-path of a descendant under its model root
    local function relPath(inst, root)
        local names = {}
        while inst and inst ~= root do
            table.insert(names, 1, inst.Name)
            inst = inst.Parent
        end
        return names
    end
    local function resolve(root, names)
        local cur = root
        for _, n in ipairs(names) do
            if not cur then return nil end
            cur = cur:FindFirstChild(n)
        end
        return cur
    end

    -- canonical rig parts (only these body parts get mirrored, so game-added
    -- bits welded inside a limb -- e.g. HC's RightLowerArm.CUFF -- are skipped).
    -- HumanoidRootPart is intentionally excluded: it's an invisible collision box
    -- and our material/colour would render it as a block in the torso. The clone
    -- positions every part independently, so it doesn't need one.
    local R15_PARTS = {
        Head = true, UpperTorso = true, LowerTorso = true,
        LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
        RightUpperArm = true, RightLowerArm = true, RightHand = true,
        LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
        RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
    }
    local R6_PARTS = {
        Head = true, Torso = true,
        ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true,
    }
    -- the set of REAL parts to mirror: the rig's body parts (direct children of
    -- the character) + every Accessory / Tool part. Nothing nested inside a body
    -- part, nothing else the game stuffs in the model.
    local function wantedRealParts(char)
        local hum = char:FindFirstChildOfClass("Humanoid")
        local r15 = (hum and hum.RigType == Enum.HumanoidRigType.R15)
            or char:FindFirstChild("UpperTorso") ~= nil
        local bodySet = r15 and R15_PARTS or R6_PARTS
        local wanted = {}   -- [realBasePart] = true
        for _, d in ipairs(char:GetChildren()) do
            if d:IsA("BasePart") then
                if bodySet[d.Name] then wanted[d] = true end
            elseif d:IsA("Accessory") or d:IsA("Tool") then
                for _, p in ipairs(d:GetDescendants()) do
                    if p:IsA("BasePart") then wanted[p] = true end
                end
            end
        end
        return wanted
    end

    -- network round-trip in seconds. Prefer the engine's Data Ping stat (the
    -- number you actually see as your ping); fall back to GetNetworkPing, which
    -- is ~one-way so it gets doubled to approximate the round trip.
    local Stats = game:GetService("Stats")
    local function pingSeconds()
        local ms
        pcall(function() ms = Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
        if type(ms) == "number" and ms > 0 then return ms / 1000 end
        local p = 0
        pcall(function() p = LocalPlr:GetNetworkPing() * 2 end)
        return p
    end

    -- find the two pose snapshots bracketing targetT (+ the blend fraction),
    -- once per frame, so each part's delayed pose is then just an O(1) lookup.
    local function bracketPose(targetT)
        local h = poseHist
        local n = #h
        if n == 0 then return nil, nil, 0 end
        if targetT <= h[1].t then return h[1], h[1], 0 end
        if targetT >= h[n].t then return h[n], h[n], 0 end
        for k = n, 2, -1 do
            if h[k - 1].t <= targetT and targetT <= h[k].t then
                local span = h[k].t - h[k - 1].t
                return h[k - 1], h[k], (span > 0) and (targetT - h[k - 1].t) / span or 0
            end
        end
        return h[n], h[n], 0
    end

    -- where the server thinks we are = our position `lookback` seconds ago.
    -- Sample the buffered history at that time (interpolated for smoothness).
    local function sampleAt(targetT)
        local h = pingHist
        local n = #h
        if n == 0 then return nil end
        if targetT <= h[1].t then return h[1].cf end
        if targetT >= h[n].t then return h[n].cf end
        for i = n, 2, -1 do
            local a, b = h[i - 1], h[i]
            if a.t <= targetT and targetT <= b.t then
                local span = b.t - a.t
                local f = (span > 0) and (targetT - a.t) / span or 0
                return a.cf:Lerp(b.cf, f)
            end
        end
        return h[n].cf
    end

    local queueRebuild
    -- force=true bypasses the cooldown (toggle on / respawn). Without it, a
    -- clone that keeps getting removed (game cleanup, anticheat) can only
    -- trigger a rebuild every BUILD_COOLDOWN s instead of every frame.
    local function buildClone(force)
        if not force and (tick() - lastBuild) < BUILD_COOLDOWN then return end
        lastBuild = tick()
        destroyClone()
        local char = LocalPlr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not char or not root then return end
        -- Flip Archivable on the char AND every descendant so Clone() copies
        -- EVERYTHING. If any accessory part stays Archivable=false it's dropped
        -- from the clone, the clone/real descendant lists diverge, and we fall
        -- back to the buggy name matching -> jumbled accessory positions. Restore
        -- the flags right after the clone.
        local prevArch = char.Archivable
        local flipped  = {}
        char.Archivable = true
        for _, d in ipairs(char:GetDescendants()) do
            if not d.Archivable then
                d.Archivable = true
                flipped[#flipped + 1] = d
            end
        end
        local ok, c = pcall(function() return char:Clone() end)
        char.Archivable = prevArch
        for _, d in ipairs(flipped) do pcall(function() d.Archivable = false end) end
        if ok and c then
            -- Pair clone parts to real parts BY INDEX first: c is an exact deep
            -- copy of char, so both GetDescendants() lists hold the matching
            -- instances in the SAME order. Pairing by position avoids the
            -- name-collision bug where two same-named accessory parts ("Handle")
            -- both resolved to the first real one -> a clone accessory mirroring
            -- the WRONG part (the intermittent jumbled-accessory positions).
            cloneParts = {}
            local wanted = wantedRealParts(char)
            local keep = {}   -- [cloneBasePart] = true
            local cd, rd = c:GetDescendants(), char:GetDescendants()
            if #cd == #rd then
                for i = 1, #cd do
                    if cd[i]:IsA("BasePart") and wanted[rd[i]] then
                        cloneParts[#cloneParts + 1] = { real = rd[i], fake = cd[i] }
                        keep[cd[i]] = true
                    end
                end
            else
                -- structure diverged (rare) -> fall back to name-path matching
                for _, d in ipairs(cd) do
                    if d:IsA("BasePart") then
                        local realPart = resolve(char, relPath(d, c))
                        if realPart and wanted[realPart] then
                            cloneParts[#cloneParts + 1] = { real = realPart, fake = d }
                            keep[d] = true
                        end
                    end
                end
            end
            -- strip the clone so the chosen material shows on EVERY kept part
            for _, d in ipairs(c:GetDescendants()) do
                if d:IsA("BasePart") then
                    d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CastShadow = false
                    -- mesh textures sit on top of the material -> clear them
                    if d:IsA("MeshPart") then pcall(function() d.TextureID = "" end) end
                elseif d:IsA("SpecialMesh") then
                    -- legacy file/head meshes (R6 head, old hats) keep their SHAPE
                    -- but ignore Material, so they show a flat colour instead of
                    -- the neon/forcefield glow. Clear the texture + vertex tint so
                    -- they at least take the chosen colour (not the original).
                    pcall(function() d.TextureId = ""; d.VertexColor = Vector3.new(1, 1, 1) end)
                -- decals, clothing, PBR surfaces and scripts all hide/override the
                -- material; strip them so the chosen look shows on every part (hair too)
                elseif d:IsA("Decal") or d:IsA("Texture") or d:IsA("SurfaceAppearance")
                    or d:IsA("Shirt") or d:IsA("Pants") or d:IsA("ShirtGraphic")
                    or d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Humanoid") then
                    pcall(function() d:Destroy() end)
                end
            end
            for _, d in ipairs(c:GetDescendants()) do
                if d:IsA("BasePart") and not keep[d] then
                    pcall(function() d:Destroy() end)
                end
            end
            -- DISGUISE so the game's anticheat doesn't read it as a player rig:
            -- 1) flatten every part up to the model root (out of Accessory/Tool
            --    wrappers and sub-models)
            for _, d in ipairs(c:GetDescendants()) do
                if d:IsA("BasePart") and d.Parent ~= c then
                    pcall(function() d.Parent = c end)
                end
            end
            -- 2) drop everything that isn't a part or its mesh: the Humanoid,
            --    Motor6D skeleton, attachments, accessory/tool wrappers, values
            for _, d in ipairs(c:GetDescendants()) do
                if not (d:IsA("BasePart") or d:IsA("DataModelMesh")) then
                    pcall(function() d:Destroy() end)
                end
            end
            -- 3) random names -> nothing matches Head / HumanoidRootPart / etc
            c.Name = randName()
            for _, d in ipairs(c:GetChildren()) do
                if d:IsA("BasePart") then d.Name = randName() end
            end
            hl = highlight(c)
            c.Parent = vizParent()
            clone, rootPart = c, root
            baseCF = root.CFrame   -- seeded; recomputed each frame from ping history
            applyAppearance()
            -- rebuild ONLY when a tool/accessory is actually added or removed.
            -- (connecting to every child change re-clones the whole rig many
            -- times a second in games that churn character children -> freeze.)
            local function onChild(child)
                if child and (child:IsA("Tool") or child:IsA("Accessory")) then
                    queueRebuild()
                end
            end
            structConns = {
                char.ChildAdded:Connect(onChild),
                char.ChildRemoved:Connect(onChild),
            }
            return
        end
        -- fallback when cloning is blocked: a single bright marker part
        local m = Instance.new("Part")
        m.Name = "_wh_serverpos"; m.Size = Vector3.new(2, 5, 1)
        m.Anchored = true; m.CanCollide = false; m.CanQuery = false; m.CastShadow = false
        hl = highlight(m)
        m.Parent = vizParent()
        clone, rootPart = m, root
        baseCF = root.CFrame   -- seeded; recomputed each frame from ping history
        applyAppearance()
    end

    queueRebuild = function()
        if not serverVizOn or rebuildQueued then return end
        rebuildQueued = true
        task.delay(0.35, function()
            rebuildQueued = false
            if serverVizOn then buildClone() end
        end)
    end

    regToggle(Visuals, "ServerPosViz", "Server position visualizer", false, function(v)
        serverVizOn = v
        if v then
            buildClone(true)   -- ping-based now; no raknet needed
        else
            destroyClone()
        end
    end)
    regColor(Visuals, "ServerPosColor", "Color", vizColor, function(c)
        vizColor = c; applyAppearance()
    end)
    regDropdown(Visuals, "ServerPosMaterial", "Material", vizMaterial,
        { "Neon", "ForceField", "Glass" }, false, function(v)
            vizMaterial = v; applyAppearance()
        end)
    regSlider(Visuals, "ServerPosTransp", "Transparency", "%", { min = 0, max = 100, default = math.floor(vizTransp * 100) },
        function(v) vizTransp = v / 100; applyAppearance() end)

    LocalPlr.CharacterAdded:Connect(function()
        if serverVizOn then task.wait(0.4); if serverVizOn then buildClone(true) end end
    end)
    RunSvc.RenderStepped:Connect(function(dt)
        if library.Unloaded then destroyClone(); return end
        if not serverVizOn then return end
        if not clone then buildClone(); return end
        -- hide it entirely while in first person
        if isFirstPerson() then
            if clone.Parent then clone.Parent = nil end
            return
        end
        if not clone.Parent then
            -- we hid it (reattach) or the game removed it (rebuild)
            pcall(function() clone.Parent = vizParent() end)
            if not clone.Parent then buildClone(); return end
        end
        if not rootPart or not rootPart.Parent then buildClone(); return end
        -- Server position from latency: the server sees us where we were one
        -- network-ping ago, plus the fake-lag delay when it's active. Buffer the
        -- real position each frame and look back by that total time.
        local now = tick()
        local realRoot = rootPart.CFrame
        -- root history (used by the fallback marker)
        pingHist[#pingHist + 1] = { t = now, cf = realRoot }
        while pingHist[1] and now - pingHist[1].t > 3 do table.remove(pingHist, 1) end
        -- pose history: snapshot every mirrored part's WORLD CFrame so the whole
        -- animation can be replayed delayed (not just the position).
        if #cloneParts > 0 then
            local poses = {}
            for i = 1, #cloneParts do
                local rp = cloneParts[i].real
                poses[i] = (rp and rp.Parent) and rp.CFrame or false
            end
            poseHist[#poseHist + 1] = { t = now, poses = poses }
            while poseHist[1] and now - poseHist[1].t > 3 do table.remove(poseHist, 1) end
        end

        -- total delay = network ping + replication buffer + fake-lag (when on)
        local lookback = pingSeconds() + REPL_BUFFER
        if hook.fakeLag and hook.fakeLag.isActive and hook.fakeLag.isActive() then
            lookback = lookback + ((hook.fakeLag.getAmount and hook.fakeLag.getAmount() or 0) / 1000)
        end
        -- a desync overrides the position with the spoofed/frozen server spot
        local desyncCF = hook.desync and hook.desync.getServerCFrame and hook.desync.getServerCFrame()

        if #cloneParts > 0 then
            pcall(function()
                if desyncCF then
                    -- desync: current pose parked at the spoofed/frozen position
                    local rootInv = realRoot:Inverse()
                    for _, p in ipairs(cloneParts) do
                        local rp = p.real
                        if rp and rp.Parent then p.fake.CFrame = desyncCF * (rootInv * rp.CFrame) end
                    end
                else
                    -- replay the FULL delayed state: each part's world pose from
                    -- `lookback` ago, so position AND animation lag together
                    local a, b, f = bracketPose(now - lookback)
                    for i, p in ipairs(cloneParts) do
                        local ca = a and a.poses[i]
                        local cb = b and b.poses[i]
                        if ca and cb then p.fake.CFrame = ca:Lerp(cb, f)
                        elseif cb then p.fake.CFrame = cb
                        elseif ca then p.fake.CFrame = ca end
                    end
                end
            end)
        else
            local cf = desyncCF or sampleAt(now - lookback) or realRoot
            pcall(function() clone:PivotTo(cf) end)   -- fallback marker
        end
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
-- effects are re-acquirable: if the game wipes Lighting on respawn, recreate them
local CC, Bloom, Blur, SunRays
local function ensureFx()
    CC      = fxInstance("ColorCorrectionEffect", "_wh_cc")
    Bloom   = fxInstance("BloomEffect",           "_wh_bloom")
    Blur    = fxInstance("BlurEffect",            "_wh_blur")
    SunRays = fxInstance("SunRaysEffect",         "_wh_sunrays")
end
ensureFx()

-- Persistence: every World control the user CHANGES registers a closure that
-- re-applies its current value. On respawn (HC resets the lighting) we recreate
-- the effects + replay those closures so the changes stick. Untouched controls
-- never register, so the game's own day/night etc. is left alone.
-- W: for sliders/toggles (their callback only fires on a real change).
-- Wc: for colorpickers (they ALSO fire once on creation -> skip that first call
--     so the default colour doesn't get pinned).
local worldReapply = {}
local function W(applyFn)
    return function(v)
        worldReapply[applyFn] = function() pcall(applyFn, v) end
        pcall(applyFn, v)
    end
end
local function Wc(applyFn)
    local first = true
    return function(c)
        if first then first = false; pcall(applyFn, c); return end
        worldReapply[applyFn] = function() pcall(applyFn, c) end
        pcall(applyFn, c)
    end
end
local function reapplyWorld()
    ensureFx()
    for _, f in pairs(worldReapply) do f() end
end

local World = Window:NewTab("World")

World:NewSection("Lighting")
regToggle(World, "Fullbright", "Fullbright", false, function(v) if v then hook.fullbright.start() else hook.fullbright.stop() end end)
regToggle(World, "GlobalShadows", "Global shadows", Lighting.GlobalShadows, W(function(v) Lighting.GlobalShadows = v end))
regSlider(World, "LightBrightness", "Brightness", "", { min = 0, max = 10, default = math.floor(Lighting.Brightness) }, W(function(v) Lighting.Brightness = v end))
regSlider(World, "LightClockTime", "Time of day", "", { min = 0, max = 24, default = math.floor(math.clamp(Lighting.ClockTime, 0, 24)) }, W(function(v) Lighting.ClockTime = v end))
regSlider(World, "LightExposure", "Exposure", "", { min = -5, max = 5, default = math.floor(Lighting.ExposureCompensation) }, W(function(v) Lighting.ExposureCompensation = v end))
regColor(World, "LightAmbient", "Ambient", "Gray", Wc(function(c) Lighting.Ambient = c end))
regColor(World, "LightOutdoor", "Outdoor ambient", "Gray", Wc(function(c) Lighting.OutdoorAmbient = c end))
World:NewButton("Restore default lighting", function()
    worldReapply = {}   -- stop re-asserting any overrides
    for k, v in pairs(LIGHT_DEFAULTS) do pcall(function() Lighting[k] = v end) end
    notify("Lighting restored", 2, "information")
end)

World:NewSection("Atmosphere")
regSlider(World, "FogStart", "Fog start", "", { min = 0, max = 5000, default = math.floor(math.min(Lighting.FogStart, 5000)) }, W(function(v) Lighting.FogStart = v end))
regSlider(World, "FogEnd", "Fog end", "", { min = 0, max = 50000, default = math.floor(math.min(Lighting.FogEnd, 50000)) }, W(function(v) Lighting.FogEnd = v end))
regColor(World, "FogColor", "Fog color", "Gray", Wc(function(c) Lighting.FogColor = c end))
World:NewButton("Clear fog", function() Lighting.FogStart = 0; Lighting.FogEnd = 100000 end)

World:NewSection("Post FX - Color correction")
regToggle(World, "CCEnabled", "Enabled", false, W(function(v) CC.Enabled = v end))
regDecimal(World, "CCBrightness", "Brightness", "%", -1, 1, 0, 100, W(function(v) CC.Brightness = v end))
regDecimal(World, "CCContrast", "Contrast", "%", -1, 1, 0, 100, W(function(v) CC.Contrast = v end))
regDecimal(World, "CCSaturation", "Saturation", "%", -1, 5, 0, 100, W(function(v) CC.Saturation = v end))
regColor(World, "CCTint", "Tint", "White", Wc(function(c) CC.TintColor = c end))

World:NewSection("Post FX - Bloom")
regToggle(World, "BloomEnabled", "Enabled", false, W(function(v) Bloom.Enabled = v end))
regDecimal(World, "BloomIntensity", "Intensity", "", 0, 5, 0.4, 10, W(function(v) Bloom.Intensity = v end))
regSlider(World, "BloomThreshold", "Threshold", "", { min = 0, max = 10, default = 2 }, W(function(v) Bloom.Threshold = v end))
regSlider(World, "BloomSize", "Size", "", { min = 0, max = 64, default = 24 }, W(function(v) Bloom.Size = v end))

World:NewSection("Post FX - Blur")
regToggle(World, "BlurEnabled", "Enabled", false, W(function(v) Blur.Enabled = v end))
regSlider(World, "BlurSize", "Size", "", { min = 0, max = 56, default = 12 }, W(function(v) Blur.Size = v end))

World:NewSection("Post FX - Sun rays")
regToggle(World, "SunRaysEnabled", "Enabled", false, W(function(v) SunRays.Enabled = v end))
regDecimal(World, "SunRaysIntensity", "Intensity", "%", 0, 1, 0.25, 100, W(function(v) SunRays.Intensity = v end))
regDecimal(World, "SunRaysSpread", "Spread", "%", 0, 1, 1, 100, W(function(v) SunRays.Spread = v end))

World:NewSection("Camera")
regToggle(World, "Freecam", "Freecam", false, function(v) if v then hook.freecam.start() else hook.freecam.stop() end end)
    :AddKeybind(Enum.KeyCode.L, "Freecam Toggle")
regSlider(World, "Fov", "FOV", "", { min = 30, max = 120, default = math.floor(hook.fov.get() or 70) }, W(function(v) hook.fov.set(v) end))

-- re-assert World overrides on respawn, when our effects get wiped, and a slow
-- backstop loop -- but only while something is actually overridden
LocalPlr.CharacterAdded:Connect(function()
    if next(worldReapply) then task.wait(0.4); reapplyWorld() end
end)
Lighting.ChildRemoved:Connect(function(c)
    if c and c.Name and c.Name:match("^_wh_") and next(worldReapply) then task.defer(reapplyWorld) end
end)
task.spawn(function()
    while not library.Unloaded do
        task.wait(3)
        if next(worldReapply) then reapplyWorld() end
    end
end)

-- ============================================================
--  MISC
-- ============================================================
local Misc = Window:NewTab("Misc")
ctx.api.miscTab = Misc   -- exposed so per-game modules can add to the shared Misc tab
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
--  ANIMATION CHANGER  (own tab, below Misc)
-- ============================================================
-- Presets overwrite the Animate script's walk/run (+ idle) IDs. The default
-- Animate watches these and reloads, so it applies live. Presets are mutually
-- exclusive; re-applied on respawn; originals restored on off.
local AnimTab = Window:NewTab("Animation Changer")
AnimTab:NewSection("Walk / run")
do
    local PRESETS = {
        dog = {
            walk = "rbxassetid://103866486218951",
            run  = "rbxassetid://103866486218951",
            idle = "rbxassetid://80401449796551",
            fidgets = true,
        },
        slow = {
            walk = "rbxassetid://82920886438316",
            run  = "rbxassetid://82920886438316",
        },
        sad = {
            walk = "rbxassetid://122248011313710",
            run  = "rbxassetid://122248011313710",
            idle = "rbxassetid://106148437094704",
        },
    }
    local active  = nil        -- "dog" | "slow" | "sad" | "custom" | nil
    local cwSaved = {}         -- [Animation] = original AnimationId
    local cwConn, cwFidgetThread, dogT, slowT, sadT, customT

    local function applyPreset(char, preset)
        local animate = char and char:FindFirstChild("Animate")
        if not animate or not preset then return end
        for _, name in ipairs({ "walk", "run", "idle" }) do
            local id = preset[name]
            local f  = id and animate:FindFirstChild(name)
            if f then
                for _, a in ipairs(f:GetChildren()) do
                    if a:IsA("Animation") then
                        if cwSaved[a] == nil then cwSaved[a] = a.AnimationId end
                        pcall(function() a.AnimationId = id end)
                    end
                end
            end
        end
    end
    local function cwRestore()
        for a, id in pairs(cwSaved) do
            pcall(function() if a.Parent then a.AnimationId = id end end)
        end
        cwSaved = {}
    end

    -- random idle "fidget" animations (dog preset only)
    local FIDGETS = {
        "rbxassetid://92972712226070", "rbxassetid://122475317803320",
        "rbxassetid://121179940665683", "rbxassetid://92913202939886",
    }
    local function playFidget(char, hum)
        local animator = hum:FindFirstChildOfClass("Animator")
        if not animator then return end
        local anim = Instance.new("Animation")
        anim.AnimationId = FIDGETS[math.random(1, #FIDGETS)]
        local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
        if not ok or not track then return end
        pcall(function() track.Priority = Enum.AnimationPriority.Action end)
        track.Looped = false
        pcall(function() track:Play() end)
        local t0 = os.clock()
        while active == "dog" and track.IsPlaying do
            if hum.MoveDirection.Magnitude > 0.1 then break end
            if os.clock() - t0 > 12 then break end
            task.wait(0.1)
        end
        pcall(function() track:Stop(0.2) end)
    end
    local function idleHum()
        local char = LocalPlr.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 and hum.MoveDirection.Magnitude < 0.1 then return hum, char end
        return nil
    end
    local function cwFidgetLoop()
        while active == "dog" do
            local target = math.random(1, 60)   -- 1-60s of continuous idle
            local acc = 0
            while active == "dog" and acc < target do
                task.wait(0.5)
                if idleHum() then acc = acc + 0.5 else acc = 0 end
            end
            if active ~= "dog" then break end
            local hum, char = idleHum()
            if hum then playFidget(char, hum) end
            local t0 = os.clock()             -- 60s timeout, ends early when not idle
            while active == "dog" and (os.clock() - t0) < 60 do
                task.wait(0.5)
                if not idleHum() then break end
            end
        end
    end

    local function setPreset(name)
        if cwConn then cwConn:Disconnect(); cwConn = nil end
        if cwFidgetThread then pcall(task.cancel, cwFidgetThread); cwFidgetThread = nil end
        cwRestore()
        active = name
        local preset = name and PRESETS[name]
        if not preset then return end
        applyPreset(LocalPlr.Character, preset)
        cwConn = LocalPlr.CharacterAdded:Connect(function(c)
            if active == name then task.wait(0.4); if active == name then applyPreset(c, preset) end end
        end)
        if preset.fidgets then cwFidgetThread = task.spawn(cwFidgetLoop) end
    end

    -- turn off every other preset toggle (mutual exclusivity)
    local function offExcept(keep)
        for _, t in ipairs({ dogT, slowT, sadT, customT }) do
            if t and t ~= keep then t:Set(false) end
        end
    end
    dogT = regToggle(AnimTab, "CustomWalk", "Dog walking animations", false, function(v)
        if v then offExcept(dogT); setPreset("dog")
        elseif active == "dog" then setPreset(nil) end
    end)
    slowT = regToggle(AnimTab, "SlowWalk", "Slow walk anim", false, function(v)
        if v then offExcept(slowT); setPreset("slow")
        elseif active == "slow" then setPreset(nil) end
    end)
    sadT = regToggle(AnimTab, "SadWalk", "Sad", false, function(v)
        if v then offExcept(sadT); setPreset("sad")
        elseif active == "sad" then setPreset(nil) end
    end)

    -- bare number -> rbxassetid://, full string left as-is, blank -> nil
    local function normId(s)
        s = tostring(s or ""):gsub("%s", "")
        if s == "" then return nil end
        if s:match("^%d+$") then return "rbxassetid://" .. s end
        return s
    end

    -- ---- custom animations: set your own walk/run + idle ----
    AnimTab:NewSection("Custom animations")
    PRESETS.custom = {}
    local function reapplyCustom()
        if active == "custom" then setPreset("custom") end
    end
    AnimTab:NewTextbox("Walk / run ID", "", "id or number", "all", "medium", true, false, function(v)
        local id = normId(v)
        PRESETS.custom.walk = id
        PRESETS.custom.run  = id
        reapplyCustom()
    end)
    AnimTab:NewTextbox("Idle ID", "", "id or number", "all", "medium", true, false, function(v)
        PRESETS.custom.idle = normId(v)
        reapplyCustom()
    end)
    customT = regToggle(AnimTab, "CustomAnimApply", "Apply custom", false, function(v)
        if v then offExcept(customT); setPreset("custom")
        elseif active == "custom" then setPreset(nil) end
    end)

    -- ---- play any animation / emote on yourself ----
    AnimTab:NewSection("Play animation / emote")
    local playId, playedTrack = "", nil
    local function stopPlayed()
        if playedTrack then pcall(function() playedTrack:Stop(0.1) end); playedTrack = nil end
    end
    AnimTab:NewTextbox("Animation / emote ID", "", "id or number", "all", "medium", true, false, function(v)
        playId = v
    end)
    AnimTab:NewButton("Play", function()
        local id = normId(playId)
        if not id then notify("Enter an animation ID first", 2, "alert"); return end
        local char     = LocalPlr.Character
        local hum      = char and char:FindFirstChildOfClass("Humanoid")
        local animator = hum and hum:FindFirstChildOfClass("Animator")
        if not animator then notify("No character loaded", 2, "alert"); return end
        stopPlayed()
        local anim = Instance.new("Animation"); anim.AnimationId = id
        local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
        if ok and track then
            pcall(function() track.Priority = Enum.AnimationPriority.Action4 end)
            pcall(function() track:Play() end)
            playedTrack = track
        else
            notify("Couldn't load that animation", 3, "error")
        end
    end):AddButton("Stop", stopPlayed)
end

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

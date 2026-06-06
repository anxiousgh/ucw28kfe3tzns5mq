-- ============================================================
--  witherhook // Games/138995385694035.lua   (Hood Customs)
--  Loads the shared shell (main.lua) then adds a single "Main"
--  tab with all Hood Customs features. Wired to
--  hook.games.hoodCustoms (+ desync for knife voidspam).
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end

local Window = ctx.window
local hook   = api.hook
local notify = api.notify
local regToggle, regSlider, regDropdown = api.regToggle, api.regSlider, api.regDropdown
local regColor, regDecimal = api.regColor, api.regDecimal

local hc = hook.games and hook.games.hoodCustoms
if not hc then
    notify("Hood Customs module unavailable", 5, "error")
    return
end

local LocalPlayer = game:GetService("Players").LocalPlayer

local Main = Window:NewTab("Main")

-- ---------- Auto stomp ----------
Main:NewSection("Auto stomp")
regToggle(Main, "HC_AutoStomp", "Auto stomp", false, function(v)
    if v then hc.autoStomp.start() else hc.autoStomp.stop() end
end)
regSlider(Main, "HC_StompRadius", "Stomp radius", "", { min = 1, max = 50, default = math.floor(hc.autoStomp.getRadius() or 5) }, function(v) hc.autoStomp.setRadius(v) end)
regSlider(Main, "HC_StompInterval", "Min interval", " ms", { min = 0, max = 2000, default = math.floor((hc.autoStomp.getInterval() or 0) * 1000) }, function(v) hc.autoStomp.setInterval(v / 1000) end)
regToggle(Main, "HC_StompRage", "Stomp ragebot targets", false, function(v) hc.autoStomp.setRageTargets(v) end)

-- ---------- Auto reload ----------
Main:NewSection("Auto reload")
regToggle(Main, "HC_AutoReload", "Auto reload", false, function(v)
    if v then hc.autoReload.start() else hc.autoReload.stop() end
end)
regSlider(Main, "HC_ReloadThreshold", "Reload at", "%", { min = 1, max = 100, default = math.floor(hc.autoReload.getThreshold() or 35) }, function(v) hc.autoReload.setThreshold(v) end)
regDecimal(Main, "HC_ReloadCooldown", "Cooldown", "s", 0, 5, hc.autoReload.getCooldown() or 1, 10, function(v) hc.autoReload.setCooldown(v) end)

-- ---------- Knife reach ----------
Main:NewSection("Knife reach")
regToggle(Main, "HC_KnifeReach", "Enable knife reach", false, function(v)
    if v then hc.knifeReach.start() else hc.knifeReach.stop() end
end)
regSlider(Main, "HC_KnifeReachSize", "Hitbox size", "", { min = 1, max = math.floor(hc.knifeReach.maxSize or 20), default = math.floor(hc.knifeReach.getSize() or 5) }, function(v) hc.knifeReach.setSize(v) end)
regToggle(Main, "HC_KnifeReachVis", "Visualize hitbox", false, function(v) hc.knifeReach.setVisualize(v) end)

-- ---------- AFK badge (mutually exclusive) ----------
Main:NewSection("AFK badge")
local antiT, forceT
antiT = regToggle(Main, "HC_AntiAfk", "Anti-AFK tag (hide)", false, function(v)
    if v then if forceT then forceT:Set(false) end; hc.antiAfkTag.start() else hc.antiAfkTag.stop() end
end)
forceT = regToggle(Main, "HC_ForceAfk", "Force-AFK tag (always show)", false, function(v)
    if v then if antiT then antiT:Set(false) end; hc.forceAfkTag.start() else hc.forceAfkTag.stop() end
end)

-- ---------- Godmode ----------
Main:NewSection("Godmode")
regToggle(Main, "HC_Godmode", "Godmode", false, function(v)
    if v then hc.godmode.start() else hc.godmode.stop() end
end)

-- ---------- Force Hit ----------
Main:NewSection("Force Hit")
local fhT = regToggle(Main, "HC_ForceHit", "Enable", false, function(v)
    if v then hc.forceHit.start() else hc.forceHit.stop() end
end)

local function playerNames()
    local names = {}
    for _, p in ipairs(hook.players.list()) do
        if p ~= LocalPlayer then names[#names + 1] = p.Name end
    end
    if #names == 0 then names = { "(none)" } end
    return names
end
local fhTargetDrop = Main:NewDropdown("Target", "(none)", playerNames(), false, function(name)
    if name == "(none)" then return end
    local p = hook.players.find(name)
    if p then hc.forceHit.setTarget(p); notify("Force-hit target: " .. name, 2, "information") end
end)
Main:NewButton("Refresh targets", function() fhTargetDrop:SetOptions(playerNames()) end)

regDropdown(Main, "HC_ForceHitPart", "Hit part", "Head", { "Head", "UpperTorso", "HumanoidRootPart" }, false, function(v) hc.forceHit.setHitPart(v) end)
regDecimal(Main, "HC_ForceHitCooldown", "Cooldown", "s", 0, 2, 0.2, 100, function(v) hc.forceHit.setCooldown(v) end)

regToggle(Main, "HC_FHTracer", "Show fake bullet tracer", true, function(v) hc.forceHit.setTracerEnabled(v) end)
regColor(Main, "HC_FHTracerColor", "Tracer color", Color3.fromRGB(0, 255, 80), function(c) hc.forceHit.setTracerColor(c) end)
regDecimal(Main, "HC_FHTracerLife", "Tracer lifetime", "s", 0.05, 1, 0.2, 100, function(v) hc.forceHit.setTracerLifetime(v) end)
regDropdown(Main, "HC_FHTracerStyle", "Tracer style", "Standard", { "Standard", "Laser", "Lightning", "Plasma", "Thin" }, false, function(v) hc.forceHit.setTracerStyle(v) end)
regToggle(Main, "HC_FHTrail", "Trail particles along beam", false, function(v) hc.forceHit.setTrailEnabled(v) end)

local HC_SOUNDS = {
    { "deep bell",                 104441273771318 },
    { "crit",                      135698842254153 },
    { "m4a1",                      18521643711 },
    { "pack a punch",              7408420244 },
    { "random sound",              133749572213659 },
    { "weird idk what its called", 129157734600366 },
    { "csgo headshot",             133002449941130 },
    { "rust headshot",             121566025787365 },
}
local soundLabels, idByLabel = {}, {}
for _, s in ipairs(HC_SOUNDS) do soundLabels[#soundLabels + 1] = s[1]; idByLabel[s[1]] = s[2] end
regToggle(Main, "HC_FHHitSound", "Play hit sound", true, function(v) hc.forceHit.setHitSoundEnabled(v) end)
regDropdown(Main, "HC_FHSoundId", "Hit sound", "crit", soundLabels, false, function(label)
    local id = idByLabel[label]; if id then hc.forceHit.setHitSoundId(id) end
end)
regDecimal(Main, "HC_FHSoundVol", "Hit sound volume", "", 0, 3, 1, 10, function(v) hc.forceHit.setHitSoundVolume(v) end)

-- ---------- Knife Bot ----------
Main:NewSection("Knife Bot")
regToggle(Main, "HC_Voidspam", "Use knife voidspam", false, function(v)
    if v then hook.desync.startVoidspam() else hook.desync.stop() end
end)
regSlider(Main, "HC_VoidStart", "Start at % of anim", "%", { min = 0, max = 100, default = 40 }, function(v) hook.desync.setShotDelayMs(v) end)
regSlider(Main, "HC_VoidEnd", "End at % of anim", "%", { min = 0, max = 100, default = 90 }, function(v) hook.desync.setShotSyncMs(v) end)
regToggle(Main, "HC_VoidVis", "Show sync window visualizer", false, function(v) hook.desync.setSyncVisualEnabled(v) end)

regToggle(Main, "HC_KnifeAttach", "Attach to ragebot target", false, function(v)
    if v then
        if fhT then fhT:Set(false) end   -- knife only: drop the ranged force-hit
        hc.knifeBot.attach.start()
    else
        hc.knifeBot.attach.stop()
    end
end)
regSlider(Main, "HC_KnifeDistance", "Attach distance", "", { min = 0, max = 50, default = 3 }, function(v) hc.knifeBot.attach.setDistance(v) end)
regDecimal(Main, "HC_KnifeClick", "Click interval", "s", 0.05, 5, 0.6, 100, function(v) hc.knifeBot.attach.setClickInterval(v) end)
regToggle(Main, "HC_KnifeOrbit", "Orbit target", false, function(v) hc.knifeBot.attach.setOrbit(v) end)
regSlider(Main, "HC_KnifeOrbitSpeed", "Orbit speed", " deg/s", { min = 0, max = 720, default = 180 }, function(v) hc.knifeBot.attach.setOrbitSpeed(v) end)
regToggle(Main, "HC_KnifeAutoEquip", "Auto-equip [Knife]", false, function(v)
    if v then hc.knifeBot.autoEquip.start() else hc.knifeBot.autoEquip.stop() end
end)

-- shared tabs (Movement/Desync/Visuals/World/Misc/Settings/Config) below
api.buildShared()

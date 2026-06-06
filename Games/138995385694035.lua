-- ============================================================
--  witherhook // Games/138995385694035.lua   (Hood Customs)
--  Tabs: Target, Combat, Checks, Utils. Wired to
--  hook.games.hoodCustoms + hook.ragebot (target list) + hook.utils.
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end

local Window  = ctx.window
local library = ctx.library
local hook    = api.hook
local notify  = api.notify
local regToggle, regSlider, regDropdown = api.regToggle, api.regSlider, api.regDropdown
local regColor, regDecimal = api.regColor, api.regDecimal

local hc = hook.games and hook.games.hoodCustoms
local rb = hook.ragebot
if not hc or not rb then
    notify("Hood Customs module unavailable", 5, "error")
    return
end

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local LocalPlayer  = Players.LocalPlayer

-- decay's knock check: workspace.Players.Characters[name].BodyEffects["K.O"]
-- (or grabbed). Skip these when knock-check is on.
local isKnocked = hc.isKnocked or function() return false end
local knockCheckOn = false

-- ---------- shared targeting helpers ----------
local function myRoot() return hook.utils.getRoot() end
-- line-of-sight origin = our HEAD (not the camera; in 3rd person the camera
-- can see over/around walls the character is actually behind, which made
-- "visible" shots go through walls).
local function headPos()
    local c = LocalPlayer.Character
    local h = c and c:FindFirstChild("Head")
    if h then return h.Position end
    local r = myRoot()
    if r then return r.Position end
    return workspace.CurrentCamera.CFrame.Position
end

local function aliveParts(p)
    local ch = p.Character; if not ch then return nil, nil end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    if hrp and hum and hum.Health > 0 then return hrp, ch end
    return nil, nil
end

local function isVisible(fromPos, hrp, ch)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    local res = workspace:Raycast(fromPos, hrp.Position - fromPos, params)
    if not res then return true end
    return res.Instance:IsDescendantOf(ch)
end

-- nearest living enemy by character distance; optional visibility + exclude set
local function nearestEnemy(range, needVisible, exclude)
    local root = myRoot(); if not root then return nil end
    local origin = root.Position
    local best, bestD
    for _, p in ipairs(hook.players.list()) do
        if p ~= LocalPlayer and not (exclude and exclude[p]) then
            local hrp, ch = aliveParts(p)
            if hrp then
                local d = (hrp.Position - origin).Magnitude
                if d <= (range or math.huge) and (not best or d < bestD) then
                    if (not needVisible) or isVisible(headPos(), hrp, ch) then
                        best, bestD = p, d
                    end
                end
            end
        end
    end
    return best
end

local function targetPart(p)
    local ch = p and p.Character; if not ch then return nil end
    return ch:FindFirstChild("HumanoidRootPart") or ch:FindFirstChild("Head")
end

local function playerNames()
    local names = {}
    for _, p in ipairs(hook.players.list()) do
        if p ~= LocalPlayer then names[#names + 1] = p.Name end
    end
    if #names == 0 then names = { "(none)" } end
    return names
end

-- ============================================================
--  TARGET
-- ============================================================
local Target = Window:NewTab("Target")
Target:NewSection("Targeting")

local targetMode = "Closest"
regDropdown(Target, "HC_TargetMode", "Priority", "Closest", { "Closest", "Mouse" }, false, function(v)
    targetMode = v
    pcall(rb.setPriority, v)
end)

local function addClosestTarget()
    local excl = {}
    for _, t in ipairs(rb.getTargetList()) do excl[t] = true end
    local p
    if targetMode == "Mouse" then
        p = hook.utils.findClosestPlayer({ fov = 9999, exclude = excl })
    else
        p = nearestEnemy(nil, false, excl)
    end
    if p then rb.addTarget(p); notify("Locked " .. p.Name, 2, "success")
    else notify("No target found", 2, "alert") end
end

Target:NewKeybind("Add target", Enum.KeyCode.H, addClosestTarget)
Target:NewKeybind("Clear targets", Enum.KeyCode.J, function() rb.unlock(); notify("Targets cleared", 2, "information") end)
Target:NewButton("Add closest", addClosestTarget)
    :AddButton("Clear all", function() rb.unlock(); notify("Targets cleared", 2, "information") end)

-- multi-select: selection becomes the target list
local tDrop = Target:NewDropdown("Players", nil, playerNames(), true, function(picked)
    rb.unlock()
    if type(picked) == "table" then
        for _, name in ipairs(picked) do
            if name ~= "(none)" then
                local p = hook.players.find(name)
                if p then rb.addTarget(p) end
            end
        end
    end
end)
Target:NewButton("Refresh players", function() tDrop:SetOptions(playerNames()) end)

local tLabel = Target:NewLabel("Targets: (none)", "left")
task.spawn(function()
    local last = ""
    while not library.Unloaded do
        local list = rb.getTargetList()
        local names = {}
        for _, p in ipairs(list) do names[#names + 1] = p.Name end
        local sig = table.concat(names, ",")
        if sig ~= last then
            last = sig
            tLabel:Text(#names > 0 and ("Targets (" .. #names .. "): " .. table.concat(names, ", ")) or "Targets: (none)")
        end
        task.wait(0.4)
    end
end)

-- Kill aura: auto-add every visible enemy within range to the target list
Target:NewSection("Kill aura")
local killAuraOn, killAuraRange = false, 200
regToggle(Target, "HC_KillAura", "Kill aura", false, function(v) killAuraOn = v end)
regSlider(Target, "HC_KillAuraRange", "Range", "", { min = 10, max = 1000, default = 200 }, function(v) killAuraRange = v end)
task.spawn(function()
    while not library.Unloaded do
        if killAuraOn then
            local root = myRoot()
            if root then
                local excl = {}
                for _, t in ipairs(rb.getTargetList()) do excl[t] = true end
                for _, p in ipairs(hook.players.list()) do
                    if p ~= LocalPlayer and not excl[p] then
                        local hrp, ch = aliveParts(p)
                        if hrp and (hrp.Position - root.Position).Magnitude <= killAuraRange
                            and ((not knockCheckOn) or not isKnocked(p))
                            and isVisible(headPos(), hrp, ch) then
                            rb.addTarget(p)
                        end
                    end
                end
            end
        end
        task.wait(0.2)
    end
end)

-- Visualization: ragebot target line + outline for the locked target
Target:NewSection("Visualization")
rb.setShowLine(false); rb.setShowOutline(false)   -- off until enabled
regToggle(Target, "HC_ShowLine", "Target line", false, function(v) rb.setShowLine(v) end)
regColor(Target, "HC_LineColor", "Line color", Color3.fromRGB(255, 60, 60), function(c) rb.setLineColor(c) end)
regDropdown(Target, "HC_LineOrigin", "Line origin", "Bottom", { "Bottom", "Center", "Top", "Mouse" }, false, function(v) rb.setLineOrigin(v) end)
regToggle(Target, "HC_ShowOutline", "Target outline", false, function(v) rb.setShowOutline(v) end)
regColor(Target, "HC_OutlineColor", "Outline color", Color3.fromRGB(255, 80, 80), function(c) rb.setOutlineColor(c) end)

-- ============================================================
--  COMBAT
-- ============================================================
local Combat = Window:NewTab("Combat")

-- Force Hit only fires while Auto Shoot is on: forceHit.fire() no-ops unless
-- Force Hit is active, and the auto-shoot loop is what calls fire().
Combat:NewSection("Force Hit")
regToggle(Combat, "HC_ForceHit", "Force Hit (needs Auto Shoot)", false, function(v)
    if v then hc.forceHit.start() else hc.forceHit.stop() end
end)
regDropdown(Combat, "HC_ForceHitPart", "Hit part", "Head", { "Head", "UpperTorso", "HumanoidRootPart" }, false, function(v) hc.forceHit.setHitPart(v) end)
regSlider(Combat, "HC_ForceHitCooldown", "Cooldown", " ms", { min = 0, max = 1000, default = 200 }, function(v) hc.forceHit.setCooldown(v / 1000) end)

Combat:NewSection("Fake tracer")
regToggle(Combat, "HC_FHTracer", "Show fake bullet tracer", true, function(v) hc.forceHit.setTracerEnabled(v) end)
regColor(Combat, "HC_FHTracerColor", "Tracer color", Color3.fromRGB(0, 255, 80), function(c) hc.forceHit.setTracerColor(c) end)
regDecimal(Combat, "HC_FHTracerLife", "Tracer lifetime", "s", 0.05, 1, 0.2, 100, function(v) hc.forceHit.setTracerLifetime(v) end)
regDropdown(Combat, "HC_FHTracerStyle", "Tracer style", "Standard", { "Standard", "Laser", "Lightning", "Plasma", "Thin" }, false, function(v) hc.forceHit.setTracerStyle(v) end)
regToggle(Combat, "HC_FHTrail", "Trail particles along beam", false, function(v) hc.forceHit.setTrailEnabled(v) end)

Combat:NewSection("Hit sound")
local HC_SOUNDS = {
    { "deep bell", 104441273771318 }, { "crit", 135698842254153 },
    { "m4a1", 18521643711 }, { "pack a punch", 7408420244 },
    { "random sound", 133749572213659 }, { "weird idk what its called", 129157734600366 },
    { "csgo headshot", 133002449941130 }, { "rust headshot", 121566025787365 },
}
local soundLabels, idByLabel = {}, {}
for _, s in ipairs(HC_SOUNDS) do soundLabels[#soundLabels + 1] = s[1]; idByLabel[s[1]] = s[2] end
regToggle(Combat, "HC_FHHitSound", "Play hit sound", true, function(v) hc.forceHit.setHitSoundEnabled(v) end)
regDropdown(Combat, "HC_FHSoundId", "Hit sound", "crit", soundLabels, false, function(label)
    local id = idByLabel[label]; if id then hc.forceHit.setHitSoundId(id) end
end)
regDecimal(Combat, "HC_FHSoundVol", "Hit sound volume", "", 0, 3, 1, 10, function(v) hc.forceHit.setHitSoundVolume(v) end)

-- Auto Shoot: force-hits LOCKED targets (from the Target tab) that are in
-- range, visible (head LOS) and not knocked. Only people you've targeted.
Combat:NewSection("Auto Shoot")
local autoOn, autoRange, autoCooldown = false, 200, 0.15
regToggle(Combat, "HC_AutoShoot", "Auto shoot (targets only)", false, function(v) autoOn = v end)
regSlider(Combat, "HC_AutoShootRange", "Range", "", { min = 10, max = 1000, default = 200 }, function(v) autoRange = v end)
regDecimal(Combat, "HC_AutoShootCooldown", "Cooldown", "s", 0.05, 1, 0.15, 100, function(v) autoCooldown = v end)
local function pickShootTarget()
    local root = myRoot(); if not root then return nil end
    for _, p in ipairs(rb.getTargetList()) do
        local hrp, ch = aliveParts(p)
        if hrp and (hrp.Position - root.Position).Magnitude <= autoRange then
            if (not knockCheckOn) or not isKnocked(p) then
                if isVisible(headPos(), hrp, ch) then return p end
            end
        end
    end
    return nil
end
task.spawn(function()
    while not library.Unloaded do
        if autoOn then
            local p = pickShootTarget()
            if p then hc.forceHit.setTarget(p); pcall(hc.forceHit.fire) end
        end
        task.wait(math.max(0.03, autoCooldown))
    end
end)

-- Camlock: lock the camera onto the active target-system target
Combat:NewSection("Camlock")
local camlockOn, camlockSmooth = false, 0.5
regToggle(Combat, "HC_Camlock", "Camlock to target", false, function(v) camlockOn = v end)
regDecimal(Combat, "HC_CamlockSmooth", "Smoothing", "", 0, 0.95, 0.5, 100, function(v) camlockSmooth = v end)
RunService.RenderStepped:Connect(function()
    if library.Unloaded or not camlockOn then return end
    local tgt = rb.getTarget()
    local part = targetPart(tgt)
    if not part then return end
    local cam = workspace.CurrentCamera
    local goal = CFrame.lookAt(cam.CFrame.Position, part.Position)
    cam.CFrame = cam.CFrame:Lerp(goal, math.clamp(1 - camlockSmooth, 0.02, 1))
end)

-- Knife Bot / Knife Reach / Auto Reload
Combat:NewSection("Knife Bot")
regToggle(Combat, "HC_Voidspam", "Use knife voidspam", false, function(v)
    if v then hook.desync.startVoidspam() else hook.desync.stop() end
end)
regSlider(Combat, "HC_VoidStart", "Start at % of anim", "%", { min = 0, max = 100, default = 40 }, function(v) hook.desync.setShotDelayMs(v) end)
regSlider(Combat, "HC_VoidEnd", "End at % of anim", "%", { min = 0, max = 100, default = 90 }, function(v) hook.desync.setShotSyncMs(v) end)
regToggle(Combat, "HC_KnifeAttach", "Attach to target", false, function(v)
    if v then hc.knifeBot.attach.start() else hc.knifeBot.attach.stop() end
end)
regSlider(Combat, "HC_KnifeDistance", "Attach distance", "", { min = 0, max = 50, default = 3 }, function(v) hc.knifeBot.attach.setDistance(v) end)
regDecimal(Combat, "HC_KnifeClick", "Click interval", "s", 0.05, 5, 0.6, 100, function(v) hc.knifeBot.attach.setClickInterval(v) end)
regToggle(Combat, "HC_KnifeOrbit", "Orbit target", false, function(v) hc.knifeBot.attach.setOrbit(v) end)
regSlider(Combat, "HC_KnifeOrbitSpeed", "Orbit speed", " deg/s", { min = 0, max = 720, default = 180 }, function(v) hc.knifeBot.attach.setOrbitSpeed(v) end)
regToggle(Combat, "HC_KnifeAutoEquip", "Auto-equip [Knife]", false, function(v)
    if v then hc.knifeBot.autoEquip.start() else hc.knifeBot.autoEquip.stop() end
end)

Combat:NewSection("Knife reach")
regToggle(Combat, "HC_KnifeReach", "Enable knife reach", false, function(v)
    if v then hc.knifeReach.start() else hc.knifeReach.stop() end
end)
regSlider(Combat, "HC_KnifeReachSize", "Hitbox size", "", { min = 1, max = math.floor(hc.knifeReach.maxSize or 20), default = math.floor(hc.knifeReach.getSize() or 5) }, function(v) hc.knifeReach.setSize(v) end)
regToggle(Combat, "HC_KnifeReachVis", "Visualize hitbox", false, function(v) hc.knifeReach.setVisualize(v) end)

Combat:NewSection("Auto reload")
regToggle(Combat, "HC_AutoReload", "Auto reload", false, function(v)
    if v then hc.autoReload.start() else hc.autoReload.stop() end
end)
regSlider(Combat, "HC_ReloadThreshold", "Reload at", "%", { min = 1, max = 100, default = math.floor(hc.autoReload.getThreshold() or 35) }, function(v) hc.autoReload.setThreshold(v) end)
regDecimal(Combat, "HC_ReloadCooldown", "Cooldown", "s", 0, 5, hc.autoReload.getCooldown() or 1, 10, function(v) hc.autoReload.setCooldown(v) end)

-- ============================================================
--  CHECKS
-- ============================================================
local Checks = Window:NewTab("Checks")
Checks:NewSection("Knock check")
regToggle(Checks, "HC_KnockCheck", "Skip knocked players", false, function(v) knockCheckOn = v; rb.setSkipKnocked(v) end)

Checks:NewSection("Visible check")
regToggle(Checks, "HC_StrictVis", "Strict (block see-through walls)", false, function(v) hook.utils.setStrictVisibleCheck(v) end)
regDropdown(Checks, "HC_VisOrigin", "Origin", "Camera", { "Camera", "Head", "Tool" }, false, function(v) hook.utils.setVisibleOrigin(v) end)

-- ============================================================
--  UTILS
-- ============================================================
local Utils = Window:NewTab("Utils")
Utils:NewSection("Godmode")
regToggle(Utils, "HC_Godmode", "Godmode", false, function(v)
    if v then hc.godmode.start() else hc.godmode.stop() end
end)

Utils:NewSection("AFK badge")
local antiT, forceT
antiT = regToggle(Utils, "HC_AntiAfk", "Anti-AFK tag (hide)", false, function(v)
    if v then if forceT then forceT:Set(false) end; hc.antiAfkTag.start() else hc.antiAfkTag.stop() end
end)
forceT = regToggle(Utils, "HC_ForceAfk", "Force-AFK tag (always show)", false, function(v)
    if v then if antiT then antiT:Set(false) end; hc.forceAfkTag.start() else hc.forceAfkTag.stop() end
end)

-- shared tabs (Movement/Desync/Visuals/World/Misc/Settings/Config) below
api.buildShared()

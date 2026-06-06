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

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = Players.LocalPlayer

-- decay's knock check: workspace.Players.Characters[name].BodyEffects["K.O"]
-- (or grabbed). Skip these when knock-check is on.
local isKnocked = hc.isKnocked or function() return false end
local knockCheckOn   = false   -- skip knocked when firing
local ignoreKnockedOn = false  -- camlock/active-target falls through knocked -> next priority

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

-- Highest-priority LOCKED target passing the filters. Priority = Closest
-- (min character distance) or Mouse (min viewport distance). Skips knocked
-- when asked, so the next-best target is chosen instead.
local function bestTarget(skipKnocked, requireVisible, range)
    local root = myRoot()
    local cam  = workspace.CurrentCamera
    local mp   = UserInputService:GetMouseLocation()
    local best, bestScore
    for _, p in ipairs(rb.getTargetList()) do
        local hrp, ch = aliveParts(p)
        if hrp
            and (not (skipKnocked and isKnocked(p)))
            and (not (range and root) or (hrp.Position - root.Position).Magnitude <= range)
            and (not requireVisible or isVisible(headPos(), hrp, ch)) then
            local score
            if targetMode == "Mouse" then
                local sp = cam:WorldToViewportPoint(hrp.Position)
                score = (mp - Vector2.new(sp.X, sp.Y)).Magnitude
            else
                score = root and (hrp.Position - root.Position).Magnitude or 0
            end
            if not best or score < bestScore then best, bestScore = p, score end
        end
    end
    return best
end

regDropdown(Target, "HC_TargetMode", "Priority", "Closest", { "Closest", "Mouse" }, false, function(v)
    targetMode = v
    pcall(rb.setPriority, v)
end)

-- Add-target ALWAYS picks the player closest to the mouse (independent of
-- the priority mode, which only controls which locked target is active).
local function addClosestTarget()
    local excl = {}
    for _, t in ipairs(rb.getTargetList()) do excl[t] = true end
    local p = hook.utils.findClosestPlayer({ fov = 9999, exclude = excl })
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

-- ---------- Target actions (operate on the active locked target) ----------
Target:NewSection("Target actions")
local function activeTarget() return bestTarget(false, false, nil) end
-- like activeTarget but skips knocked players (isKnocked also counts being
-- grabbed by someone), so TP shoot / Bring don't pick a downed/carried player
local function activeTargetAlive() return bestTarget(true, false, nil) end

-- upright teleport (won't fall over onto knocked players) + desync-aware
local uprightTp = hook.uprightTp or function(_, h, pos, face)
    if h then h.CFrame = CFrame.new(pos, pos + Vector3.new((face and face.X) or 0, 0, (face and face.Z) or -1)) end
end

-- the six guns; TP shoot / Bring abort if we hold none of them
local GUN_NAMES = { "[DoubleBarrel]", "[Revolver]", "[SMG]", "[Shotgun]", "[Silencer]", "[TacticalShotgun]" }
local DB_NAMES  = { "[DoubleBarrel]", "[Double Barrel]", "[Double-Barrel]" }

-- true if any of the six guns is in our character or backpack
local function hasAnyGun()
    local char = LocalPlayer.Character
    local bp   = LocalPlayer:FindFirstChild("Backpack")
    for _, n in ipairs(GUN_NAMES) do
        if (char and char:FindFirstChild(n)) or (bp and bp:FindFirstChild(n)) then return true end
    end
    return false
end

-- equip the Double Barrel if not already holding it
local function equipDoubleBarrel()
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not hum then return end
    for _, n in ipairs(DB_NAMES) do if char:FindFirstChild(n) then return end end  -- already equipped
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if not bp then return end
    for _, n in ipairs(DB_NAMES) do
        local tool = bp:FindFirstChild(n)
        if tool and tool:IsA("Tool") then pcall(function() hum:EquipTool(tool) end); return end
    end
end

local function torsoOf(ch)
    return ch and (ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso") or ch:FindFirstChild("HumanoidRootPart"))
end

-- true if the player currently has spawn protection (a ForceField)
local function inForceField(plr)
    local ch = plr and plr.Character
    return ch ~= nil and ch:FindFirstChildOfClass("ForceField") ~= nil
end

-- true only if BodyEffects.APPEARANCE_LOADED exists and is true
local function appearanceLoaded(plr)
    local ch = plr and plr.Character
    local fx = ch and ch:FindFirstChild("BodyEffects")
    local v  = fx and fx:FindFirstChild("APPEARANCE_LOADED")
    return v ~= nil and v.Value == true
end

-- safe to engage: not spawn-protected and fully loaded
local function canEngage(plr)
    return not inForceField(plr) and appearanceLoaded(plr)
end

-- TP shoot: equip DB -> save spot -> TP to target (upright) -> force-hit -> TP back ~1s
local function tpShoot()
    if not hasAnyGun() then notify("No gun in inventory", 2, "alert"); return end
    local tgt = activeTargetAlive(); if not tgt then notify("No target", 2, "alert"); return end
    if inForceField(tgt) then notify("Target in forcefield", 2, "alert"); return end
    if not appearanceLoaded(tgt) then notify("Target not loaded", 2, "alert"); return end
    local lc   = LocalPlayer.Character
    local lhrp = lc and lc:FindFirstChild("HumanoidRootPart")
    local thrp = tgt.Character and tgt.Character:FindFirstChild("HumanoidRootPart")
    if not lhrp or not thrp then return end
    equipDoubleBarrel()
    local saved     = lhrp.CFrame
    local wasActive = hc.forceHit.isActive()
    hc.forceHit.setTarget(tgt)
    if not wasActive then hc.forceHit.start() end
    uprightTp(lc, lhrp, thrp.Position, thrp.CFrame.LookVector)
    task.wait(0.12)
    pcall(hc.forceHit.fire)
    -- TP back immediately after the shot
    if lhrp and lhrp.Parent then uprightTp(lc, lhrp, saved.Position, saved.LookVector) end
    if not wasActive then hc.forceHit.stop() end
end

local function gotoTarget()
    local tgt = activeTarget(); if not tgt then notify("No target", 2, "alert"); return end
    pcall(function() hook.players["goto"](tgt) end)
end

-- Bring: equip DB, TP to target (upright) + force-hit, pause auto-stomp, TP
-- upright onto their UpperTorso, fire grab once, then TP back 0.5s AFTER our
-- BodyEffects.Grabbed value changes; resume auto-stomp.
local function bring()
    if not hasAnyGun() then notify("No gun in inventory", 2, "alert"); return end
    local tgt = activeTargetAlive(); if not tgt then notify("No target", 2, "alert"); return end
    if inForceField(tgt) then notify("Target in forcefield", 2, "alert"); return end
    if not appearanceLoaded(tgt) then notify("Target not loaded", 2, "alert"); return end
    local lc   = LocalPlayer.Character
    local lhrp = lc and lc:FindFirstChild("HumanoidRootPart")
    if not lhrp then return end
    task.spawn(function()
        equipDoubleBarrel()
        local saved    = lhrp.CFrame
        local fx       = lc:FindFirstChild("BodyEffects")
        local grab     = fx and fx:FindFirstChild("Grabbed")
        local startVal = grab and grab.Value

        local function onTopOfTarget()
            local part = torsoOf(tgt.Character)
            if part and lhrp and lhrp.Parent then
                local pos = part.Position + Vector3.new(0, (part.Size.Y / 2) + 3, 0)
                uprightTp(lc, lhrp, pos, lhrp.CFrame.LookVector)
            end
        end

        -- pause auto-stomp for the whole sequence so we don't finish them off
        local stompWasOn = hc.autoStomp.isActive()
        if stompWasOn then hc.autoStomp.stop() end

        -- 1) You can only grab a KNOCKED player. Stand on them and force-hit
        --    until they're K.O (skip if already knocked).
        local wasFH = hc.forceHit.isActive()
        if not wasFH then hc.forceHit.start() end
        local kt0 = os.clock()
        while not isKnocked(tgt) do
            if not (tgt.Character and tgt.Character.Parent) or not lhrp.Parent then break end
            onTopOfTarget()
            hc.forceHit.setTarget(tgt)
            pcall(hc.forceHit.fire)
            task.wait(0.08)
            if os.clock() - kt0 > 4 then break end
        end
        if not wasFH then hc.forceHit.stop() end

        if not isKnocked(tgt) then
            notify("Couldn't knock target", 2, "alert")
            if lhrp and lhrp.Parent then uprightTp(lc, lhrp, saved.Position, saved.LookVector) end
            if stompWasOn then hc.autoStomp.start() end
            return
        end

        -- 2) Grab: stay on top and SPAM the Grabbing remote every 0.5s until
        --    our BodyEffects.Grabbed value changes (= grab landed).
        local t0 = os.clock()
        repeat
            onTopOfTarget()
            pcall(function() ReplicatedStorage.MainEvent:FireServer("Grabbing") end)
            task.wait(0.5)
            grab = fx and fx:FindFirstChild("Grabbed")
        until (grab and grab.Value ~= startVal) or (os.clock() - t0 > 5) or not lhrp.Parent

        -- 3) bring them home
        if lhrp and lhrp.Parent then uprightTp(lc, lhrp, saved.Position, saved.LookVector) end
        if stompWasOn then hc.autoStomp.start() end
    end)
end

Target:NewButton("TP shoot", tpShoot)
    :AddButton("Goto", gotoTarget)
Target:NewButton("Bring", bring)
Target:NewKeybind("TP shoot key", Enum.KeyCode.K, tpShoot)

-- Visualization: ragebot target line + outline for the locked target
Target:NewSection("Visualization")
rb.setShowLine(false); rb.setShowOutline(false)   -- off until enabled
regToggle(Target, "HC_ShowLine", "Target line", false, function(v) rb.setShowLine(v) end)
regColor(Target, "HC_LineColor", "Line color", Color3.fromRGB(255, 60, 60), function(c) rb.setLineColor(c) end)
regDropdown(Target, "HC_LineOrigin", "Line origin", "Bottom", { "Bottom", "Center", "Top", "Mouse" }, false, function(v) rb.setLineOrigin(v) end)
regToggle(Target, "HC_ShowOutline", "Target outline", false, function(v) rb.setShowOutline(v) end)
regColor(Target, "HC_OutlineColor", "Outline color", Color3.fromRGB(255, 80, 80), function(c) rb.setOutlineColor(c) end)

-- ---------- Target HUD (styled like the menu) ----------
Target:NewSection("Target HUD")
do
    local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
    local function mk(class, props)
        local i = Instance.new(class)
        for k, v in pairs(props) do i[k] = v end
        return i
    end

    local hud = mk("ScreenGui", { Name = "hc_targethud", ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false })
    pcall(function() hud.ResetOnSpawn = false end)
    hud.Parent = guiParent

    local edge = mk("Frame", { Name = "edge", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10),
        Size = UDim2.fromOffset(280, 96), BackgroundColor3 = Color3.fromRGB(60, 60, 60), Parent = hud })
    mk("UICorner", { CornerRadius = UDim.new(0, 2), Parent = edge })
    local bg = mk("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, -2, 1, -2), BackgroundColor3 = Color3.fromRGB(255, 255, 255), ClipsDescendants = true, Parent = edge })
    mk("UICorner", { CornerRadius = UDim.new(0, 2), Parent = bg })
    mk("UIGradient", { Rotation = 90, Parent = bg,
        Color = ColorSequence.new{ ColorSequenceKeypoint.new(0, Color3.fromRGB(34, 34, 34)), ColorSequenceKeypoint.new(1, Color3.fromRGB(28, 28, 28)) } })
    local accentBar = mk("Frame", { BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = library.accentColor, Parent = bg })

    local avatar = mk("ImageLabel", { Position = UDim2.fromOffset(8, 8), Size = UDim2.fromOffset(56, 56),
        BackgroundColor3 = Color3.fromRGB(40, 40, 40), Image = "", Parent = bg })
    mk("UICorner", { CornerRadius = UDim.new(0, 2), Parent = avatar })
    local function lbl(x, y, w, txt, size, xalign)
        return mk("TextLabel", { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, 16),
            BackgroundTransparency = 1, Font = Enum.Font.Code, Text = txt or "", TextColor3 = Color3.fromRGB(200, 200, 200),
            TextSize = size or 13, TextXAlignment = xalign or Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = bg })
    end
    local stateLbl   = lbl(8, 66, 56, "", 12, Enum.TextXAlignment.Center)
    local displayLbl = lbl(72, 8, 200, "", 14)
    local hpBg = mk("Frame", { Position = UDim2.fromOffset(72, 30), Size = UDim2.fromOffset(200, 12),
        BackgroundColor3 = Color3.fromRGB(40, 40, 40), BorderSizePixel = 0, Parent = bg })
    mk("UICorner", { CornerRadius = UDim.new(0, 2), Parent = hpBg })
    local hpFill = mk("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = library.accentColor, BorderSizePixel = 0, Parent = hpBg })
    mk("UICorner", { CornerRadius = UDim.new(0, 2), Parent = hpFill })
    local hpText = lbl(72, 29, 200, "", 12, Enum.TextXAlignment.Center); hpText.Parent = hpBg; hpText.Size = UDim2.new(1, 0, 1, 0); hpText.Position = UDim2.new(0, 0, 0, 0); hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
    local distLbl = lbl(72, 48, 200, "", 13)
    local toolLbl = lbl(72, 66, 200, "", 13)

    regToggle(Target, "HC_TargetHud", "Show target HUD", false, function(v) hud.Enabled = v end)

    local lastUserId
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if library.Unloaded then if hud then hud:Destroy() end; conn:Disconnect(); return end
        if not hud.Enabled then return end
        -- honor the knock checks: skip knocked players when either knock
        -- toggle is on, so the HUD follows the same target as the camlock
        local tgt = bestTarget(knockCheckOn or ignoreKnockedOn, false, nil)
        if not tgt then
            -- only show the HUD when there's an actual target
            edge.Visible = false; lastUserId = nil
            return
        end
        edge.Visible = true
        if tgt.UserId ~= lastUserId then
            lastUserId = tgt.UserId
            task.spawn(function()
                local ok, img = pcall(function()
                    return Players:GetUserThumbnailAsync(tgt.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
                end)
                if ok and img then avatar.Image = img end
            end)
        end
        displayLbl.Text = string.format("%s (@%s) | #%d", tgt.DisplayName, tgt.Name, tgt.UserId)
        local ch  = tgt.Character
        local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        stateLbl.Text = isKnocked(tgt) and "KNOCKED" or (hum and hum.Health > 0 and "Alive" or "Dead")
        if hum then
            local mh = hum.MaxHealth > 0 and hum.MaxHealth or 100
            hpText.Text = math.floor(hum.Health) .. "/" .. math.floor(mh)
            hpFill.Size = UDim2.new(math.clamp(hum.Health / mh, 0, 1), 0, 1, 0)
        else
            hpText.Text = "?"; hpFill.Size = UDim2.new(0, 0, 1, 0)
        end
        local root = myRoot()
        distLbl.Text = (root and hrp) and ("Distance: " .. math.floor((hrp.Position - root.Position).Magnitude) .. "m") or "Distance: -"
        local tool = ch and ch:FindFirstChildOfClass("Tool")
        toolLbl.Text = "Tool: " .. (tool and tool.Name or "none")
        accentBar.BackgroundColor3 = library.accentColor
        hpFill.BackgroundColor3 = library.accentColor
    end)
end

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
task.spawn(function()
    while not library.Unloaded do
        if autoOn then
            -- highest-priority locked target in range + visible, skipping knocked
            local p = bestTarget(knockCheckOn or ignoreKnockedOn, true, autoRange)
            -- only shoot loaded players who aren't spawn-protected (ForceField)
            if p and canEngage(p) then hc.forceHit.setTarget(p); pcall(hc.forceHit.fire) end
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
    -- ignore-knocked: fall through to the next-priority non-knocked target
    local tgt = bestTarget(ignoreKnockedOn, false, nil)
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
regSlider(Combat, "HC_KnifeDistance", "Attach distance", "", { min = 1, max = 50, default = 3 }, function(v) hc.knifeBot.attach.setDistance(v) end)
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
regToggle(Checks, "HC_IgnoreKnocked", "Ignore knocked (switch to next target)", false, function(v) ignoreKnockedOn = v; rb.setIgnoreKnocked(v) end)

Checks:NewSection("Visible check")
regToggle(Checks, "HC_StrictVis", "Strict (block see-through walls)", false, function(v) hook.utils.setStrictVisibleCheck(v) end)
regDropdown(Checks, "HC_VisOrigin", "Origin", "Camera", { "Camera", "Head", "Tool" }, false, function(v) hook.utils.setVisibleOrigin(v) end)

-- ============================================================
--  UTILS
-- ============================================================
local Utils = Window:NewTab("Utils")

Utils:NewSection("Auto stomp")
regToggle(Utils, "HC_AutoStomp", "Auto stomp", false, function(v)
    if v then hc.autoStomp.start() else hc.autoStomp.stop() end
end)
regSlider(Utils, "HC_StompRadius", "Stomp radius", "", { min = 1, max = 50, default = math.floor(hc.autoStomp.getRadius() or 5) }, function(v) hc.autoStomp.setRadius(v) end)
regSlider(Utils, "HC_StompInterval", "Min interval", " ms", { min = 0, max = 2000, default = math.floor((hc.autoStomp.getInterval() or 0) * 1000) }, function(v) hc.autoStomp.setInterval(v / 1000) end)
regToggle(Utils, "HC_StompRage", "Stomp targets only", false, function(v) hc.autoStomp.setRageTargets(v) end)

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

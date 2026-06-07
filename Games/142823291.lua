-- ============================================================
--  witherhook // Games/142823291.lua   (Murder Mystery 2)
--  Loads the shared shell (main.lua) then adds a single "Main"
--  tab with every MM2 feature. Wired to hook.games.mm2 (+ desync
--  for invisible).
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

-- ============================================================
--  MURDER MYSTERY 2 BACKEND  (moved here from functions.lua)
--  Registers onto hook.games.mm2; deps come from hook.util.
-- ============================================================
do
    local lplr       = hook.util.lplr
    local RunService = hook.util.runService

--  GAMES: MURDER MYSTERY 2 (MM2)
-- ============================================================
--  Three features bundled under hook.games.mm2:
--
--    identityEsp.start() / .stop()
--      Scans every player's Character + Backpack for tools named
--      "Gun" or "Knife". Above their head, renders a BillboardGui
--      label saying "Sheriff" (Gun) or "Murderer" (Knife). Other
--      players show no label. Updates every 0.5s.
--
--    pickupGun.fire()
--      Locates a BasePart named "GunDrop" in workspace. Spoofs our
--      HRP.CFrame to the drop's position on Heartbeat (write) +
--      RenderStep First (restore real CFrame so locally we stay
--      put). Server sees us at the drop -> auto-pickup proximity
--      triggers. Stops after ~1.5s or when the drop disappears.
--
--    autoPickupGun.start() / .stop()
--      Polls every 0.5s for a GunDrop. When one exists, calls
--      pickupGun.fire() then waits 1.5s before the next check
--      to avoid re-triggering on the same drop.
-- ============================================================
hook.games.mm2 = (function()
    local Players = game:GetService("Players")
    local IDENTITY = { Gun = "Sheriff", Knife = "Murderer" }
    local COLORS = {
        Sheriff  = Color3.fromRGB( 80, 160, 255),
        Murderer = Color3.fromRGB(255,  80,  80),
    }

    -- ---------- Identity ESP ----------
    -- Uses Drawing.new("Text") (matches the main ESP look) instead
    -- of BillboardGui. Position is projected from each player's
    -- head every RenderStepped so labels follow heads smoothly.
    -- Identity (Gun -> Sheriff, Knife -> Murderer) is re-scanned
    -- in a separate thread every 0.25s.
    local identityActive = false
    local identityScanThread
    local identityRenderConn
    local identityDraws = {}  -- [Player] = Drawing.new("Text")
    local identityCache = {}  -- [Player] = "Sheriff"|"Murderer"|nil

    -- Reads a player's identity from their Character + Backpack tools.
    -- Callers that want to skip the local player must filter
    -- themselves - autoPickupGun uses this to detect "am I the
    -- murderer" so it can skip pickups.
    local function getIdentity(plr)
        if not plr then return nil end
        local function scan(parent)
            if not parent then return nil end
            for _, t in ipairs(parent:GetChildren()) do
                if t:IsA("Tool") and IDENTITY[t.Name] then
                    return IDENTITY[t.Name]
                end
            end
            return nil
        end
        return scan(plr.Character) or scan(plr:FindFirstChild("Backpack"))
    end

    local function buildDraw()
        if not Drawing or not Drawing.new then return nil end
        local t = Drawing.new("Text")
        t.Visible      = false
        t.Center       = true
        t.Outline      = true
        t.OutlineColor = Color3.new(0, 0, 0)
        t.Color        = Color3.fromRGB(255, 255, 255)
        t.Size         = 13         -- matches main ESP name size
        t.Font         = 2          -- bold
        t.Text         = ""
        return t
    end

    local function removeDraw(plr)
        local d = identityDraws[plr]
        if d then pcall(function() d:Remove() end) end
        identityDraws[plr] = nil
        identityCache[plr] = nil
    end

    local function clearAllDraws()
        for plr, _ in pairs(identityDraws) do
            removeDraw(plr)
        end
    end

    local function identityStart()
        if identityActive then return end
        identityActive = true

        -- background scan: refresh identity cache every 0.25s
        if identityScanThread then pcall(task.cancel, identityScanThread) end
        identityScanThread = task.spawn(function()
            while identityActive do
                local live = {}
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= lplr then
                        live[plr] = true
                        local id = getIdentity(plr)
                        identityCache[plr] = id
                        -- IDENTITY LOST: nuke the draw too. Without
                        -- this, the render loop stops iterating this
                        -- player (cache nil = no entry) and the
                        -- drawing stays stuck at its last position.
                        if not id and identityDraws[plr] then
                            removeDraw(plr)
                        end
                    end
                end
                -- PLAYER LEFT: prune draws (and cache entries) for any
                -- player no longer in Players:GetPlayers().
                for plr, _ in pairs(identityDraws) do
                    if not live[plr] then removeDraw(plr) end
                end
                task.wait(0.25)
            end
        end)

        -- render loop: project head -> screen, position label,
        -- runs every frame so labels follow movement smoothly.
        if identityRenderConn then identityRenderConn:Disconnect() end
        identityRenderConn = RunService.RenderStepped:Connect(function()
            if not identityActive then return end
            local cam = workspace.CurrentCamera
            if not cam then return end
            for plr, id in pairs(identityCache) do
                local d = identityDraws[plr]
                local char = plr.Character
                local head = char and char:FindFirstChild("Head")
                if id and head then
                    if not d then
                        d = buildDraw()
                        identityDraws[plr] = d
                    end
                    if d then
                        local sp, onScreen = cam:WorldToViewportPoint(head.Position + Vector3.new(0, 2.6, 0))
                        if onScreen then
                            d.Position = Vector2.new(sp.X, sp.Y)
                            d.Text     = id
                            d.Color    = COLORS[id] or Color3.fromRGB(255, 255, 255)
                            d.Visible  = true
                        else
                            d.Visible = false
                        end
                    end
                elseif d then
                    -- character / head missing OR identity nil: remove
                    -- the draw entirely so it can't get stuck visible.
                    -- A fresh one rebuilds next time identity returns.
                    removeDraw(plr)
                end
            end
        end)
    end

    local function identityStop()
        identityActive = false
        if identityScanThread then pcall(task.cancel, identityScanThread); identityScanThread = nil end
        if identityRenderConn then identityRenderConn:Disconnect(); identityRenderConn = nil end
        clearAllDraws()
    end

    -- ---------- GunDrop tracking ----------
    -- A live cache of every BasePart named "GunDrop" currently in
    -- workspace, maintained via DescendantAdded/Removing listeners.
    -- The previous workspace:GetDescendants() scan was the dominant
    -- perf cost when MM2 maps have thousands of descendants - this
    -- replaces it with O(1) lookups.
    --
    -- Cache + listener installation are gated on getgenv so script
    -- reloads don't double-stack listeners. The cache table itself
    -- is shared via getgenv too, so listeners installed by a prior
    -- script run still write to the same table this run reads.
    getgenv()._F_MM2_GUNDROP_CACHE = getgenv()._F_MM2_GUNDROP_CACHE or {}
    local _gunDropCache = getgenv()._F_MM2_GUNDROP_CACHE
    if not getgenv()._F_MM2_GUNDROP_HOOKED then
        getgenv()._F_MM2_GUNDROP_HOOKED = true
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("BasePart") and d.Name == "GunDrop" then
                _gunDropCache[d] = true
            end
        end
        workspace.DescendantAdded:Connect(function(d)
            if d:IsA("BasePart") and d.Name == "GunDrop" then
                _gunDropCache[d] = true
            end
        end)
        workspace.DescendantRemoving:Connect(function(d)
            if _gunDropCache[d] then
                _gunDropCache[d] = nil
            end
        end)
    end

    local function findGunDrop()
        for d, _ in pairs(_gunDropCache) do
            if d.Parent then return d end
            _gunDropCache[d] = nil  -- prune stale
        end
        return nil
    end

    -- Actual teleport pickup: save HRP CFrame, write GunDrop CFrame,
    -- wait PICKUP_HOLD_MS, write the saved CFrame back. The brief
    -- physical presence at the drop triggers MM2's proximity-based
    -- pickup remote. The previous Heartbeat-write/RenderStep-restore
    -- "desync" never put us PHYSICALLY there at all (just spoofed
    -- replication briefly), so the pickup never fired.
    local PICKUP_HOLD_MS = 100   -- ms to stay at the drop
    local pickupActive = false

    -- If any hook.desync mode is active when we start the pickup, we
    -- stop it for the duration so our HRP is actually at our REAL
    -- position before the teleport (otherwise the server sees us in
    -- the void / sky / wherever, never at the drop). We restart the
    -- same mode once the pickup window closes.
    local DESYNC_RESTARTERS = {
        void      = "startVoid",
        voidspam  = "startVoidspam",
        sky       = "startSky",
        spin      = "startSpin",
        velocity  = "startVelocity",
        raknet    = "startRaknet",
        invisible = "startInvisible",
    }

    -- Return values:
    --   true                success - teleport in progress
    --   false, "active"     a previous pickup is still mid-flight (silent)
    --   false, "no_drop"    no GunDrop exists in the workspace (notify)
    --   false, "no_hrp"     local character isn't loaded
    local function pickupOnce()
        if pickupActive then return false, "active" end
        local drop = findGunDrop(); if not drop then return false, "no_drop" end
        local char = lplr.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return false, "no_hrp" end

        -- snapshot + stop any active desync so we actually go to the
        -- drop position rather than sitting at our spoofed location
        local restartName
        if hook.desync and hook.desync.getMode then
            local m = hook.desync.getMode()
            if m and m ~= "off" and DESYNC_RESTARTERS[m] then
                restartName = DESYNC_RESTARTERS[m]
                hook.desync.stop()
            end
        end

        pickupActive = true
        local realCF = hrp.CFrame
        pcall(function() hrp.CFrame = drop.CFrame end)
        task.delay(PICKUP_HOLD_MS / 1000, function()
            if hrp.Parent then
                pcall(function() hrp.CFrame = realCF end)
            end
            pickupActive = false
            -- restore the desync mode that was active before pickup
            if restartName and hook.desync and hook.desync[restartName] then
                pcall(function() hook.desync[restartName]() end)
            end
        end)
        return true
    end

    -- ---------- Dropped-gun ESP ----------
    -- Highlight on the drop part (so you can see through walls) +
    -- a Drawing.new("Text") "GUN" label above it (matches main ESP).
    -- Scan every 0.3s for new/removed drops; project the label
    -- position every RenderStepped.
    local dropEspActive = false
    local dropEspScanThread
    local dropEspRenderConn
    local dropEspAdorned = {}  -- [drop part] = { hl, draw }

    local function buildDropDraw()
        if not Drawing or not Drawing.new then return nil end
        local t = Drawing.new("Text")
        t.Visible      = false
        t.Center       = true
        t.Outline      = true
        t.OutlineColor = Color3.new(0, 0, 0)
        t.Color        = Color3.fromRGB(255, 215, 60)
        t.Size         = 13
        t.Font         = 2
        t.Text         = "GUN"
        return t
    end

    local function attachDropMarker(drop)
        local hl = Instance.new("Highlight")
        hl.Name                = "_mm2_dropgun_hl"
        hl.FillColor           = Color3.fromRGB(255, 215,  60)
        hl.OutlineColor        = Color3.fromRGB(255, 255, 255)
        hl.FillTransparency    = 0.45
        hl.OutlineTransparency = 0
        hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee             = drop
        hl.Parent              = drop
        return hl, buildDropDraw()
    end

    local function removeDropMarker(m)
        if m.hl   and m.hl.Parent   then pcall(function() m.hl:Destroy() end) end
        if m.draw                   then pcall(function() m.draw:Remove() end) end
    end

    local function dropEspClearAll()
        for _, m in pairs(dropEspAdorned) do removeDropMarker(m) end
        dropEspAdorned = {}
    end

    local function dropEspScanTick()
        -- iterate the live cache (O(N) where N = active drop count,
        -- usually 0 or 1) instead of workspace:GetDescendants()
        local seen = {}
        for d, _ in pairs(_gunDropCache) do
            if d.Parent then
                seen[d] = true
                if not dropEspAdorned[d] then
                    local hl, draw = attachDropMarker(d)
                    dropEspAdorned[d] = { hl = hl, draw = draw }
                end
            else
                _gunDropCache[d] = nil  -- prune stale
            end
        end
        for drop, m in pairs(dropEspAdorned) do
            if not seen[drop] or not drop.Parent then
                removeDropMarker(m)
                dropEspAdorned[drop] = nil
            end
        end
    end

    local function dropEspStart()
        if dropEspActive then return end
        dropEspActive = true
        if dropEspScanThread then pcall(task.cancel, dropEspScanThread) end
        dropEspScanThread = task.spawn(function()
            while dropEspActive do
                pcall(dropEspScanTick)
                task.wait(0.3)
            end
        end)
        if dropEspRenderConn then dropEspRenderConn:Disconnect() end
        dropEspRenderConn = RunService.RenderStepped:Connect(function()
            if not dropEspActive then return end
            local cam = workspace.CurrentCamera
            if not cam then return end
            for drop, m in pairs(dropEspAdorned) do
                if drop.Parent and m.draw then
                    local sp, onScreen = cam:WorldToViewportPoint(drop.Position + Vector3.new(0, 1.5, 0))
                    if onScreen then
                        m.draw.Position = Vector2.new(sp.X, sp.Y)
                        m.draw.Visible  = true
                    else
                        m.draw.Visible = false
                    end
                end
            end
        end)
    end

    local function dropEspStop()
        dropEspActive = false
        if dropEspScanThread then pcall(task.cancel, dropEspScanThread); dropEspScanThread = nil end
        if dropEspRenderConn then dropEspRenderConn:Disconnect(); dropEspRenderConn = nil end
        dropEspClearAll()
    end

    -- ---------- Murderer trigger (hover -> fire nil RemoteEvent) ----------
    -- When mouse hovers over the player identified as Murderer, fire a
    -- nil-parented RemoteEvent with (theirHRP.CFrame, myHRP.CFrame).
    -- Args format matches the canonical MM2 hit payload the user
    -- provided. Throttled per-fire so we don't spam the remote.
    local triggerActive = false
    local triggerConn
    local triggerLastFire = 0
    local TRIGGER_COOLDOWN = 0.4

    -- The Gun tool's Shoot RemoteEvent works whether the Gun is in
    -- the Character (equipped) OR in the Backpack (not equipped) -
    -- captured both cases. We check both parents so no auto-equip
    -- is needed.
    local function findHitRemote()
        local function pull(parent)
            if not parent then return nil end
            local gun = parent:FindFirstChild("Gun")
            if not gun then return nil end
            return gun:FindFirstChild("Shoot")
        end
        return pull(lplr.Character) or pull(lplr:FindFirstChild("Backpack"))
    end

    local mouseRef
    local function getMouse()
        if mouseRef then return mouseRef end
        mouseRef = lplr:GetMouse()
        return mouseRef
    end

    local function getHoveredPlayer()
        local m = getMouse(); if not m then return nil end
        local target = m.Target; if not target then return nil end
        local model = target:FindFirstAncestorOfClass("Model")
        if not model then return nil end
        return Players:GetPlayerFromCharacter(model)
    end

    -- Hit-position resolver. Prefers HumanoidRootPart by name (raw
    -- instance, no GetPivot - MM2 might re-point PrimaryPart so the
    -- pivot would be spoofed). Falls through a wide chain so we
    -- ALWAYS return a CFrame as long as the character has any
    -- BasePart, even if MM2 is messing with the standard names.
    local function targetHitCF(char)
        if not char then return nil end
        -- Head first - MM2 server validates the hit part client-claims,
        -- and the shoot remote accepts head shots all the same. Aiming
        -- at the head also makes the visual match what you'd see if
        -- you actually shot the player normally.
        local head = char:FindFirstChild("Head")
        if head and head:IsA("BasePart") then return head.CFrame end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp and hrp:IsA("BasePart") then return hrp.CFrame end
        local p = char:FindFirstChild("LowerTorso")
              or char:FindFirstChild("Torso")
              or char:FindFirstChild("UpperTorso")
        if p and p:IsA("BasePart") then return p.CFrame end
        -- GetPivot fallback (may return spoofed pivot but at least
        -- it's a CFrame so the shot fires)
        if char.GetPivot then
            local ok, cf = pcall(function() return char:GetPivot() end)
            if ok and cf then return cf end
        end
        -- Final fallback: any BasePart anywhere in the character
        local any = char:FindFirstChildWhichIsA("BasePart")
        return any and any.CFrame or nil
    end
    -- Second arg is "my position" with identity rotation - matches the
    -- canonical payload exactly (CFrame.new(x, y, z) without basis
    -- vectors).
    local function myPosCFrame()
        local c = lplr.Character
        local hrp = c and c:FindFirstChild("HumanoidRootPart")
        if not hrp then return nil end
        return CFrame.new(hrp.Position)
    end


    local function triggerStart()
        if triggerActive then return end
        triggerActive = true
        if triggerConn then triggerConn:Disconnect() end
        triggerConn = RunService.RenderStepped:Connect(function()
            if not triggerActive then return end
            if tick() - triggerLastFire < TRIGGER_COOLDOWN then return end
            local plr = getHoveredPlayer()
            if not plr or plr == lplr then return end
            if hook.whitelist and hook.whitelist.contains(plr) then return end
            if identityCache[plr] ~= "Murderer" and getIdentity(plr) ~= "Murderer" then return end
            local theirCF = targetHitCF(plr.Character)
            local myPos   = myPosCFrame()
            if not theirCF or not myPos then return end
            local remote = findHitRemote()
            if not remote then return end  -- no Gun in Character or Backpack -> not Sheriff
            -- Canonical payload from captures: arg1 = target's pivot
            -- CFrame (= HRP.CFrame), arg2 = our HRP position with
            -- identity rotation.
            pcall(function() remote:FireServer(theirCF, myPos) end)
            triggerLastFire = tick()
        end)
    end

    local function triggerStop()
        triggerActive = false
        if triggerConn then triggerConn:Disconnect(); triggerConn = nil end
    end

    -- ---------- Shoot murderer (one-shot, no hover required) ----------
    -- Resolves the Murderer from a live getIdentity() scan, then fires
    -- the Gun's Shoot remote with (theirHRP.CFrame, myHRP.CFrame).
    --
    -- If the Gun isn't equipped but we have it in our Backpack
    -- (we're the Sheriff), auto-equips it and delays the fire by
    -- 0.5s so the Gun child + its Shoot remote have time to mount.
    --
    -- Return values (loader uses reason for specific notify):
    --   true                     success (immediate or deferred)
    --   false, "no_my_hrp"       local HRP missing
    --   false, "no_murderer"     no player holds the Knife
    --   false, "no_victim_hrp"   target's HRP missing
    --   false, "no_gun"          no Gun in Character or Backpack
    --                            (we're not the Sheriff)
    -- Same desync-stop-restart pattern as pickup. If we're spoofed
    -- to the void at fire time, the server's shooter-position
    -- validation rejects the hit because arg2 (our real HRP) won't
    -- match where the server thinks we are.
    local SHOOT_DESYNC_RESTARTERS = {
        void      = "startVoid",
        voidspam  = "startVoidspam",
        sky       = "startSky",
        spin      = "startSpin",
        velocity  = "startVelocity",
        raknet    = "startRaknet",
        invisible = "startInvisible",
    }

    local function shootMurdererFire()
        local victim
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= lplr
                and not (hook.whitelist and hook.whitelist.contains(plr))
                and getIdentity(plr) == "Murderer" then
                victim = plr; break
            end
        end
        if not victim then return false, "no_murderer" end
        local theirCF = targetHitCF(victim.Character)
        if not theirCF then return false, "no_victim_hrp" end

        local remote = findHitRemote()
        if not remote then return false, "no_gun" end

        -- snapshot + stop any active desync so our HRP is at the real
        -- position before the shot. Server-side shooter-position
        -- validation rejects the hit otherwise.
        local restartName
        if hook.desync and hook.desync.getMode then
            local m = hook.desync.getMode()
            if m and m ~= "off" and SHOOT_DESYNC_RESTARTERS[m] then
                restartName = SHOOT_DESYNC_RESTARTERS[m]
                hook.desync.stop()
            end
        end

        -- Now read myPos AFTER the desync stopped (HRP is back at the
        -- real position) so arg2 matches what the server has for us.
        local myPos = myPosCFrame()
        if not myPos then
            if restartName and hook.desync and hook.desync[restartName] then
                pcall(function() hook.desync[restartName]() end)
            end
            return false, "no_my_hrp"
        end

        -- Canonical payload from MM2 captures:
        --   arg1 = target's HumanoidRootPart CFrame
        --   arg2 = shooter HRP position with IDENTITY rotation
        --          (CFrame.new(x, y, z) with default basis)
        local ok, err = pcall(function() remote:FireServer(theirCF, myPos) end)
        if not ok then
            print("[decay.lua] Shoot FireServer error:", err)
        end

        -- restart desync after a brief grace period so the shot has
        -- time to register server-side before we vanish again
        if restartName then
            task.delay(0.2, function()
                if hook.desync and hook.desync[restartName] then
                    pcall(function() hook.desync[restartName]() end)
                end
            end)
        end
        return true
    end

    -- ---------- Auto-pickup ----------
    local autoActive = false
    local autoThread

    local function autoStart()
        if autoActive then return end
        autoActive = true
        if autoThread then pcall(task.cancel, autoThread) end
        autoThread = task.spawn(function()
            while autoActive do
                local drop = findGunDrop()
                -- skip pickup if we're the murderer (have Knife) - we
                -- don't want to grab the sheriff's gun and reveal our
                -- identity, and we can't use it anyway
                local myIdentity = getIdentity(lplr)
                if drop and myIdentity ~= "Murderer" then
                    pickupOnce()
                    task.wait(2)
                else
                    task.wait(0.5)
                end
            end
        end)
    end

    local function autoStop()
        autoActive = false
        if autoThread then pcall(task.cancel, autoThread); autoThread = nil end
    end

    return {
        identityEsp = {
            start    = identityStart,
            stop     = identityStop,
            isActive = function() return identityActive end,
        },
        pickupGun = {
            fire = pickupOnce,
        },
        autoPickupGun = {
            start    = autoStart,
            stop     = autoStop,
            isActive = function() return autoActive end,
        },
        dropEsp = {
            start    = dropEspStart,
            stop     = dropEspStop,
            isActive = function() return dropEspActive end,
        },
        triggerMurderer = {
            start    = triggerStart,
            stop     = triggerStop,
            isActive = function() return triggerActive end,
        },
        shootMurderer = {
            fire = shootMurdererFire,
        },
    }
end)()

end

local mm2 = hook.games and hook.games.mm2
if not mm2 then
    notify("Murder Mystery 2 module unavailable", 5, "error")
    return
end

local Main = Window:NewTab("Main")

-- ---------- Identity ESP ----------
Main:NewSection("Identity ESP")
regToggle(Main, "MM2_IdentityEsp", "Sheriff / Murderer labels", false, function(v)
    if v then mm2.identityEsp.start() else mm2.identityEsp.stop() end
end)

-- ---------- Gun pickup ----------
Main:NewSection("Gun pickup")
regToggle(Main, "MM2_DropEsp", "Dropped gun ESP", false, function(v)
    if v then mm2.dropEsp.start() else mm2.dropEsp.stop() end
end)

local PICKUP_ERR = {
    no_drop = "Can't pick up yet - Sheriff hasn't dropped the gun.",
    no_hrp  = "Your character isn't loaded.",
}
local function tryPickup()
    local ok, reason = mm2.pickupGun.fire()
    if not ok and reason and PICKUP_ERR[reason] then notify(PICKUP_ERR[reason], 3, "alert") end
end
Main:NewButton("Pickup gun now", tryPickup)
Main:NewKeybind("Pickup gun key", Enum.KeyCode.H, function() tryPickup() end)
regToggle(Main, "MM2_AutoPickup", "Auto pickup gun", false, function(v)
    if v then mm2.autoPickupGun.start() else mm2.autoPickupGun.stop() end
end)

-- ---------- Sheriff: shoot the murderer ----------
Main:NewSection("Sheriff")
local SHOOT_ERR = {
    no_gun        = "You don't have the Gun. Only the Sheriff can shoot.",
    no_my_hrp     = "Your character isn't loaded yet.",
    no_murderer   = "No player is holding the [Knife] tool right now.",
    no_victim_hrp = "Murderer's character isn't loaded.",
}
local function tryShoot()
    local ok, reason = mm2.shootMurderer.fire()
    if not ok then notify(SHOOT_ERR[reason] or ("Shoot failed: " .. tostring(reason)), 3, "error") end
end
Main:NewButton("Shoot murderer", tryShoot)
Main:NewKeybind("Shoot murderer key", Enum.KeyCode.K, function() tryShoot() end)

-- ---------- Murderer: knife kill ----------
-- Uses your Knife tool's own remotes: KnifeStabbed (the swing) then
-- HandleTouched (registers a hit on a victim's body part).
Main:NewSection("Murderer knife")
local Players2     = game:GetService("Players")
local LocalPlayer2 = Players2.LocalPlayer

local function knifeEvents()
    local ch    = LocalPlayer2.Character
    local knife = ch and ch:FindFirstChild("Knife")
    local ev    = knife and knife:FindFirstChild("Events")
    if not ev then return nil end
    return ev:FindFirstChild("KnifeStabbed"), ev:FindFirstChild("HandleTouched")
end
local function victimPart(plr)
    local ch = plr and plr.Character
    if not ch then return nil end
    return ch:FindFirstChild("LowerTorso") or ch:FindFirstChild("Torso") or ch:FindFirstChild("HumanoidRootPart")
end
local function isAlive(plr)
    local ch  = plr and plr.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health > 0
end
local function myRoot2()
    local ch = LocalPlayer2.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

-- swing once, then register a hit on every living player (optionally in range)
local function knifeKillAll(range)
    local stab, touch = knifeEvents()
    if not (stab and touch) then notify("You're not holding the [Knife]", 3, "alert"); return end
    local root = myRoot2()
    pcall(function() stab:FireServer() end)
    for _, p in ipairs(Players2:GetPlayers()) do
        if p ~= LocalPlayer2 and isAlive(p) then
            local part = victimPart(p)
            if part and (not range or not root or (part.Position - root.Position).Magnitude <= range) then
                pcall(function() touch:FireServer(part) end)
            end
        end
    end
end

Main:NewButton("Kill all", function() knifeKillAll(nil) end)
local knifeAuraOn, knifeAuraRange = false, 30
regToggle(Main, "MM2_KnifeAura", "Knife aura (auto)", false, function(v) knifeAuraOn = v end)
regSlider(Main, "MM2_KnifeAuraRange", "Aura range", "", { min = 5, max = 200, default = 30 }, function(v) knifeAuraRange = v end)
task.spawn(function()
    while not library.Unloaded do
        if knifeAuraOn then knifeKillAll(knifeAuraRange) end
        task.wait(0.3)
    end
end)

-- shared tabs (Movement/Desync/Visuals/World/Misc/Settings/Config) below
api.buildShared()

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

-- ============================================================
--  HOOD CUSTOMS BACKEND  (moved here from functions.lua)
--  Registers onto hook.games.hoodCustoms so the shared ragebot
--  in functions.lua can still reach it. Deps come from hook.util.
-- ============================================================
do
    local lplr                = hook.util.lplr
    local plrs                = hook.util.players
    local RunService          = hook.util.runService
    local VirtualInputManager = hook.util.vim
    local ReplicatedStorage   = hook.util.replicatedStorage
    local makeToggle          = hook.util.makeToggle
    local G                   = hook.util.state
    local _uprightTp          = hook.uprightTp
    -- ragebot stayed in functions.lua; its current-target getter is reached
    -- through the exposed API (knifeBot/forceHit use it for "current target")
    local rbGetTarget         = hook.ragebot and hook.ragebot.getTarget


-- ============================================================
--  GAMES: HOOD CUSTOMS - AUTO STOMP
--  Spams ReplicatedStorage.MainEvent:FireServer("Stomp") on Heartbeat,
--  but only while the local player is standing over another player
--  (within a small horizontal radius and slightly above them) so we
--  don't flood the server when there's nothing to stomp.
-- ============================================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- cached MainEvent getter (closure-local cache lives in IIFE, no extra top-level locals)
local getMainEvent = (function()
    local cache
    return function()
        if cache and cache.Parent then return cache end
        cache = ReplicatedStorage:FindFirstChild("MainEvent")
        return cache
    end
end)()

-- HC: detect "grabbed" state. When player A picks up player B, the K.O
-- value on B's BodyEffects flips OFF (so the regular K.O check thinks B
-- is alive). Meanwhile, on A's BodyEffects, a "Grabbed" value is set to
-- B's name / B's player ref. We scan every character's BodyEffects.Grabbed
-- and treat plr as "being grabbed" if any other character points to them.
-- Handles both StringValue (name) and ObjectValue (Player / Character)
-- forms since we don't know which HC uses without inspecting in-game.
local function _hcIsGrabbed(plr)
    if not plr then return false end
    local wsPlayers = workspace:FindFirstChild("Players")
    local chars = wsPlayers and wsPlayers:FindFirstChild("Characters")
    if not chars then return false end
    local target = plr.Name
    for _, mdl in ipairs(chars:GetChildren()) do
        if mdl.Name ~= target then  -- skip own folder
            local fx = mdl:FindFirstChild("BodyEffects")
            if fx then
                local g = fx:FindFirstChild("Grabbed")
                if g then
                    local v = g.Value
                    if v == target then return true end
                    if typeof(v) == "Instance" then
                        if v == plr then return true end
                        if v.Name == target then return true end
                    end
                end
            end
        end
    end
    return false
end

-- HC-specific knocked check via workspace.Players.Characters.<name>.BodyEffects["K.O"].Value
-- Treats "being grabbed by someone" as still knocked, since the K.O bool
-- gets flipped off the instant a grabber starts carrying them. Without
-- this every grabbed target would slip through SkipKnocked / IgnoreKnocked
-- and we'd dump shots into people who are effectively still down.
local function _hcIsKnocked(plr)
    if not plr then return false end
    local wsPlayers = workspace:FindFirstChild("Players")
    local chars = wsPlayers and wsPlayers:FindFirstChild("Characters")
    if not chars then return false end
    local mdl = chars:FindFirstChild(plr.Name)
    if mdl then
        local fx = mdl:FindFirstChild("BodyEffects")
        if fx then
            local ko = fx:FindFirstChild("K.O")
            if ko ~= nil and ko.Value == true then return true end
        end
    end
    -- Grabbed counts as knocked (K.O flips off when picked up)
    return _hcIsGrabbed(plr)
end

hook.games = hook.games or {}
hook.games.hoodCustoms = hook.games.hoodCustoms or {}
hook.games.hoodCustoms.isKnocked = _hcIsKnocked
hook.games.hoodCustoms.isGrabbed = _hcIsGrabbed

hook.games.hoodCustoms.autoStomp = (function()
    local conn
    local last = 0
    local radius, vertUp, vertDown = 5, 7, 1
    local interval = 0
    local rageTargets = false

    local function someoneBelow()
        local lc = lplr.Character
        local lhrp = lc and lc:FindFirstChild("HumanoidRootPart")
        if not lhrp then return false end
        for _, p in ipairs(plrs:GetPlayers() or plrs:GetPlayers()) do
            if p == lplr then continue end
            local char = p.Character; if not char then continue end
            local hrp = char:FindFirstChild("HumanoidRootPart"); if not hrp then continue end
            local hum = char:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 then continue end
            local d = lhrp.Position - hrp.Position
            local horizD = Vector2.new(d.X, d.Z).Magnitude
            if horizD <= radius and d.Y <= vertUp and d.Y >= -vertDown then return true end
        end
        return false
    end

    local function start()
        G.hcAutoStompActive = true
        if conn then conn:Disconnect() end
        conn = RunService.Heartbeat:Connect(function()
            if not G.hcAutoStompActive then return end
            if interval > 0 and tick() - last < interval then return end
            local me = getMainEvent()
            if not me then return end
            if rageTargets then
                local list = hook.ragebot.getTargetList and hook.ragebot.getTargetList() or {}
                for _, plr in ipairs(list) do
                    if _hcIsKnocked(plr) then
                        local char = plr.Character
                        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                        if hrp then
                            local lc   = lplr.Character
                            local lhrp = lc and lc:FindFirstChild("HumanoidRootPart")
                            if lhrp then _uprightTp(lc, lhrp, hrp.Position + Vector3.new(0, 3, 0), nil) end
                            last = tick()
                            pcall(function() me:FireServer("Stomp") end)
                            return
                        end
                    end
                end
                return  -- targets-only: never fall through to stomp non-targets
            end
            if not someoneBelow() then return end
            last = tick()
            pcall(function() me:FireServer("Stomp") end)
        end)
    end

    local function stop()
        G.hcAutoStompActive = false
        if conn then conn:Disconnect(); conn = nil end
    end

    local t = makeToggle(start, stop, "hcAutoStompActive")
    t.setRadius      = function(n) radius   = math.clamp(tonumber(n) or 5, 1, 30) end
    t.getRadius      = function() return radius end
    t.setInterval    = function(n) interval = math.clamp(tonumber(n) or 0, 0, 5) end
    t.getInterval    = function() return interval end
    t.setRageTargets = function(b) rageTargets = b == true end
    t.getRageTargets = function() return rageTargets end
    return t
end)()

-- ============================================================
--  GAMES: HOOD CUSTOMS - AUTO RELOAD
--  Reads exactly:  lplr.Character.<Tool>.Script.Ammo
--  When that IntValue is <= threshold, sends the configured reload key.
-- ============================================================
hook.games.hoodCustoms.autoReload = (function()
    local key = Enum.KeyCode.R
    local threshold = 0
    local cooldown = 1.5
    local last = 0
    local conn

    local function getAmmo()
        local char = lplr.Character;                                      if not char then return nil end
        local tool = char:FindFirstChildOfClass("Tool");                  if not tool then return nil end
        local script = tool:FindFirstChild("Script");                     if not script then return nil end
        local ammo = script:FindFirstChild("Ammo")
        if ammo and (ammo:IsA("IntValue") or ammo:IsA("NumberValue")) then return ammo end
        return nil
    end

    local function fireKey()
        pcall(function()
            VirtualInputManager:SendKeyEvent(true,  key, false, game)
            task.wait(0.05)
            VirtualInputManager:SendKeyEvent(false, key, false, game)
        end)
    end

    local function start()
        G.hcAutoReloadActive = true
        if conn then conn:Disconnect() end
        conn = RunService.Heartbeat:Connect(function()
            if not G.hcAutoReloadActive then return end
            if tick() - last < cooldown then return end
            local ammo = getAmmo();              if not ammo then return end
            if ammo.Value > threshold then return end
            last = tick()
            fireKey()
        end)
    end

    local function stop()
        G.hcAutoReloadActive = false
        if conn then conn:Disconnect(); conn = nil end
    end

    local t = makeToggle(start, stop, "hcAutoReloadActive")
    t.setKey = function(k)
        if typeof(k) == "EnumItem" then key = k
        elseif type(k) == "string" then key = Enum.KeyCode[k] or key end
    end
    t.setThreshold = function(n) threshold = tonumber(n) or 0 end
    t.getThreshold = function() return threshold end
    t.setCooldown  = function(n) cooldown = math.clamp(tonumber(n) or 1.5, 0.1, 10) end
    t.getCooldown  = function() return cooldown end
    return t
end)()

-- (HC Ammo.CLIENT auto-sync removed in v1.4.7 - it caused reload
-- slowdown because the game's reload state machine watches CLIENT,
-- and mirroring fresh Value writes into CLIENT interrupted the
-- reload animation. Old listeners from prior script runs will GC
-- once the character respawns and their Ammo instances destruct.)

-- ============================================================
--  GAMES: HOOD CUSTOMS - KNIFE REACH
--  Resizes lplr.Character.Knife.Handle.HITBOX_PART up to MAX (13,13,13).
--  Anything above that triggers HC's anti-cheat. Survives respawn via a
--  Heartbeat loop that re-applies whenever the knife reappears.
-- ============================================================
hook.games.hoodCustoms.knifeReach = (function()
    local DEFAULT = Vector3.new(2.5, 1, 1)
    local MAX     = 13
    local size, visualize = 13, false
    local conn

    local function getHb()
        local function find(p)
            local k = p and p:FindFirstChild("[Knife]")
            if not k then return nil end
            local h = k:FindFirstChild("Handle"); if not h then return nil end
            return h:FindFirstChild("HITBOX_PART")
        end
        return find(lplr:FindFirstChildOfClass("Backpack")) or find(lplr.Character)
    end

    local function start()
        G.hcKnifeReachActive = true
        if conn then conn:Disconnect() end
        conn = RunService.Heartbeat:Connect(function()
            if not G.hcKnifeReachActive then return end
            local hb = getHb(); if not hb then return end
            local target = Vector3.new(size, size, size)
            if hb.Size ~= target then pcall(function() hb.Size = target end) end
            if hb.Transparency ~= 0.9999 then pcall(function() hb.Transparency = 0.9999 end) end
            local hl = hb:FindFirstChild("_kr_hl")
            if visualize then
                if not hl then
                    hl = Instance.new("Highlight")
                    hl.Name             = "_kr_hl"
                    hl.FillTransparency = 1
                    hl.DepthMode        = Enum.HighlightDepthMode.Occluded
                    hl.Parent           = hb
                end
            else
                if hl then hl:Destroy() end
            end
        end)
    end

    local function stop()
        G.hcKnifeReachActive = false
        if conn then conn:Disconnect(); conn = nil end
        local hb = getHb()
        if hb then
            pcall(function() hb.Size = DEFAULT end)
            pcall(function() hb.Transparency = 1 end)
            local hl = hb:FindFirstChild("_kr_hl")
            if hl then hl:Destroy() end
        end
    end

    local t = makeToggle(start, stop, "hcKnifeReachActive")
    t.setSize       = function(n) size = math.clamp(tonumber(n) or MAX, 1, MAX) end
    t.getSize       = function() return size end
    t.maxSize       = MAX
    t.setVisualize  = function(b) visualize = b == true end
    t.getVisualize  = function() return visualize end
    return t
end)()

-- ============================================================
--  GAMES: HOOD CUSTOMS - ANTI-AFK TAG
--  Watches HumanoidRootPart.CharacterAFK (BillboardGui).Enabled.
--  When it goes true the game has flagged you as AFK; we fire
--  MainEvent:FireServer("RequestAFKDisplay", false) to clear it.
--  Survives respawn (re-hooks via CharacterAdded).
-- ============================================================
hook.games.hoodCustoms.antiAfkTag = (function()
    local propConn, charConn

    local function clearOnce()
        local me = getMainEvent()
        if me then pcall(function() me:FireServer("RequestAFKDisplay", false) end) end
    end

    local function hook(char)
        if not char then return end
        local hrp = char:WaitForChild("HumanoidRootPart", 5); if not hrp then return end
        local gui = hrp:WaitForChild("CharacterAFK", 5); if not gui then return end
        if propConn then propConn:Disconnect() end
        if gui.Enabled then
            pcall(function() gui.Enabled = false end)
            clearOnce()
        end
        propConn = gui:GetPropertyChangedSignal("Enabled"):Connect(function()
            if not G.hcAntiAfkTagActive then return end
            if gui.Enabled then
                pcall(function() gui.Enabled = false end)
                clearOnce()
            end
        end)
    end

    local function start()
        -- mutually exclusive with force-AFK tag
        if G.hcForceAfkTagActive and hook.games.hoodCustoms.forceAfkTag then
            pcall(function() hook.games.hoodCustoms.forceAfkTag.stop() end)
        end
        G.hcAntiAfkTagActive = true
        if charConn then charConn:Disconnect() end
        charConn = lplr.CharacterAdded:Connect(function(c)
            if G.hcAntiAfkTagActive then task.spawn(hook, c) end
        end)
        if lplr.Character then task.spawn(hook, lplr.Character) end
    end

    local function stop()
        G.hcAntiAfkTagActive = false
        if propConn then propConn:Disconnect(); propConn = nil end
        if charConn then charConn:Disconnect(); charConn = nil end
    end

    -- always-on by default - but only auto-start in Hood Customs.
    -- Outside HC, hook() does WaitForChild("CharacterAFK", 5) which times
    -- out (5s noise) on every character spawn for no reason.
    local _HC_PLACE_IDS = { [138995385694035] = true, [9825515356] = true }
    if _HC_PLACE_IDS[game.PlaceId] then task.spawn(start) end
    return makeToggle(start, stop, "hcAntiAfkTagActive")
end)()

-- ============================================================
--  GAMES: HOOD CUSTOMS - FORCE AFK TAG
--  Reverse of antiAfkTag: keeps HumanoidRootPart.CharacterAFK
--  (BillboardGui).Enabled = true, and fires
--  MainEvent:FireServer("RequestAFKDisplay", true) so the server
--  also flags you as AFK to other players. Re-asserts whenever
--  anything sets Enabled back to false. Survives respawn.
--  Mutually exclusive with antiAfkTag - turning this on disables
--  the anti tag, and vice versa (the loader handles that wiring).
-- ============================================================
hook.games.hoodCustoms.forceAfkTag = (function()
    local propConn, charConn

    local function setOnce()
        local me = getMainEvent()
        if me then pcall(function() me:FireServer("RequestAFKDisplay", true) end) end
    end

    local function hook(char)
        if not char then return end
        local hrp = char:WaitForChild("HumanoidRootPart", 5); if not hrp then return end
        local gui = hrp:WaitForChild("CharacterAFK", 5); if not gui then return end
        if propConn then propConn:Disconnect() end
        if not gui.Enabled then
            pcall(function() gui.Enabled = true end)
            setOnce()
        end
        propConn = gui:GetPropertyChangedSignal("Enabled"):Connect(function()
            if not G.hcForceAfkTagActive then return end
            if not gui.Enabled then
                pcall(function() gui.Enabled = true end)
                setOnce()
            end
        end)
    end

    local function start()
        -- mutually exclusive with anti-AFK tag
        if G.hcAntiAfkTagActive and hook.games.hoodCustoms.antiAfkTag then
            pcall(function() hook.games.hoodCustoms.antiAfkTag.stop() end)
        end
        G.hcForceAfkTagActive = true
        if charConn then charConn:Disconnect() end
        charConn = lplr.CharacterAdded:Connect(function(c)
            if G.hcForceAfkTagActive then task.spawn(hook, c) end
        end)
        if lplr.Character then task.spawn(hook, lplr.Character) end
    end

    local function stop()
        G.hcForceAfkTagActive = false
        if propConn then propConn:Disconnect(); propConn = nil end
        if charConn then charConn:Disconnect(); charConn = nil end
        -- restore the badge to whatever the server thinks (don't force off
        -- here - antiAfkTag is the explicit "always off" toggle)
    end

    return makeToggle(start, stop, "hcForceAfkTagActive")
end)()

-- HC godmode: built inside an IIFE so all its locals live in the inner
-- function's own register pool - none of them count against the file-
-- top-level chunk's 200-register Luau budget (we're at the limit).
hook.games.hoodCustoms.godmode = (function()
    -- ============================================================
    -- HC godmode = FROZEN EMOTE EXPLOIT.
    --
    -- The limb-detach approach turned out to be unreliable on HC's
    -- current build. This is a much simpler exploit that actually
    -- works: load a specific emote animation, play it, then every
    -- Heartbeat re-set its TimePosition to a specific frame
    -- (freezetime) and AdjustSpeed(0). This locks the character in
    -- the very first pose of the emote, which puts HC's hit-detection
    -- in a state where damage doesn't apply.
    --
    -- Two helpers that keep it solid:
    --   * AnimationPlayed listener: HC plays its own animations on
    --     equip / move / shoot etc. The moment another animation
    --     starts, our frozen track gets blended out and we lose
    --     godmode. So we listen for AnimationPlayed and re-fire the
    --     setup ~20-50ms later (small random jitter so we don't trip
    --     "scripted on every frame" detection).
    --   * CharacterAdded: respawn rebuilds the Humanoid - wait 0.25s
    --     for HC to fully assemble the new rig, then re-fire setup.
    --
    -- Toggle off: stop+destroy the animation track, disconnect both
    -- helpers. Nothing to restore - we never touched joints, welds,
    -- constraints, or anchors. Cleanup is essentially free.
    -- ============================================================
    local EMOTE_ID   = "rbxassetid://70883871260184"
    local FREEZE_T   = 0.1265

    local track, hbConn, animConn, charConn
    local lastArmAt = 0       -- re-arm throttle (HC fires AnimationPlayed many times/sec)
    local lastListenAt = 0    -- listener throttle (don't even schedule redundant task.delays)

    local function getHumanoid()
        local c = lplr.Character
        if not c then return nil end
        return c:FindFirstChildOfClass("Humanoid")
    end

    local function killTrack()
        if hbConn   then hbConn:Disconnect();   hbConn   = nil end
        if animConn then animConn:Disconnect(); animConn = nil end
        if track then
            pcall(function() track:Stop() end)
            pcall(function() track:Destroy() end)
            track = nil
        end
    end

    -- declared forward so animConn can re-call after a delay.
    local arm
    arm = function()
        if not G.hcGmActive then return end
        -- Re-arm throttle. HC fires AnimationPlayed many times per
        -- second (walk, idle, sway, equip ...) and each fire would
        -- otherwise rebuild the track + both connections + the
        -- limb-void setup. Cap to once per 150ms - plenty fast to
        -- re-grab godmode after HC interrupts the emote, cheap
        -- enough that the game doesn't melt.
        local now = tick()
        if now - lastArmAt < 0.15 then return end
        lastArmAt = now

        local hum = getHumanoid()
        if not hum then return end

        killTrack()

        local anim = Instance.new("Animation")
        anim.AnimationId = EMOTE_ID
        local ok, newTrack = pcall(function() return hum:LoadAnimation(anim) end)
        if not ok or not newTrack then return end
        track = newTrack
        pcall(function() track:Play(0, 1, 1) end)

        -- Every Heartbeat: hold the animation at the godmode frame.
        -- AdjustSpeed(0) freezes the play head; setting TimePosition
        -- back to FREEZE_T defends against any external nudge.
        --
        -- Cheap-path: once the track is paused at FREEZE_T, the
        -- per-frame cost is just one TimePosition read + a compare.
        -- We only write when the position has actually drifted -
        -- writing TimePosition forces a full rig re-pose, which is
        -- what was tanking FPS when stacked on the rest of the
        -- executor's load. Same logic for Speed.
        hbConn = RunService.Heartbeat:Connect(function()
            if not G.hcGmActive then killTrack(); return end
            if not track then return end
            local ok, tp = pcall(function() return track.TimePosition end)
            if ok and math.abs(tp - FREEZE_T) > 0.001 then
                pcall(function() track.TimePosition = FREEZE_T end)
            end
            local ok2, sp = pcall(function() return track.Speed end)
            if ok2 and sp ~= 0 then
                pcall(function() track:AdjustSpeed(0) end)
            end
        end)

        -- HC plays its own animations (equip, move, shoot, etc.).
        -- Whenever a NEW animation starts, our track loses priority
        -- and the godmode breaks - so re-arm shortly after.
        --
        -- Throttle the LISTENER itself, not just arm(): without this
        -- we still queue a task.delay() for every fire (30+/sec from
        -- HC), and each scheduled task allocates a closure even if
        -- the eventual arm() call hits the throttle and returns.
        animConn = hum.AnimationPlayed:Connect(function(newAnim)
            if not G.hcGmActive then return end
            if not track or newAnim == track then return end
            local now = tick()
            if now - lastListenAt < 0.1 then return end
            lastListenAt = now
            task.delay(0.02 + math.random() * 0.03, arm)
        end)
    end

    return makeToggle(
        function()
            G.hcGmActive = true
            lastArmAt = 0  -- bypass throttle on first arm
            arm()
            if charConn then charConn:Disconnect() end
            charConn = lplr.CharacterAdded:Connect(function()
                if not G.hcGmActive then return end
                killTrack()
                task.wait(0.25)  -- let HC finish assembling the new rig
                if G.hcGmActive then
                    lastArmAt = 0
                    arm()
                end
            end)
        end,
        function()
            G.hcGmActive = false
            killTrack()
            if charConn then charConn:Disconnect(); charConn = nil end
        end,
        "hcGmActive"
    )
end)()


-- ============================================================
--  GAMES: HOOD CUSTOMS - FORCE HIT  (single-fire, shotgun WIP)
--  On hotkey press, force a hit on the chosen target:
--
--   * SINGLE-FIRE weapons -> direct FireServer("Shoot", payload)
--     with synthetic single-pellet payload (Head as origin,
--     camera-aligned aim, hit on chosen body part). Optional
--     TP-wallbang teleports into LoS, fires, teleports back.
--
--   * SHOTGUNS ([Shotgun] / [Double Barrel] / [Tactical Shotgun]) -
--     synthesizing a payload trips HC's per-shot PRNG check
--     ("attempt on spoofing spread pattern"). Falls back to
--     VirtualInputManager click so the gun fires natively. Pellets
--     land on target via natural cone when silent aim is on. No
--     TP wallbang on this path - silent aim collapsing the cone
--     to 0 spread also trips the pattern check.
--
--  Optional ammo refill writes Tool.Script.Ammo.Value to its
--  observed max each Heartbeat (c-closure style), keeps the gun
--  visually full and ready to click-fire.
-- ============================================================

hook.games.hoodCustoms.forceHit = (function()
    local SHOTGUN_NAMES = {
        ["[Shotgun]"]          = true,
        ["[Double Barrel]"]    = true,
        ["[DoubleBarrel]"]     = true,  -- HC's exact tool name (no space)
        ["[Tactical Shotgun]"] = true,
    }
    local SHOTGUN_PELLETS = {
        ["[Shotgun]"]          = 5,
        ["[Double Barrel]"]    = 5,
        ["[DoubleBarrel]"]     = 5,
        ["[Tactical Shotgun]"] = 5,
    }
    -- Fallback substrings: catches any HC tool whose actual Name differs
    -- from our hardcoded keys (case / spacing / bracket variations).
    -- Without this fuzzy match, isShotgun() returns false and forceHit
    -- routes the shot through fireDirect() which only sends 1 pellet -
    -- the server flags "shotgun fired with 1 pellet" and kicks.
    local SHOTGUN_SUBSTRINGS = { "shotgun", "barrel" }
    local _loggedTools = {}  -- tools we've already logged Tool.Name for

    local target          = nil
    local hitPartName     = "Head"
    local cooldown        = 0.20
    -- shotgun spread strategy
    --   "click"   -> click the mouse, gun fires natively (works, low risk)
    --   "synth"   -> synthesize a 2-section payload (WIP - tries to bypass
    --                the per-shot PRNG check). 2 stacked clusters ~3 studs
    --                apart, sub-stud anti-zero-spread jitter inside each.
    -- shotgunMode used to be "click" vs "synth"; click let the gun's own
    -- script fire via VirtualInputManager. Removed entirely per user
    -- request - fireShoot (the synth path) is the only path now since
    -- the canonical HC Shoot payload it sends doesn't kick.

    -- visual / audio feedback (FireServer doesn't render bullet visuals
    -- because we never hit the gun script, so we fake them locally)
    local tracerEnabled   = true
    local tracerColor     = Color3.fromRGB(0, 255, 80)
    local tracerLifetime  = 0.20
    local tracerThickness = 0.12
    -- Beam visual style. Each name maps to a builder in spawnTracer.
    --   "Standard"  - two-beam halo + white-hot inner with scrolling texture
    --   "Laser"     - single sharp solid beam, no halo, no texture
    --   "Lightning" - segmented jagged beam with electric texture
    --   "Plasma"    - thick pulsing glowing beam
    --   "Thin"      - single thin beam in solid color, no halo
    local tracerStyle     = "Standard"
    -- Trail particles along the beam path (sparkles linger after the shot).
    local trailEnabled    = false
    local hitSoundEnabled = true
    local hitSoundId      = 135698842254153  -- "crit" by default
    local hitSoundVolume  = 1.0
    -- Concurrent-tracer cap. Each tracer spawns a pile of workspace
    -- parts (start/end anchors, beams, impact flash + ring + sparkle
    -- emitters, and up to 12 trail anchors). On fast / auto fire
    -- these stack up unbounded and flood the instance tree, which
    -- is the "random freeze" players hit. We cap how many can be
    -- alive at once; over the cap, a new shot just skips its visual.
    local _activeTracers  = 0
    local MAX_TRACERS     = 10
    -- Minimum seconds between tracer spawns. Even under the
    -- concurrent cap, a high fire rate would still pay the
    -- synchronous part/beam creation burst every shot. This
    -- throttle skips the visual for shots that land within
    -- MIN_TRACER_GAP of the previous one (the bullet still fires).
    local _lastTracerAt   = 0
    local MIN_TRACER_GAP  = 0.05

    local lastFire = 0

    local _RS = game:GetService("ReplicatedStorage")

    local function getEquippedTool()
        local c = lplr.Character
        return c and c:FindFirstChildOfClass("Tool")
    end

    local function isShotgun()
        local t = getEquippedTool()
        if not t then return false end
        if SHOTGUN_NAMES[t.Name] then return true end
        -- substring fallback for unknown naming variations
        local lower = t.Name:lower()
        for _, key in ipairs(SHOTGUN_SUBSTRINGS) do
            if lower:find(key, 1, true) then return true end
        end
        return false
    end

    -- diagnostic: log Tool.Name once per unique tool so the user can see
    -- what HC actually names guns and confirm shotgun detection
    local function logToolOnce()
        local t = getEquippedTool()
        if t and not _loggedTools[t.Name] then
            _loggedTools[t.Name] = true
            print(("[forceHit] equipped: %q  isShotgun=%s"):format(t.Name, tostring(isShotgun())))
        end
    end

    local function getHead()
        local c = lplr.Character
        return c and c:FindFirstChild("Head")
    end

    -- Pretty fake bullet tracer using two layered Beam constraints:
    --   * OUTER beam = wide, semi-transparent halo glow (the user's
    --     chosen tracerColor)
    --   * INNER beam = narrower bright core with a white midpoint
    --     gradient (gives the laser a hot-center feel)
    --   * Width tapers from origin -> hit so it looks like a real
    --     bullet streak (fat at the muzzle, thin at the target)
    --
    -- Stages:
    --   1. Travel: the END attachment animates from origin toward
    --      hitPos over ~40ms so the beam "extends" along the bullet
    --      path
    --   2. Impact: neon ball + PointLight at hit, expands and fades
    --   3. Fade: both beams fade transparency to 1 over tracerLifetime
    --
    -- All local-only.
    local function spawnTracer(origin, hitPos)
        if not tracerEnabled then return end
        local dist = (hitPos - origin).Magnitude
        if dist < 0.5 then return end
        -- anti-freeze gates: skip the visual (not the shot) when
        -- firing too fast or when too many tracers are already alive
        local nowT = tick()
        if nowT - _lastTracerAt < MIN_TRACER_GAP then return end
        if _activeTracers >= MAX_TRACERS then return end
        _lastTracerAt  = nowT
        _activeTracers = _activeTracers + 1
        -- guaranteed release: even if the animation thread early-returns
        -- (parts gc'd, etc), decrement after a safe upper bound so the
        -- counter can never leak and permanently block tracers.
        task.delay(math.max(1.5, tracerLifetime + 1), function()
            _activeTracers = math.max(0, _activeTracers - 1)
        end)

        local dir = (hitPos - origin).Unit

        local function invisAnchor(pos)
            local p = Instance.new("Part")
            p.Anchored     = true
            p.CanCollide   = false
            p.CanTouch     = false
            p.CanQuery     = false
            p.CastShadow   = false
            p.Size         = Vector3.new(0.05, 0.05, 0.05)
            p.Transparency = 1
            p.CFrame       = CFrame.new(pos)
            p.Parent       = workspace
            return p
        end

        local startPart = invisAnchor(origin)
        startPart.Name  = "_fh_tracer_start"
        local endPart   = invisAnchor(origin)  -- starts at origin, animates to hit
        endPart.Name    = "_fh_tracer_end"

        local att0 = Instance.new("Attachment"); att0.Parent = startPart
        local att1 = Instance.new("Attachment"); att1.Parent = endPart

        -- Build the beam(s) according to tracerStyle. Each builder
        -- returns a list of Beam instances so the fade phase can
        -- animate all of them uniformly.
        local beams = {}
        local function mkBeam()
            local b = Instance.new("Beam")
            b.Attachment0 = att0; b.Attachment1 = att1
            b.LightEmission = 1; b.LightInfluence = 0
            b.FaceCamera = true; b.Segments = 1
            b.Parent = startPart
            table.insert(beams, b)
            return b
        end

        if tracerStyle == "Laser" then
            -- single sharp thin beam, full opacity, no texture, no halo
            local b = mkBeam()
            b.Width0 = tracerThickness * 1.2
            b.Width1 = tracerThickness * 1.2
            b.Color  = ColorSequence.new(tracerColor)
            b.Transparency = NumberSequence.new(0)

        elseif tracerStyle == "Thin" then
            -- single thin beam in tracerColor, no halo, no texture
            local b = mkBeam()
            b.Width0 = tracerThickness * 0.6
            b.Width1 = tracerThickness * 0.6
            b.Color  = ColorSequence.new(tracerColor)
            b.Transparency = NumberSequence.new(0.1)

        elseif tracerStyle == "Lightning" then
            -- jagged electric beam with multiple segments + scrolling texture
            local b = mkBeam()
            b.Width0 = tracerThickness * 2.5
            b.Width1 = tracerThickness * 2.5
            b.Segments = math.max(8, math.floor(dist / 4))
            b.CurveSize0 = 1.5; b.CurveSize1 = -1.5
            b.Color = ColorSequence.new(tracerColor)
            b.Transparency = NumberSequence.new(0.1)
            pcall(function()
                b.Texture = "rbxassetid://446111271"
                b.TextureMode = Enum.TextureMode.Wrap
                b.TextureLength = 1
                b.TextureSpeed = 15
            end)

        elseif tracerStyle == "Plasma" then
            -- thick pulsing glow, no inner core
            local b = mkBeam()
            b.Width0 = tracerThickness * 7
            b.Width1 = tracerThickness * 5
            b.Color = ColorSequence.new(tracerColor)
            b.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0,   0.4),
                NumberSequenceKeypoint.new(0.5, 0.15),
                NumberSequenceKeypoint.new(1,   0.4),
            })
            pcall(function()
                b.Texture = "rbxassetid://1837228550"  -- soft glow
                b.TextureMode = Enum.TextureMode.Stretch
            end)

        else
            -- "Standard" - outer halo + inner white-hot core w/ scrolling texture
            local outer = mkBeam()
            outer.Width0 = tracerThickness * 5
            outer.Width1 = tracerThickness * 4
            outer.Color  = ColorSequence.new(tracerColor)
            outer.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0,   0.55),
                NumberSequenceKeypoint.new(0.5, 0.35),
                NumberSequenceKeypoint.new(1,   0.55),
            })
            local inner = mkBeam()
            inner.Width0 = tracerThickness * 1.8
            inner.Width1 = tracerThickness * 1.2
            inner.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0,   tracerColor),
                ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
                ColorSequenceKeypoint.new(1,   tracerColor),
            })
            inner.Transparency = NumberSequence.new(0.05)
            pcall(function()
                inner.Texture = "rbxassetid://446111271"
                inner.TextureMode = Enum.TextureMode.Wrap
                inner.TextureLength = 6
                inner.TextureSpeed = 8
            end)
        end

        -- TRAIL PARTICLES: sparkles along the bullet path that linger
        -- ~500ms. Anchored midpoint parts each emit once.
        if trailEnabled then
            local TRAIL_PARTS = math.clamp(math.floor(dist / 10), 2, 6)
            task.spawn(function()
                for i = 1, TRAIL_PARTS do
                    local pos = origin + dir * (dist * (i / TRAIL_PARTS))
                    local anchor = invisAnchor(pos)
                    anchor.Name = "_fh_tracer_trail"
                    local att = Instance.new("Attachment", anchor)
                    local pe = Instance.new("ParticleEmitter")
                    pe.Texture = "rbxassetid://241876428"
                    pe.LightEmission = 1
                    pe.Color = ColorSequence.new(tracerColor)
                    pe.Size = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 0.25),
                        NumberSequenceKeypoint.new(1, 0),
                    })
                    pe.Transparency = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 0.2),
                        NumberSequenceKeypoint.new(1, 1),
                    })
                    pe.Lifetime = NumberRange.new(0.3, 0.5)
                    pe.Rate = 0
                    pe.Speed = NumberRange.new(0.5, 1.5)
                    pe.SpreadAngle = Vector2.new(180, 180)
                    pe.Parent = att
                    pe:Emit(3)
                    task.delay(0.6, function() if anchor.Parent then anchor:Destroy() end end)
                end
            end)
        end

        task.spawn(function()
            -- (1) travel: extend end attachment from origin -> hit.
            -- A bit longer than before (60ms) so the eye can actually
            -- track the beam shoot out rather than seeing it pop in.
            local TRAVEL_STEPS    = 8
            local TRAVEL_DURATION = 0.06
            for i = 1, TRAVEL_STEPS do
                task.wait(TRAVEL_DURATION / TRAVEL_STEPS)
                if not startPart.Parent then return end
                endPart.CFrame = CFrame.new(origin + dir * (dist * (i / TRAVEL_STEPS)))
            end
            if not startPart.Parent then return end
            endPart.CFrame = CFrame.new(hitPos)

            -- (2) impact: bright neon ball, expanding shockwave ring,
            --     and a sparkle particle burst.
            local flash = invisAnchor(hitPos)
            flash.Transparency = 0
            flash.Material     = Enum.Material.Neon
            flash.Color        = tracerColor
            flash.Shape        = Enum.PartType.Ball
            flash.Size         = Vector3.new(0.6, 0.6, 0.6)
            flash.Name         = "_fh_tracer_flash"
            local light = Instance.new("PointLight")
            light.Color      = tracerColor
            light.Brightness = 5
            light.Range      = 10
            light.Parent     = flash

            -- shockwave ring (a thin disc that expands outward)
            local ring = Instance.new("Part")
            ring.Anchored=true; ring.CanCollide=false; ring.CanTouch=false; ring.CanQuery=false; ring.CastShadow=false
            ring.Material = Enum.Material.Neon
            ring.Shape    = Enum.PartType.Cylinder
            ring.Color    = tracerColor
            ring.Size     = Vector3.new(0.05, 0.5, 0.5)
            ring.Transparency = 0.3
            -- orient ring perpendicular to the bullet path
            ring.CFrame   = CFrame.lookAt(hitPos, hitPos + dir) * CFrame.Angles(0, math.rad(90), 0)
            ring.Parent   = workspace
            ring.Name     = "_fh_tracer_ring"

            -- sparkle particle burst via an Attachment+ParticleEmitter
            local sparkAtt = Instance.new("Attachment", flash)
            local sparks = Instance.new("ParticleEmitter")
            sparks.Texture          = "rbxassetid://241876428"  -- soft glow
            sparks.LightEmission    = 1
            sparks.Color            = ColorSequence.new(tracerColor)
            sparks.Size             = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.4),
                NumberSequenceKeypoint.new(1, 0)
            })
            sparks.Transparency     = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(1, 1)
            })
            sparks.Lifetime         = NumberRange.new(0.15, 0.35)
            sparks.Rate             = 0
            sparks.Speed            = NumberRange.new(8, 14)
            sparks.SpreadAngle      = Vector2.new(180, 180)
            sparks.Parent           = sparkAtt
            sparks:Emit(18)

            task.spawn(function()
                local FLASH_STEPS    = 10
                local FLASH_DURATION = 0.22
                for i = 1, FLASH_STEPS do
                    task.wait(FLASH_DURATION / FLASH_STEPS)
                    if not flash.Parent then return end
                    local p = i / FLASH_STEPS
                    local s = 0.6 + p * 2.6
                    flash.Size         = Vector3.new(s, s, s)
                    flash.Transparency = p
                    light.Brightness   = 5 * (1 - p)
                    -- shockwave ring expands faster than the ball
                    if ring.Parent then
                        local r = 0.5 + p * 4.5
                        ring.Size = Vector3.new(0.05, r, r)
                        ring.Transparency = 0.3 + (1 - 0.3) * p
                    end
                end
                if flash.Parent then flash:Destroy() end
                if ring.Parent  then ring:Destroy()  end
            end)

            -- (3) fade all beams uniformly over tracerLifetime
            local FADE_STEPS = 8
            for i = 1, FADE_STEPS do
                task.wait(tracerLifetime / FADE_STEPS)
                if not startPart.Parent then return end
                local p = i / FADE_STEPS
                for _, b in ipairs(beams) do
                    if b.Parent then
                        b.Transparency = NumberSequence.new(p)
                    end
                end
            end
            if startPart.Parent then startPart:Destroy() end
            if endPart.Parent   then endPart:Destroy()   end
        end)
    end

    -- play the configured hit sound at the target's position. Local-only
    -- (parented to PlayerGui so distance-based attenuation doesn't fade
    -- it when we're far from the target). Auto-destroys after playback.
    local function playHitSound()
        if not hitSoundEnabled then return end
        if not hitSoundId or hitSoundId == 0 then return end
        local pg = lplr:FindFirstChildOfClass("PlayerGui")
        local s = Instance.new("Sound")
        s.SoundId = "rbxassetid://" .. tostring(hitSoundId)
        s.Volume  = math.clamp(hitSoundVolume, 0, 5)
        s.Parent  = pg or workspace
        s:Play()
        task.delay(5, function() if s and s.Parent then s:Destroy() end end)
    end

    -- Canonical HC client-side Shoot payload, verified against a
    -- working reference implementation. pelletCount identical entries
    -- all referencing the SAME target part, with:
    --   origin = local player's HRP.Position
    --   aim    = local player's HRP.Position  (yes, identical to origin)
    --   stamp  = workspace:GetServerTimeNow()
    -- No MainFunction:InvokeServer("GunCheck") follow-up - that extra
    -- remote call was part of what was tripping HC's anti-cheat. The
    -- "Normal" field is set to the head position (NOT a unit vector);
    -- the reference impl does this and the server accepts it, so we
    -- match exactly rather than reasoning about why.
    local function fireShoot(part, pelletCount)
        if not part then return false end
        local me = _RS:FindFirstChild("MainEvent")
        if not me then return false end
        local c = lplr.Character
        local root = c and c:FindFirstChild("HumanoidRootPart")
        if not root then return false end
        local hitPos  = part.Position
        local hits    = table.create(pelletCount)
        local targets = table.create(pelletCount)
        for i = 1, pelletCount do
            hits[i]    = { Normal = hitPos, Instance = part, Position = hitPos }
            targets[i] = { thePart = part, theOffset = Vector3.zero }
        end
        local payload = { hits, targets, root.Position, root.Position, workspace:GetServerTimeNow() }
        return pcall(function() me:FireServer("Shoot", payload) end)
    end
    -- Legacy single-shot wrapper kept for non-shotgun call sites
    local function fireDirect(part)
        return fireShoot(part, 1)
    end

    -- Resolve the gun's actual muzzle position. HC's anti-cheat compares
    -- packet origin against the equipped tool's barrel position; using
    -- our head's position made every shot look like a head-mounted gun.
    -- Falls back to head if no tool / handle.
    local function getMuzzlePos()
        local c = lplr.Character
        if not c then return nil end
        local tool = c:FindFirstChildOfClass("Tool")
        if tool then
            local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
            if handle then
                -- attachments named Muzzle/Tip take precedence; some HC guns
                -- have a "Muzzle" Attachment on the Handle
                for _, a in ipairs(handle:GetChildren()) do
                    if a:IsA("Attachment") and (a.Name == "Muzzle" or a.Name == "Tip") then
                        return a.WorldPosition
                    end
                end
                return handle.Position
            end
        end
        local h = getHead(); return h and h.Position or nil
    end

    -- shotgun synth path (v11): TWO-PART V-SHAPE.
    -- User wants pellets spread across TWO body parts forming a V:
    --   - partA (UpperTorso) pellets on a line angled +30deg from horiz
    --   - partB (LowerTorso) pellets on a line angled -30deg from horiz
    -- Together they form a chevron / V pattern when viewed from camera.
    -- partA is the `part` passed in (already UpperTorso, set by fireOnce);
    -- partB is sibling LowerTorso (falls back to HumanoidRootPart if
    -- LowerTorso doesn't exist on the rig).
    --
    -- The line on each part is in WORLD-horizontal direction, rotated
    -- by +-LINE_ANGLE around the face's outward normal. Each line has
    -- its own LINE_HALF_LEN range; per-pellet position is random along
    -- the line + tiny perpendicular jitter.
    local LINE_HALF_LEN = 0.28   -- shorter than v10 so 2 lines fit cleanly
    local LINE_PERP_JIT = 0.02
    local LINE_ANGLE_DEG = 30    -- arms of the V at +-30deg from horiz

    -- helper: generate `count` pellet entries on `bp` at line angle `angDeg`.
    -- Appends into `hits` and `targets` starting at index `baseIdx + 1`.
    local function _vGenOnPart(bp, count, angDeg, origin, hits, targets, baseIdx)
        local sz = bp.Size
        local toLocal = bp.CFrame:VectorToObjectSpace(origin - bp.Position)
        local ax, ay, az = math.abs(toLocal.X), math.abs(toLocal.Y), math.abs(toLocal.Z)
        local faceIdx, faceSign
        if ax >= ay and ax >= az then
            faceIdx, faceSign = 1, (toLocal.X >= 0) and 1 or -1
        elseif ay >= az then
            faceIdx, faceSign = 2, (toLocal.Y >= 0) and 1 or -1
        else
            faceIdx, faceSign = 3, (toLocal.Z >= 0) and 1 or -1
        end

        local LOCAL_AXES = {
            Vector3.new(1, 0, 0),
            Vector3.new(0, 1, 0),
            Vector3.new(0, 0, 1),
        }
        local FACE_INPLANE = {
            [1] = { 2, 3 },
            [2] = { 1, 3 },
            [3] = { 1, 2 },
        }
        local axA, axB = FACE_INPLANE[faceIdx][1], FACE_INPLANE[faceIdx][2]
        local worldAxA = bp.CFrame:VectorToWorldSpace(LOCAL_AXES[axA])
        local worldAxB = bp.CFrame:VectorToWorldSpace(LOCAL_AXES[axB])
        -- horiz = smaller |Y|, vert = larger |Y|
        local horizIdx, vertIdx
        if math.abs(worldAxA.Y) <= math.abs(worldAxB.Y) then
            horizIdx, vertIdx = axA, axB
        else
            horizIdx, vertIdx = axB, axA
        end
        local horizVec = LOCAL_AXES[horizIdx]
        local vertVec  = LOCAL_AXES[vertIdx]

        -- line direction in (horiz, vert) plane, rotated by angDeg
        local rad = math.rad(angDeg)
        local lineH, lineV = math.cos(rad), math.sin(rad)
        local perpH, perpV = -lineV, lineH

        local faceSize = ({sz.X, sz.Y, sz.Z})[faceIdx]
        local faceOff  = LOCAL_AXES[faceIdx] * (faceSize * 0.5 * faceSign)
        local worldN   = bp.CFrame:VectorToWorldSpace(LOCAL_AXES[faceIdx] * faceSign)

        local ts = table.create(count)
        for i = 1, count do
            ts[i] = (math.random() * 2 - 1) * LINE_HALF_LEN
        end
        table.sort(ts)
        for i = 1, count do
            local t = ts[i]
            local p = (math.random() * 2 - 1) * LINE_PERP_JIT
            local h = t * lineH + p * perpH
            local v = t * lineV + p * perpV
            local off = faceOff + horizVec * h + vertVec * v
            local pos = bp.CFrame:PointToWorldSpace(off)
            local idx = baseIdx + i
            hits[idx]    = { Normal = worldN, Instance = bp, Position = pos }
            targets[idx] = { thePart = bp, theOffset = off }
        end
    end

    -- Shotgun fire path: just routes to fireShoot with the gun's pellet
    -- count. The old V-pattern / barrel-origin / centroid-aim synth was
    -- what HC anti-cheat was kicking on. Reference impl sends N identical
    -- pellets all at the same part, and HC accepts it.
    local function fireShotgunSynth(part, pelletCount)
        return fireShoot(part, pelletCount or 5)
    end

    -- pick whichever target is most current. Ragebot's target auto-switches
    -- with locks/closest/mouse - we prefer it. Fall back to a manually-set
    -- target if ragebot has none.
    local function currentTarget()
        if rbGetTarget then
            local p = rbGetTarget()
            if p and p.Parent then return p end
        end
        if target and target.Parent then return target end
        return nil
    end

    -- like getTargetMainPart() but uses currentTarget() instead of `target`
    local function getCurrentTargetPart()
        local p = currentTarget(); if not p or not p.Character then return nil end
        local sp = p.Character:FindFirstChild("SpecialParts") or p.Character
        return sp:FindFirstChild(hitPartName)
            or sp:FindFirstChild("HumanoidRootPart")
            or sp:FindFirstChild("Head")
    end

    -- self-knock check: refuse to fire while we're K.O. so we don't
    -- waste shots / trip "shooting while knocked" detection
    local function selfIsKnocked()
        if hook.games and hook.games.hoodCustoms and hook.games.hoodCustoms.isKnocked then
            local ok, knocked = pcall(hook.games.hoodCustoms.isKnocked, lplr)
            if ok and knocked then return true end
        end
        return false
    end

    -- ============================================================
    --  Event-driven FX watchers
    -- ============================================================
    --  The old "snapshot value, wait 150ms, compare" approach was
    --  racy: if multiple shots are in flight, the second shot's
    --  snapshot captures the post-first-shot value, so when its
    --  delayed check fires the value LOOKS unchanged and we silently
    --  miss the second tracer / sound.
    --
    --  Event-driven: maintain a watcher on the relevant signal
    --  (Ammo.Value or Humanoid.HealthChanged). Every individual
    --  decrement event fires the FX exactly once, gated by "we
    --  fired within the last 0.5s" so unrelated damage (other
    --  players shooting the same target) doesn't trigger.
    -- ============================================================

    -- last-fire bookkeeping (read by the watchers when they fire)
    local _lastFireOrigin, _lastFireHit
    local _lastFireForFx = 0
    local FX_FIRE_WINDOW = 0.5  -- seconds after fire that a damage / ammo event can claim

    -- find first Tool in Character or Backpack that has a Script.Ammo IntValue
    local function findCurrentAmmo()
        local function pull(parent)
            if not parent then return nil end
            for _, tool in ipairs(parent:GetChildren()) do
                if tool:IsA("Tool") then
                    local scr = tool:FindFirstChild("Script")
                    if scr then
                        local av = scr:FindFirstChild("Ammo")
                        if av and (av:IsA("IntValue") or av:IsA("NumberValue")) then
                            return av
                        end
                    end
                end
            end
            return nil
        end
        return pull(lplr.Character) or pull(lplr:FindFirstChild("Backpack"))
    end

    -- ammo watcher: each Value-decrease event spawns ONE tracer using
    -- the stashed origin/hit from the most recent fire (if within the
    -- fire window). Consumes the stash so multiple decrements without
    -- another fire don't all draw the same tracer.
    local _watchedAmmo, _watchedAmmoConn, _watchedAmmoLast
    local function ensureAmmoWatch()
        local av = findCurrentAmmo()
        if av == _watchedAmmo then return end
        if _watchedAmmoConn then _watchedAmmoConn:Disconnect(); _watchedAmmoConn = nil end
        _watchedAmmo = av
        if not av then return end
        _watchedAmmoLast = av.Value
        _watchedAmmoConn = av:GetPropertyChangedSignal("Value"):Connect(function()
            local newV = av.Value
            local old  = _watchedAmmoLast
            _watchedAmmoLast = newV
            if old and newV < old
                and _lastFireOrigin
                and (tick() - _lastFireForFx < FX_FIRE_WINDOW) then
                spawnTracer(_lastFireOrigin, _lastFireHit)
                _lastFireOrigin, _lastFireHit = nil, nil  -- consume
            end
        end)
    end

    -- target-humanoid watcher: each HealthChanged with health < lastHealth
    -- plays ONE hit sound (gated by recent fire). Re-attaches when the
    -- target changes.
    local _watchedHum, _watchedHumConn, _watchedHumLast
    local function ensureHumWatch()
        local plr = currentTarget()
        local hum = plr and plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
        if hum == _watchedHum then return end
        if _watchedHumConn then _watchedHumConn:Disconnect(); _watchedHumConn = nil end
        _watchedHum = hum
        if not hum then return end
        _watchedHumLast = hum.Health
        _watchedHumConn = hum.HealthChanged:Connect(function(newHP)
            local old = _watchedHumLast
            _watchedHumLast = newHP
            if old and newHP < old and (tick() - _lastFireForFx < FX_FIRE_WINDOW) then
                playHitSound()
            end
        end)
    end

    local function fireOnce()
        if tick() - lastFire < cooldown then return end
        if selfIsKnocked() then return end
        local part = getCurrentTargetPart(); if not part then return end

        -- diagnostic so the user can see if shotgun detection actually matches
        logToolOnce()

        local headPart = getHead()
        local origin   = headPart and headPart.Position
        local shotgun  = isShotgun()
        local tool     = getEquippedTool()
        -- pellet count: explicit table lookup, otherwise default to 5 for
        -- anything substring-matched as a shotgun, otherwise 1
        local pellets
        if shotgun then
            pellets = (tool and SHOTGUN_PELLETS[tool.Name]) or 5
        else
            pellets = 1
        end

        -- For SHOTGUNS, override the target body part to ALWAYS be the
        -- torso, regardless of what hitPart the user picked. The hitPart
        -- dropdown still controls fireDirect (revolvers / pistols).
        -- Rationale: shotguns naturally land their pellet line on a
        -- large flat area; the torso is the largest, most consistent
        -- target. Head-targeting shotgun shots produced 200 dmg per
        -- shot which trips the per-shot damage cap.
        if shotgun then
            local sp = part.Parent
            if sp and sp.Name == "SpecialParts" then
                local torso = sp:FindFirstChild("UpperTorso")
                           or sp:FindFirstChild("Torso")
                           or sp:FindFirstChild("LowerTorso")
                           or sp:FindFirstChild("HumanoidRootPart")
                if torso and torso:IsA("BasePart") then
                    part = torso
                end
            end
        end

        local fired = false
        if shotgun then
            if fireShotgunSynth(part, pellets) then fired = true end
        else
            if fireDirect(part) then fired = true end
        end

        if fired then
            lastFire = tick()
            -- Stash this fire's origin/hit so the ammo watcher can
            -- consume them on the next decrement event, and bump the
            -- fire-window timestamp so both watchers consider this a
            -- recent fire for FX-gating purposes.
            _lastFireOrigin = origin
            _lastFireHit    = part.Position
            _lastFireForFx  = tick()
            -- Make sure watchers are attached to the current ammo /
            -- target. Cheap when nothing changed (refs match).
            ensureAmmoWatch()
            ensureHumWatch()
        end
    end

    -- ============================================================
    --  Fake ammo HUD
    -- ============================================================
    --  A small rounded panel in the bottom-right (above the real
    --  ammo counter) showing "Ammo / MaxAmmo" read straight off
    --  Tool.Script.Ammo + Tool.Script.MaxAmmo. Sub-label says
    --  "(forcehit ammo)" so it's obvious it's the cheat's view of
    --  the true ammo, not the game's CLIENT counter (which would
    --  otherwise stay stale after every forceHit shot).
    --
    --  Only shown while G.hcForceHitActive. Created on start(),
    --  destroyed on stop().
    -- ============================================================
    local hudGui, hudConn

    local function findAmmoPair()
        -- Only check Character — i.e. the tool the player currently has
        -- equipped. If nothing's equipped (no Tool under Character), we
        -- return nil so the HUD hides itself. Backpack tools are
        -- intentionally ignored so the panel disappears the moment the
        -- gun is unequipped instead of lingering with stale Backpack
        -- numbers.
        local char = lplr.Character
        if not char then return nil, nil end
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") then
                local scr = tool:FindFirstChild("Script")
                if scr then
                    local av = scr:FindFirstChild("Ammo")
                    if av and (av:IsA("IntValue") or av:IsA("NumberValue")) then
                        local mv = scr:FindFirstChild("MaxAmmo")
                        local maxV = mv and (mv:IsA("IntValue") or mv:IsA("NumberValue")) and mv.Value or nil
                        return av.Value, maxV
                    end
                end
            end
        end
        return nil, nil
    end

    local function hudDestroy()
        if hudConn then hudConn:Disconnect(); hudConn = nil end
        if hudGui  then pcall(function() hudGui:Destroy() end); hudGui = nil end
    end

    local function hudCreate()
        if hudGui then return end
        hudGui = Instance.new("ScreenGui")
        hudGui.Name             = "_fh_ammo_hud"
        hudGui.ResetOnSpawn     = false
        hudGui.IgnoreGuiInset   = true
        hudGui.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
        -- prefer CoreGui (CoreGui survives respawn AND can't be wiped
        -- by the game), fall back to PlayerGui
        local parented = pcall(function() hudGui.Parent = game:GetService("CoreGui") end)
        if not parented or not hudGui.Parent then
            hudGui.Parent = lplr:WaitForChild("PlayerGui")
        end

        local frame = Instance.new("Frame")
        frame.Name                  = "Bg"
        frame.Size                  = UDim2.fromOffset(140, 60)
        -- anchor to bottom-right, slightly above the game's ammo counter
        frame.AnchorPoint           = Vector2.new(1, 1)
        frame.Position              = UDim2.new(1, -20, 1, -100)
        frame.BackgroundColor3      = Color3.fromRGB(15, 15, 15)
        frame.BackgroundTransparency = 0.35
        frame.BorderSizePixel       = 0
        frame.Parent                = hudGui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent       = frame

        local stroke = Instance.new("UIStroke")
        stroke.Color        = Color3.fromRGB(80, 80, 80)
        stroke.Thickness    = 1
        stroke.Transparency = 0.4
        stroke.Parent       = frame

        local mainLbl = Instance.new("TextLabel")
        mainLbl.Name                   = "Ammo"
        mainLbl.Size                   = UDim2.new(1, -8, 0, 32)
        mainLbl.Position               = UDim2.new(0, 4, 0, 4)
        mainLbl.BackgroundTransparency = 1
        mainLbl.Text                   = "0 / 0"
        mainLbl.TextColor3             = Color3.fromRGB(255, 255, 255)
        mainLbl.TextStrokeTransparency = 0.5
        mainLbl.TextSize               = 24
        mainLbl.Font                   = Enum.Font.GothamBold
        mainLbl.Parent                 = frame

        local subLbl = Instance.new("TextLabel")
        subLbl.Name                   = "Sub"
        subLbl.Size                   = UDim2.new(1, -8, 0, 16)
        subLbl.Position               = UDim2.new(0, 4, 0, 38)
        subLbl.BackgroundTransparency = 1
        subLbl.Text                   = "(forcehit ammo)"
        subLbl.TextColor3             = Color3.fromRGB(180, 180, 180)
        subLbl.TextSize               = 12
        subLbl.Font                   = Enum.Font.Gotham
        subLbl.Parent                 = frame

        if hudConn then hudConn:Disconnect() end
        hudConn = RunService.Heartbeat:Connect(function()
            if not G.hcForceHitActive or not hudGui then return end
            local a, m = findAmmoPair()
            if a then
                mainLbl.Text  = tostring(a) .. " / " .. tostring(m or "?")
                frame.Visible = true
            else
                frame.Visible = false
            end
        end)
    end

    local function start()
        G.hcForceHitActive = true
        hudCreate()
    end

    local function stop()
        G.hcForceHitActive = false
        hudDestroy()
    end

    local t = makeToggle(start, stop, "hcForceHitActive")
    -- public hotkey trigger - the loader's bindFireKey calls this
    t.fire          = function()
        if not G.hcForceHitActive then return end
        fireOnce()
    end
    t.setTarget     = function(plr) target = plr end
    t.getTarget     = function() return target end
    t.setHitPart    = function(name) hitPartName = name or "Head" end
    t.getHitPart    = function() return hitPartName end
    t.setCooldown   = function(n) cooldown = math.max(0, tonumber(n) or 0.2) end
    -- setShotgunMode / getShotgunMode removed - there's only one path now
    -- (synth, the canonical-payload direct FireServer). Kept as no-op
    -- stubs so the loader doesn't crash if it still tries to call them.
    t.setShotgunMode = function() end
    t.getShotgunMode = function() return "synth" end
    -- tracer + hit sound
    t.setTracerEnabled  = function(v) tracerEnabled = v == true end
    t.setTracerColor    = function(c) if typeof(c) == "Color3" then tracerColor = c end end
    t.setTracerLifetime = function(n) tracerLifetime = math.clamp(tonumber(n) or 0.2, 0.05, 2) end
    t.setTracerThickness = function(n) tracerThickness = math.clamp(tonumber(n) or 0.12, 0.02, 1) end
    t.setTracerStyle    = function(s) tracerStyle = tostring(s or "Standard") end
    t.getTracerStyle    = function() return tracerStyle end
    t.setTrailEnabled   = function(v) trailEnabled = v == true end
    t.setHitSoundEnabled = function(v) hitSoundEnabled = v == true end
    t.setHitSoundId      = function(id) hitSoundId = tonumber(id) or 0 end
    t.setHitSoundVolume  = function(n) hitSoundVolume = math.clamp(tonumber(n) or 1, 0, 5) end
    t.isShotgunEquipped = isShotgun
    return t
end)()

-- ============================================================
--  HOOD CUSTOMS: KNIFE BOT (attach + 1Hz stab + auto-equip)
-- ============================================================
--  Two independent toggles bundled under hook.games.hoodCustoms.knifeBot:
--
--    attach.start() / .stop() / .setDistance(n)
--      Each Heartbeat, snap HRP to a position `distance` studs
--      behind the ragebot's current target. Once per second, fire
--      a synthetic MouseButton1 click via VirtualInputManager so the
--      equipped knife swings at the target.
--
--    autoEquip.start() / .stop()
--      Each CharacterAdded + once on start, equip the "[Knife]" tool
--      from the player's Backpack. Re-equips on respawn.
--
--  Built as an IIFE so all the local helpers stay scoped here and
--  don't eat top-level register slots (chunk is at Luau's 200-local
--  limit).
-- ============================================================
hook.games.hoodCustoms.knifeBot = (function()
    local KNIFE_NAME = "[Knife]"

    -- -------- attach --------
    local attachDistance = 3      -- studs from target
    local clickInterval  = 0.6    -- seconds between auto-clicks
    local orbitActive    = false  -- rotate around target while attached
    local orbitSpeed     = 180    -- degrees / second
    local orbitAngle     = 0      -- internal accumulator
    local attachHbConn, attachClickThread
    local attachActive   = false

    local function getTargetHRP()
        if not rbGetTarget then return nil end
        local plr = rbGetTarget()
        if not plr or plr == lplr then return nil end
        local char = plr.Character
        return char and char:FindFirstChild("HumanoidRootPart")
    end

    -- forcibly disable ragebot autoshoot + HC forcehit so they don't
    -- fire alongside the knife. Setting RageSettings.AutoShoot = false
    -- + G.hcForceHitActive = false here is the engine-level mute;
    -- the loader also flips the UI toggles off so the GUI matches.
    local function muteRangedAutos()
        pcall(function()
            if hook.ragebot and hook.ragebot.setAutoShoot then hook.ragebot.setAutoShoot(false) end
        end)
        G.hcForceHitActive = false
        pcall(function()
            if hook.games and hook.games.hoodCustoms and hook.games.hoodCustoms.forceHit then
                hook.games.hoodCustoms.forceHit.stop()
            end
        end)
    end

    local function attachStart()
        if attachActive then return end
        attachActive = true
        G.hcKnifeAttachActive = true
        orbitAngle = 0
        muteRangedAutos()

        if attachHbConn then attachHbConn:Disconnect() end
        attachHbConn = RunService.Heartbeat:Connect(function(dt)
            if not attachActive then return end
            -- keep ragebot autoshoot + forcehit muted every frame in
            -- case something else flips them back on
            muteRangedAutos()

            local c = lplr.Character
            local hrp = c and c:FindFirstChild("HumanoidRootPart")
            if not hrp then return end
            local tHrp = getTargetHRP()
            if not tHrp then return end

            local pos
            if orbitActive then
                orbitAngle = (orbitAngle + orbitSpeed * dt) % 360
                local rad = math.rad(orbitAngle)
                pos = tHrp.Position + Vector3.new(math.cos(rad), 0, math.sin(rad)) * attachDistance
            else
                -- snap behind the target (so the knife swing arc lands)
                local forward = tHrp.CFrame.LookVector
                pos = tHrp.Position - forward * attachDistance
            end
            -- guard against a degenerate look CFrame (pos == target) which
            -- produces NaN and can hard-freeze the client
            if (pos - tHrp.Position).Magnitude >= 0.5 then
                pcall(function()
                    hrp.CFrame = CFrame.new(pos, tHrp.Position)
                end)
            end
        end)

        if attachClickThread then pcall(task.cancel, attachClickThread) end
        attachClickThread = task.spawn(function()
            while attachActive do
                local tHrp = getTargetHRP()
                if tHrp then
                    pcall(function()
                        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true,  game, 0)
                        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
                    end)
                end
                -- read the live value so slider changes take effect
                -- immediately without needing a toggle off/on
                task.wait(clickInterval)
            end
        end)
    end

    local function attachStop()
        attachActive = false
        G.hcKnifeAttachActive = false
        if attachHbConn then attachHbConn:Disconnect(); attachHbConn = nil end
        if attachClickThread then pcall(task.cancel, attachClickThread); attachClickThread = nil end
    end

    -- -------- auto-equip --------
    local autoEquipActive = false
    local autoEquipCharConn, autoEquipThread

    local function tryEquipKnife()
        local char = lplr.Character; if not char then return false end
        local hum  = char:FindFirstChildOfClass("Humanoid"); if not hum then return false end
        if char:FindFirstChild(KNIFE_NAME) then return true end
        local bp = lplr:FindFirstChild("Backpack")
        if not bp then return false end
        local tool = bp:FindFirstChild(KNIFE_NAME)
        if not tool or not tool:IsA("Tool") then return false end
        pcall(function() hum:EquipTool(tool) end)
        return true
    end

    local function autoEquipStart()
        if autoEquipActive then return end
        autoEquipActive = true
        G.hcKnifeAutoEquipActive = true
        tryEquipKnife()

        if autoEquipCharConn then autoEquipCharConn:Disconnect() end
        autoEquipCharConn = lplr.CharacterAdded:Connect(function()
            if not autoEquipActive then return end
            local bp = lplr:WaitForChild("Backpack", 10)
            if bp then bp:WaitForChild(KNIFE_NAME, 10) end
            if autoEquipActive then tryEquipKnife() end
        end)

        -- aggressive re-check: every 0.2s so a brief unequip
        -- (tool switch, animation interrupt) is corrected fast.
        if autoEquipThread then pcall(task.cancel, autoEquipThread) end
        autoEquipThread = task.spawn(function()
            while autoEquipActive do
                task.wait(0.2)
                if autoEquipActive then tryEquipKnife() end
            end
        end)
    end

    local function autoEquipStop()
        autoEquipActive = false
        G.hcKnifeAutoEquipActive = false
        if autoEquipCharConn then autoEquipCharConn:Disconnect(); autoEquipCharConn = nil end
        if autoEquipThread then pcall(task.cancel, autoEquipThread); autoEquipThread = nil end
    end

    return {
        attach = {
            start            = attachStart,
            stop             = attachStop,
            isActive         = function() return attachActive end,
            setDistance      = function(n) attachDistance = math.clamp(tonumber(n) or 3, 0, 50) end,
            getDistance      = function() return attachDistance end,
            setClickInterval = function(n) clickInterval = math.clamp(tonumber(n) or 0.6, 0.05, 5) end,
            getClickInterval = function() return clickInterval end,
            setOrbit         = function(v) orbitActive = v == true end,
            getOrbit         = function() return orbitActive end,
            setOrbitSpeed    = function(n) orbitSpeed = math.clamp(tonumber(n) or 180, 0, 720) end,
            getOrbitSpeed    = function() return orbitSpeed end,
        },
        autoEquip = {
            start    = autoEquipStart,
            stop     = autoEquipStop,
            isActive = function() return autoEquipActive end,
        },
    }
end)()

end

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

-- upright teleport (won't fall over onto knocked players) + desync-aware.
-- This clears ragdoll/sit and notifies desync -- relatively heavy, so use it
-- ONCE per teleport, never in a per-frame loop.
local uprightTp = hook.uprightTp or function(_, h, pos, face)
    if h then h.CFrame = CFrame.new(pos, pos + Vector3.new((face and face.X) or 0, 0, (face and face.Z) or -1)) end
end

-- lightweight upright snap for tight per-frame loops: sets an upright CFrame
-- and zeroes velocity only. Running the full uprightTp (humanoid-state spam +
-- WaitForChild + task.delay + desync-notify) every frame was freezing Bring.
local function snapUprightTo(h, pos, face)
    if not h then return end
    local horiz = face and Vector3.new(face.X, 0, face.Z)
        or Vector3.new(h.CFrame.LookVector.X, 0, h.CFrame.LookVector.Z)
    if horiz.Magnitude < 0.01 then horiz = Vector3.new(0, 0, -1) end
    pcall(function()
        h.CFrame = CFrame.new(pos, pos + horiz.Unit)
        h.AssemblyLinearVelocity  = Vector3.zero
        h.AssemblyAngularVelocity = Vector3.zero
    end)
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

        -- per-frame snap onto the target's torso top (lightweight)
        local function onTopOfTarget()
            local part = torsoOf(tgt.Character)
            if part and lhrp and lhrp.Parent then
                local pos = part.Position + Vector3.new(0, (part.Size.Y / 2) + 3, 0)
                snapUprightTo(lhrp, pos, lhrp.CFrame.LookVector)
            end
        end

        -- pause auto-stomp for the whole sequence so we don't finish them off
        local stompWasOn = hc.autoStomp.isActive()
        if stompWasOn then hc.autoStomp.stop() end

        -- one heavy upright fix up front (clears ragdoll/sit, syncs desync);
        -- the per-frame loops below use the lightweight snap instead
        do
            local part = torsoOf(tgt.Character)
            if part then uprightTp(lc, lhrp, part.Position + Vector3.new(0, (part.Size.Y / 2) + 3, 0), nil) end
        end

        -- 1) You can only grab a KNOCKED player. Stand on them and shoot ASAP
        --    (every frame, like TP shoot) until they're K.O -- but don't fire
        --    while they're spawn-protected or not loaded in. Skip if already
        --    knocked.
        local wasFH = hc.forceHit.isActive()
        if not wasFH then hc.forceHit.start() end
        local kt0 = os.clock()
        while not isKnocked(tgt) do
            if not (tgt.Character and tgt.Character.Parent) or not lhrp.Parent then break end
            onTopOfTarget()
            if canEngage(tgt) then
                hc.forceHit.setTarget(tgt)
                pcall(hc.forceHit.fire)
            end
            task.wait()
            if os.clock() - kt0 > 4 then break end
        end
        if not wasFH then hc.forceHit.stop() end

        if not isKnocked(tgt) then
            notify("Couldn't knock target", 2, "alert")
            if lhrp and lhrp.Parent then uprightTp(lc, lhrp, saved.Position, saved.LookVector) end
            if stompWasOn then hc.autoStomp.start() end
            return
        end

        -- 2) Grab: stay glued on top EVERY frame, but only fire the Grabbing
        --    remote every ~0.35s, until our BodyEffects.Grabbed value changes.
        local t0, lastFire = os.clock(), 0
        repeat
            onTopOfTarget()
            local now = os.clock()
            if now - lastFire >= 0.35 then
                lastFire = now
                pcall(function() ReplicatedStorage.MainEvent:FireServer("Grabbing") end)
            end
            task.wait()
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

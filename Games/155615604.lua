-- ============================================================
--  witherhook // Games/155615604.lua   (Prison Life)
--  Loads the shared shell (main.lua) then adds the Prison Life
--  tabs: Aimbot, Guns, Game Misc. Wired to hook.games.prisonLife.
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end

local Window = ctx.window
local hook   = api.hook
local notify = api.notify
local regToggle, regSlider, regDropdown = api.regToggle, api.regSlider, api.regDropdown

-- ============================================================
--  PRISON LIFE BACKEND  (moved here from functions.lua)
--  Registers onto hook.games.prisonLife; deps from hook.util.
-- ============================================================
do
    local lplr                = hook.util.lplr
    local VirtualInputManager = hook.util.vim
    local ReplicatedStorage   = hook.util.replicatedStorage
    local isReallyVisible     = hook.util.visibleCheck

-- ============================================================
--  GAMES: PRISON LIFE
-- ============================================================
hook.games.prisonLife = (function()
    local Players = game:GetService("Players")

    local ESCAPE_CF = CFrame.new(
        -973.669861, 108.323685, 2043.36267,
         0, 0, -1,
         0, 1,  0,
         1, 0,  0
    )

    local function getHrp()
        local char = lplr.Character
        if not char then return nil end
        return char:FindFirstChild("HumanoidRootPart")
    end

    -- Returns the name of the local player's current team, or nil.
    local function myTeamName()
        local t = lplr.Team
        return t and t.Name or nil
    end

    -- Returns the equipped Tool (or any gun-like Model) in the
    -- character, or nil. Checks:
    --   1. Standard Tool class (most games)
    --   2. Any Model child of Character that has a "Damage"
    --      attribute (some games use custom gun Models)
    --   3. Also checks the Backpack as a fallback in case the game
    --      keeps tools there while "equipped" (rare but seen)
    local function equippedTool()
        local char = lplr.Character
        if not char then return nil end
        local t = char:FindFirstChildOfClass("Tool")
        if t then return t end
        -- broader: any child with gun-like attributes
        for _, v in ipairs(char:GetChildren()) do
            if (v:IsA("Model") or v:IsA("Tool"))
               and (v:GetAttribute("Damage") or v:GetAttribute("CurrentAmmo")) then
                return v
            end
        end
        return nil
    end

    -- hasGunEquipped: true if an armed tool is present. Less strict
    -- than equippedTool() - also returns true when a character child
    -- with gun attributes exists even if FindFirstChildOfClass fails.
    -- Used as the kill-aura gate so the check degrades gracefully.
    local function hasGunEquipped()
        return equippedTool() ~= nil
    end

    -- ---- escape ----
    local function escape()
        local hrp = getHrp()
        if not hrp then return end
        pcall(function() hrp.CFrame = ESCAPE_CF end)
    end

    local autoActive   = false
    local autoThread   = nil
    local autoTeamConn = nil

    local function _isInmate()
        local t = myTeamName()
        return t == "Inmates" or t == "Prisoner"
    end

    local function _runEscapeLoop()
        while autoActive and _isInmate() do
            local hrp = getHrp()
            if hrp then pcall(function() hrp.CFrame = ESCAPE_CF end) end
            task.wait(0.1)
        end
        autoThread = nil
    end

    local function _onTeamChanged()
        if not autoActive then return end
        if _isInmate() then
            if not autoThread then autoThread = task.spawn(_runEscapeLoop) end
        else
            if autoThread then pcall(task.cancel, autoThread); autoThread = nil end
        end
    end

    local function autoEscapeStart()
        if autoActive then return end
        autoActive = true
        _onTeamChanged()
        if autoTeamConn then autoTeamConn:Disconnect() end
        autoTeamConn = lplr:GetPropertyChangedSignal("Team"):Connect(_onTeamChanged)
    end

    local function autoEscapeStop()
        autoActive = false
        if autoTeamConn then autoTeamConn:Disconnect(); autoTeamConn = nil end
        if autoThread   then pcall(task.cancel, autoThread); autoThread = nil end
    end

    -- ---- fake bullet tracers (ported from HC module) ----
    -- All local-only; identical implementation to the HC tracer but
    -- scoped inside the PL module so HC state isn't shared.
    local plTracerOn       = false
    local plTracerColor    = Color3.fromRGB(255, 60, 60)
    local plTracerLifetime = 0.20
    local plTracerThick    = 0.12
    local plTracerStyle    = "Standard"  -- Standard/Laser/Thin/Lightning/Plasma
    local plTrailOn        = false
    -- cap concurrent impact effects: kill-aura auto-fire (esp. shotguns) can
    -- otherwise spawn dozens of PointLights + emitters at once and freeze the
    -- renderer. Counted for a fixed window then freed, so it can't leak.
    local _plFxCount = 0
    local _PL_FX_MAX = 40

    local function _plSpawnTracer(origin, hitPos)
        if not plTracerOn then return end
        if _plFxCount >= _PL_FX_MAX then return end
        local dist = (hitPos - origin).Magnitude
        if dist < 0.5 then return end
        local dir = (hitPos - origin).Unit
        _plFxCount = _plFxCount + 1
        task.delay(1.2, function() _plFxCount = math.max(0, _plFxCount - 1) end)

        local function invis(pos)
            local p = Instance.new("Part")
            p.Anchored=true; p.CanCollide=false; p.CanTouch=false
            p.CanQuery=false; p.CastShadow=false
            p.Size=Vector3.new(0.05,0.05,0.05); p.Transparency=1
            p.CFrame=CFrame.new(pos); p.Parent=workspace
            return p
        end

        local s = invis(origin); s.Name="_pl_tr_start"
        local e = invis(origin); e.Name="_pl_tr_end"
        local a0=Instance.new("Attachment"); a0.Parent=s
        local a1=Instance.new("Attachment"); a1.Parent=e

        local beams={}
        local function mkB()
            local b=Instance.new("Beam")
            b.Attachment0=a0; b.Attachment1=a1
            b.LightEmission=1; b.LightInfluence=0
            b.FaceCamera=true; b.Segments=1; b.Parent=s
            table.insert(beams,b); return b
        end

        local c = plTracerColor
        if plTracerStyle == "Laser" then
            local b=mkB(); b.Width0=plTracerThick*1.2; b.Width1=plTracerThick*1.2
            b.Color=ColorSequence.new(c); b.Transparency=NumberSequence.new(0)
        elseif plTracerStyle == "Thin" then
            local b=mkB(); b.Width0=plTracerThick*0.6; b.Width1=plTracerThick*0.6
            b.Color=ColorSequence.new(c); b.Transparency=NumberSequence.new(0.1)
        elseif plTracerStyle == "Lightning" then
            local b=mkB(); b.Width0=plTracerThick*2.5; b.Width1=plTracerThick*2.5
            b.Segments=math.max(8,math.floor(dist/4))
            b.CurveSize0=1.5; b.CurveSize1=-1.5
            b.Color=ColorSequence.new(c); b.Transparency=NumberSequence.new(0.1)
            pcall(function() b.Texture="rbxassetid://446111271"
                b.TextureMode=Enum.TextureMode.Wrap; b.TextureLength=1; b.TextureSpeed=15 end)
        elseif plTracerStyle == "Plasma" then
            local b=mkB(); b.Width0=plTracerThick*7; b.Width1=plTracerThick*5
            b.Color=ColorSequence.new(c)
            b.Transparency=NumberSequence.new({
                NumberSequenceKeypoint.new(0,0.4),
                NumberSequenceKeypoint.new(0.5,0.15),
                NumberSequenceKeypoint.new(1,0.4)})
            pcall(function() b.Texture="rbxassetid://1837228550"
                b.TextureMode=Enum.TextureMode.Stretch end)
        else -- Standard
            local o=mkB(); o.Width0=plTracerThick*5; o.Width1=plTracerThick*4
            o.Color=ColorSequence.new(c)
            o.Transparency=NumberSequence.new({
                NumberSequenceKeypoint.new(0,0.55),
                NumberSequenceKeypoint.new(0.5,0.35),
                NumberSequenceKeypoint.new(1,0.55)})
            local i=mkB(); i.Width0=plTracerThick*1.8; i.Width1=plTracerThick*1.2
            i.Color=ColorSequence.new({
                ColorSequenceKeypoint.new(0,c),
                ColorSequenceKeypoint.new(0.5,Color3.new(1,1,1)),
                ColorSequenceKeypoint.new(1,c)})
            i.Transparency=NumberSequence.new(0.05)
            pcall(function() i.Texture="rbxassetid://446111271"
                i.TextureMode=Enum.TextureMode.Wrap; i.TextureLength=6; i.TextureSpeed=8 end)
        end

        if plTrailOn then
            local N=math.clamp(math.floor(dist/6),3,12)
            task.spawn(function()
                for i=1,N do
                    local pos=origin+dir*(dist*(i/N))
                    local a=invis(pos); a.Name="_pl_tr_trail"
                    local at=Instance.new("Attachment",a)
                    local pe=Instance.new("ParticleEmitter")
                    pe.Texture="rbxassetid://241876428"; pe.LightEmission=1
                    pe.Color=ColorSequence.new(c)
                    pe.Size=NumberSequence.new({NumberSequenceKeypoint.new(0,0.25),NumberSequenceKeypoint.new(1,0)})
                    pe.Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,0.2),NumberSequenceKeypoint.new(1,1)})
                    pe.Lifetime=NumberRange.new(0.3,0.5); pe.Rate=0
                    pe.Speed=NumberRange.new(0.5,1.5); pe.SpreadAngle=Vector2.new(180,180)
                    pe.Parent=at; pe:Emit(3)
                    task.delay(0.6,function() if a.Parent then a:Destroy() end end)
                end
            end)
        end

        task.spawn(function()
            local TSTEPS=8; local TDUR=0.06
            for i=1,TSTEPS do
                task.wait(TDUR/TSTEPS)
                if not s.Parent then return end
                e.CFrame=CFrame.new(origin+dir*(dist*(i/TSTEPS)))
            end
            if not s.Parent then return end
            e.CFrame=CFrame.new(hitPos)

            local flash=invis(hitPos); flash.Transparency=0
            flash.Material=Enum.Material.Neon; flash.Color=c
            flash.Shape=Enum.PartType.Ball; flash.Size=Vector3.new(0.6,0.6,0.6)
            flash.Name="_pl_tr_flash"
            local light=Instance.new("PointLight")
            light.Color=c; light.Brightness=5; light.Range=10; light.Parent=flash

            local ring=Instance.new("Part")
            ring.Anchored=true; ring.CanCollide=false; ring.CanTouch=false
            ring.CanQuery=false; ring.CastShadow=false
            ring.Material=Enum.Material.Neon; ring.Shape=Enum.PartType.Cylinder
            ring.Color=c; ring.Size=Vector3.new(0.05,0.5,0.5); ring.Transparency=0.3
            ring.CFrame=CFrame.lookAt(hitPos,hitPos+dir)*CFrame.Angles(0,math.rad(90),0)
            ring.Parent=workspace; ring.Name="_pl_tr_ring"

            local sa=Instance.new("Attachment",flash)
            local sp=Instance.new("ParticleEmitter")
            sp.Texture="rbxassetid://241876428"; sp.LightEmission=1
            sp.Color=ColorSequence.new(c)
            sp.Size=NumberSequence.new({NumberSequenceKeypoint.new(0,0.4),NumberSequenceKeypoint.new(1,0)})
            sp.Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(1,1)})
            sp.Lifetime=NumberRange.new(0.15,0.35); sp.Rate=0
            sp.Speed=NumberRange.new(8,14); sp.SpreadAngle=Vector2.new(180,180)
            sp.Parent=sa; sp:Emit(18)

            task.spawn(function()
                local FS=10; local FD=0.22
                for i=1,FS do
                    task.wait(FD/FS)
                    if not flash.Parent then return end
                    local p=i/FS; local sz=0.6+p*2.6
                    flash.Size=Vector3.new(sz,sz,sz); flash.Transparency=p
                    light.Brightness=5*(1-p)
                    if ring.Parent then
                        local r=0.5+p*4.5
                        ring.Size=Vector3.new(0.05,r,r); ring.Transparency=0.3+(1-0.3)*p
                    end
                end
                if flash.Parent then flash:Destroy() end
                if ring.Parent  then ring:Destroy()  end
            end)

            local FSTEPS=8
            for i=1,FSTEPS do
                task.wait(plTracerLifetime/FSTEPS)
                if not s.Parent then return end
                local p=i/FSTEPS
                for _,b in ipairs(beams) do
                    if b.Parent then b.Transparency=NumberSequence.new(p) end
                end
            end
            if s.Parent then s:Destroy() end
            if e.Parent then e:Destroy() end
        end)
    end

    -- ---- shoot remote ----
    -- ShootEvent:FireServer({ {fromPos, toPos, targetPart}, ... })
    -- Shotguns send multiple pellets per fire (multiple sub-tables).
    -- We detect pellet count + spread from the tool's attributes:
    --   ProjectileCount / BulletsPerShot / Pellets -> pellet count
    --   SpreadRadius                               -> spread (studs)
    -- If none found and tool name contains "Shotgun"/"Pump" etc,
    -- default to 5 pellets.

    local function getShootEvent()
        local rs = game:GetService("ReplicatedStorage")
        local gr = rs:FindFirstChild("GunRemotes")
        return gr and gr:FindFirstChild("ShootEvent")
    end

    local function _toolPellets(tool)
        if not tool then return 1 end
        -- ProjectileCount is the real Prison Life attribute for pellet count
        local n = tool:GetAttribute("ProjectileCount")
        if n and n > 1 then return n end
        -- Remington 870 is the only shotgun in Prison Life
        if tool.Name == "Remington 870" then return 5 end
        return 1
    end

    local function _toolSpread(tool)
        if not tool then return 0 end
        return tool:GetAttribute("SpreadRadius") or 0
    end

    local function _requeueTool()
        local char = lplr.Character; if not char then return end
        local hum  = char:FindFirstChildOfClass("Humanoid"); if not hum then return end
        local tool = equippedTool(); if not tool then return end
        local name = tool.Name
        pcall(function() hum:UnequipTools() end)
        task.wait(0.15)
        local bp = lplr:FindFirstChild("Backpack")
        local t  = bp and bp:FindFirstChild(name)
        if t then pcall(function() hum:EquipTool(t) end) end
    end

    -- ---- no spread (survives death) ----
    local noSpreadOn        = false
    local _noSpreadCharConn = nil
    local _noSpreadToolConn = nil
    -- Suppression window: _requeueTool re-equips the gun which fires
    -- ChildAdded, which would call _applyNoSpread -> requeue again ->
    -- infinite loop. A flag doesn't work because the ChildAdded
    -- handler waits 0.1s before applying (so the flag clears first).
    -- Instead, stamp a deadline; the handler ignores any equip that
    -- happens before the deadline (i.e. our own requeue's re-equip).
    local _noSpreadSuppressUntil = 0

    local function _applyNoSpread(tool)
        if not (noSpreadOn and tool) then return end
        -- already 0? nothing to change, don't requeue
        if tool:GetAttribute("SpreadRadius") == 0 then return end
        pcall(function() tool:SetAttribute("SpreadRadius", 0) end)
        -- our re-equip below will fire ChildAdded; ignore it for 1.5s
        _noSpreadSuppressUntil = tick() + 1.5
        _requeueTool()
    end

    local function _hookNoSpreadChar(char)
        if _noSpreadToolConn then _noSpreadToolConn:Disconnect(); _noSpreadToolConn = nil end
        if not char then return end
        local t = char:FindFirstChildOfClass("Tool")
        if t then _applyNoSpread(t) end
        _noSpreadToolConn = char.ChildAdded:Connect(function(child)
            if not noSpreadOn then return end
            -- ignore the equip our own requeue just triggered
            if tick() < _noSpreadSuppressUntil then return end
            if child:IsA("Tool")
               or (child:IsA("Model") and child:GetAttribute("SpreadRadius")) then
                task.wait(0.1)
                _applyNoSpread(child)
            end
        end)
    end

    local function noSpreadStart()
        noSpreadOn = true
        _hookNoSpreadChar(lplr.Character)
        if _noSpreadCharConn then _noSpreadCharConn:Disconnect() end
        _noSpreadCharConn = lplr.CharacterAdded:Connect(function(char)
            if not noSpreadOn then return end
            task.wait(0.5) -- let character + backpack load
            _hookNoSpreadChar(char)
        end)
    end

    local function noSpreadStop()
        noSpreadOn = false
        if _noSpreadCharConn then _noSpreadCharConn:Disconnect(); _noSpreadCharConn = nil end
        if _noSpreadToolConn then _noSpreadToolConn:Disconnect(); _noSpreadToolConn = nil end
    end

    -- ---- auto fire (survives death) ----
    -- Sets AutoFire = true on the equipped gun so semi-auto guns
    -- (pistols, revolver, sniper, shotgun) fire while the mouse is
    -- held instead of one shot per click. Same equip-on-spawn +
    -- suppression-window pattern as no spread.
    local autoFireOn         = false
    local _autoFireCharConn  = nil
    local _autoFireToolConn  = nil
    local _autoFireSuppress  = 0

    local function _applyAutoFire(tool)
        if not (autoFireOn and tool) then return end
        -- already auto? nothing to change, don't requeue
        if tool:GetAttribute("AutoFire") == true then return end
        pcall(function() tool:SetAttribute("AutoFire", true) end)
        _autoFireSuppress = tick() + 1.5
        _requeueTool()
    end

    local function _hookAutoFireChar(char)
        if _autoFireToolConn then _autoFireToolConn:Disconnect(); _autoFireToolConn = nil end
        if not char then return end
        local t = char:FindFirstChildOfClass("Tool")
        if t then _applyAutoFire(t) end
        _autoFireToolConn = char.ChildAdded:Connect(function(child)
            if not autoFireOn then return end
            if tick() < _autoFireSuppress then return end
            if child:IsA("Tool")
               or (child:IsA("Model") and child:GetAttribute("AutoFire") ~= nil) then
                task.wait(0.1)
                _applyAutoFire(child)
            end
        end)
    end

    local function autoFireStart()
        autoFireOn = true
        _hookAutoFireChar(lplr.Character)
        if _autoFireCharConn then _autoFireCharConn:Disconnect() end
        _autoFireCharConn = lplr.CharacterAdded:Connect(function(char)
            if not autoFireOn then return end
            task.wait(0.5)
            _hookAutoFireChar(char)
        end)
    end

    local function autoFireStop()
        autoFireOn = false
        if _autoFireCharConn then _autoFireCharConn:Disconnect(); _autoFireCharConn = nil end
        if _autoFireToolConn then _autoFireToolConn:Disconnect(); _autoFireToolConn = nil end
    end

    -- ---- fast fire (survives death) ----
    -- Sets FireRate low on the equipped gun so it shoots faster.
    -- Same equip-on-spawn + suppression-window pattern as the others.
    -- Rate is configurable; setRate re-applies live if the toggle
    -- is on.
    local fastFireOn        = false
    local fastFireRate      = 0.05
    local _fastFireCharConn = nil
    local _fastFireToolConn = nil
    local _fastFireSuppress = 0

    local function _applyFastFire(tool)
        if not (fastFireOn and tool) then return end
        -- already at the target rate? nothing to change, don't requeue
        if tool:GetAttribute("FireRate") == fastFireRate then return end
        pcall(function() tool:SetAttribute("FireRate", fastFireRate) end)
        _fastFireSuppress = tick() + 1.5
        _requeueTool()
    end

    local function _hookFastFireChar(char)
        if _fastFireToolConn then _fastFireToolConn:Disconnect(); _fastFireToolConn = nil end
        if not char then return end
        local t = char:FindFirstChildOfClass("Tool")
        if t then _applyFastFire(t) end
        _fastFireToolConn = char.ChildAdded:Connect(function(child)
            if not fastFireOn then return end
            if tick() < _fastFireSuppress then return end
            if child:IsA("Tool")
               or (child:IsA("Model") and child:GetAttribute("FireRate") ~= nil) then
                task.wait(0.1)
                _applyFastFire(child)
            end
        end)
    end

    local function fastFireStart()
        fastFireOn = true
        _hookFastFireChar(lplr.Character)
        if _fastFireCharConn then _fastFireCharConn:Disconnect() end
        _fastFireCharConn = lplr.CharacterAdded:Connect(function(char)
            if not fastFireOn then return end
            task.wait(0.5)
            _hookFastFireChar(char)
        end)
    end

    local function fastFireStop()
        fastFireOn = false
        if _fastFireCharConn then _fastFireCharConn:Disconnect(); _fastFireCharConn = nil end
        if _fastFireToolConn then _fastFireToolConn:Disconnect(); _fastFireToolConn = nil end
    end

    -- ---- gun grabber ----
    -- Gun pickups are Models named "TouchGiver" directly under
    -- workspace, each with a ToolName attribute (e.g. "M700") and a
    -- child BasePart also named "TouchGiver" that holds the
    -- TouchInterest. Firing that touch interest gives you the gun.
    local function _fireGiver(part)
        local hrp = getHrp()
        if not (hrp and part) then return end
        local ft = firetouchinterest or fire_touch_interest
        if not ft then return end
        pcall(function()
            ft(hrp, part, 0)
            task.wait()
            ft(hrp, part, 1)
        end)
    end

    -- list available gun names from the touch givers in workspace
    local function listGunGivers()
        local out = {}
        for _, m in ipairs(workspace:GetChildren()) do
            if m.Name == "TouchGiver" then
                local nm = m:GetAttribute("ToolName")
                if nm then table.insert(out, nm) end
            end
        end
        return out
    end

    local function grabGun(toolName)
        for _, m in ipairs(workspace:GetChildren()) do
            if m.Name == "TouchGiver"
               and (not toolName or m:GetAttribute("ToolName") == toolName) then
                local part = m:FindFirstChild("TouchGiver")
                if part and part:IsA("BasePart") then _fireGiver(part) end
                if toolName then return end  -- grabbed the requested one
            end
        end
    end

    local function grabAllGuns()
        grabGun(nil)  -- nil = every giver
    end

    -- ---- hit sound ----
    local plHitSoundOn  = false
    local plHitSoundOn  = false
    local plHitSoundId  = 135698842254153
    local plHitSoundVol = 1.0

    local function _playHitSound()
        if not plHitSoundOn then return end
        local pg = lplr:FindFirstChildOfClass("PlayerGui")
        local s  = Instance.new("Sound")
        s.SoundId = "rbxassetid://" .. tostring(plHitSoundId)
        s.Volume  = math.clamp(plHitSoundVol, 0, 5)
        s.Parent  = pg or workspace
        s:Play()
        task.delay(5, function() if s and s.Parent then s:Destroy() end end)
    end

    -- ---- auto-reload ----
    -- POLLING based (was attribute-event based). The old version
    -- hooked GetAttributeChangedSignal("CurrentAmmo") and pressed R
    -- on the 0 transition. That worked for auto guns (AK/MP5) which
    -- spam ammo changes so a missed press retries, but single-shot /
    -- low-cap guns (M700 MaxAmmo=1, Revolver) fire the 0-event ONCE -
    -- if the R press didn't register (sniper charge time, animation,
    -- mouse still held) there was no further change event, so it
    -- never retried and the gun sat empty.
    -- Polling re-checks every tick and re-presses R until the reload
    -- actually starts, so it's robust across every gun. Also naturally
    -- survives death (reads the live equipped tool each tick) with no
    -- per-tool / per-character connections to manage.
    local autoReloadOn     = false
    local _reloadThread    = nil

    local function _pressR()
        VirtualInputManager:SendKeyEvent(true,  Enum.KeyCode.R, false, game)
        task.wait(0.05)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.R, false, game)
    end

    local function autoReloadStart()
        if autoReloadOn then return end
        autoReloadOn = true
        _reloadThread = task.spawn(function()
            local lastPress = 0
            while autoReloadOn do
                local tool = equippedTool()
                if tool then
                    local ammo = tool:GetAttribute("CurrentAmmo")
                    if ammo ~= nil then
                        -- keep client counter in sync
                        pcall(function() tool:SetAttribute("Local_CurrentAmmo", ammo) end)
                        local reloading = tool:GetAttribute("IsReloading")
                        -- press R when empty + not already reloading.
                        -- 0.6s debounce so we don't machine-gun R while
                        -- the reload animation hasn't flipped IsReloading.
                        if ammo <= 0 and not reloading
                           and (tick() - lastPress) > 0.6 then
                            lastPress = tick()
                            _pressR()
                        end
                    end
                end
                task.wait(0.15)
            end
            _reloadThread = nil
        end)
    end

    local function autoReloadStop()
        autoReloadOn = false
        if _reloadThread then pcall(task.cancel, _reloadThread); _reloadThread = nil end
    end

    -- ---- hitmarker + damage numbers ----
    local hitMarkerOn   = false
    local hitNumberOn   = false
    local hitNumColor   = Color3.fromRGB(255, 255, 255)
    local HITMARK_IMG   = "rbxassetid://5544769872"

    -- A briefly-shown hitmarker image centred on the hit part.
    local function _spawnHitMarker(part)
        if not (hitMarkerOn and part) then return end
        local bb = Instance.new("BillboardGui")
        bb.Name           = "_pl_hitmark"
        bb.Adornee        = part
        bb.Size           = UDim2.fromOffset(40, 40)
        bb.AlwaysOnTop    = true
        bb.LightInfluence = 0
        bb.Parent         = part
        local img = Instance.new("ImageLabel")
        img.BackgroundTransparency = 1
        img.Size  = UDim2.fromScale(1, 1)
        img.Image = HITMARK_IMG
        img.Parent = bb
        task.spawn(function()
            local STEPS = 6
            for i = 1, STEPS do
                if not bb.Parent then return end
                local p = i / STEPS
                img.ImageTransparency = p
                bb.Size = UDim2.fromOffset(40 + p * 20, 40 + p * 20)
                task.wait(0.04)
            end
            if bb.Parent then bb:Destroy() end
        end)
    end

    -- A damage number that floats up into the sky and fades. Uses the
    -- same bold-outlined style as the ESP text (white-ish bold font
    -- with a black stroke).
    local function _spawnDamageNumber(worldPos, dmg)
        if not (hitNumberOn and worldPos) then return end
        local anchor = Instance.new("Part")
        anchor.Anchored=true; anchor.CanCollide=false; anchor.CanTouch=false
        anchor.CanQuery=false; anchor.CastShadow=false
        anchor.Transparency=1; anchor.Size=Vector3.new(0.05,0.05,0.05)
        anchor.CFrame=CFrame.new(worldPos); anchor.Parent=workspace
        anchor.Name="_pl_dmgnum"

        local bb = Instance.new("BillboardGui")
        bb.Adornee=anchor; bb.Size=UDim2.fromOffset(120, 40)
        bb.AlwaysOnTop=true; bb.LightInfluence=0
        bb.StudsOffsetWorldSpace=Vector3.new(0,0,0); bb.Parent=anchor

        local lbl = Instance.new("TextLabel")
        lbl.BackgroundTransparency=1; lbl.Size=UDim2.fromScale(1,1)
        lbl.Font=Enum.Font.GothamBold
        lbl.TextSize=22
        lbl.Text="-" .. tostring(math.floor(dmg + 0.5))
        lbl.TextColor3=hitNumColor
        lbl.TextStrokeColor3=Color3.new(0,0,0)
        lbl.TextStrokeTransparency=0
        lbl.Parent=bb

        task.spawn(function()
            local DUR=0.8; local t0=tick()
            -- small random horizontal drift so stacked hits don't overlap
            local driftX=(math.random()-0.5)*1.5
            while true do
                local p=(tick()-t0)/DUR
                if p>=1 or not anchor.Parent then break end
                -- rise into the sky + fade
                bb.StudsOffsetWorldSpace=Vector3.new(driftX*p, 3*p, 0)
                lbl.TextTransparency=p
                lbl.TextStrokeTransparency=p
                task.wait()
            end
            if anchor.Parent then anchor:Destroy() end
        end)
    end

    -- Hit detection: watch the kill-aura target's humanoid health.
    -- Each shoot() re-points the watcher at the current target. When
    -- the target's health drops within a short window after a fire,
    -- we spawn the marker + damage number with the actual delta.
    local _hmHum, _hmConn, _hmLast, _hmPart
    local _hmLastFireAt = 0
    local function _ensureHitWatch(targetHRP)
        local char = targetHRP and targetHRP.Parent
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        _hmPart = targetHRP
        if hum == _hmHum then return end
        if _hmConn then _hmConn:Disconnect(); _hmConn = nil end
        _hmHum = hum
        if not hum then return end
        _hmLast = hum.Health
        _hmConn = hum.HealthChanged:Connect(function(newHP)
            local old = _hmLast
            _hmLast = newHP
            if old and newHP < old and (tick() - _hmLastFireAt) < 0.5 then
                local dmg = old - newHP
                _spawnHitMarker(_hmPart)
                if _hmPart then _spawnDamageNumber(_hmPart.Position, dmg) end
            end
        end)
    end

    local function shoot(targetHRP)
        if not targetHRP then return end
        local event = getShootEvent()
        if not event then return end
        local hrp = getHrp()
        if not hrp then return end
        local tool   = equippedTool()
        local from   = hrp.Position
        local to     = targetHRP.Position
        local count  = _toolPellets(tool)
        local spread = _toolSpread(tool)
        local pellets = {}
        for _ = 1, count do
            local offset = Vector3.new(0, 0, 0)
            if count > 1 and spread > 0 then
                offset = Vector3.new(
                    (math.random() - 0.5) * spread * 80,
                    (math.random() - 0.5) * spread * 80,
                    (math.random() - 0.5) * spread * 80
                )
            end
            local toOffset = to + offset
            table.insert(pellets, { from, toOffset, targetHRP })
            task.spawn(_plSpawnTracer, from, toOffset)
        end
        -- arm hit detection for this target before firing
        if hitMarkerOn or hitNumberOn then
            _ensureHitWatch(targetHRP)
            _hmLastFireAt = tick()
        end
        local ok = pcall(function() event:FireServer(pellets) end)
        if ok then _playHitSound() end
    end

    -- ---- team-based enemy filter ----
    -- Criminal -> Guards (always) + hostile Inmates (conditional)
    -- Inmate   -> Criminals, Guards
    -- Guard    -> ONLY inmates with Hostile == true (no criminals)
    -- Same-team is never targeted. Team names normalized to a
    -- category so singular/plural ("Criminal"/"Criminals") match.
    -- Returns true if a Prisoner/Inmate player has any of the
    -- attributes that make them a valid guard target.
    local function _isHostileInmate(player)
        local char = player.Character
        if not char then return false end
        return char:GetAttribute("Hostile")            == true
            or char:GetAttribute("Trespassing")        == true
            or char:GetAttribute("EquippedHostileTool") == true
    end

    -- which teams the kill aura is allowed to target (default: all). The
    -- "Target teams" dropdown narrows this down.
    local targetTeams = { inmate = true, guard = true, criminal = true }

    local function _isEnemy(player)
        local myT    = (myTeamName() or ""):lower()
        local theirT = (player.Team and player.Team.Name or ""):lower()

        -- Never target someone on our OWN team. This is the primary
        -- guard against criminal-vs-criminal (the Hostile attribute
        -- is true for ALL criminals, so without this check a criminal
        -- with no ENEMY_TEAMS entry would shoot teammates).
        if myT ~= "" and myT == theirT then return false end

        -- Normalize: treat singular/plural team names as the same
        -- category so a missing table key doesn't fall through to
        -- "shoot everyone".
        local function cat(name)
            if name:find("criminal") then return "criminal" end
            if name:find("inmate") or name:find("prisoner") then return "inmate" end
            if name:find("guard") or name:find("police") then return "guard" end
            return name
        end
        local myCat    = cat(myT)
        local theirCat = cat(theirT)

        -- only target teams the user has enabled in "Target teams"
        if not targetTeams[theirCat] then return false end

        if myCat == theirCat then return false end  -- same category

        if myCat == "criminal" then
            -- guards always; inmates only if they turned hostile
            -- (punched someone -> Hostile attribute set)
            if theirCat == "guard" then return true end
            if theirCat == "inmate" then return _isHostileInmate(player) end
            return false
        elseif myCat == "inmate" then
            return theirCat == "criminal" or theirCat == "guard"
        elseif myCat == "guard" then
            -- as a guard: ONLY inmates whose Hostile attribute is true (per
            -- request) - no criminals, and not trespassing/armed-but-not-hostile
            if theirCat == "inmate" then
                local ch = player.Character
                return ch ~= nil and ch:GetAttribute("Hostile") == true
            end
            return false
        end

        -- unknown team category: don't shoot (safer than shoot-all)
        return false
    end

    -- ---- kill aura ----
    local auraActive = false
    local auraThread = nil
    -- Range and fire rate are read from the equipped tool's attributes
    -- each tick so they always match the gun. These fallbacks are used
    -- when no tool is equipped.
    local _auraRangeFallback    = 500
    local _auraIntervalFallback = 0.1

    local function _nearestEnemy()
        local hrp = getHrp(); if not hrp then return nil end
        local char   = lplr.Character
        local head   = char and char:FindFirstChild("Head")
        local origin = head and head.Position or hrp.Position
        -- read range from the equipped tool's Range attribute
        local tool  = equippedTool()
        local range = (tool and tool:GetAttribute("Range")) or _auraRangeFallback
        local best, bestD2 = nil, range * range
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= lplr and _isEnemy(p) and p.Character then
                local eh  = p.Character:FindFirstChild("HumanoidRootPart")
                local hum = p.Character:FindFirstChildOfClass("Humanoid")
                local ff = p.Character:FindFirstChildOfClass("ForceField")
                if eh and hum and hum.Health > 0 and not ff then
                    local d2 = (eh.Position - hrp.Position).Magnitude
                    d2 = d2 * d2
                    if d2 < bestD2 then
                        local ignore = { lplr.Character, p.Character }
                        if isReallyVisible(origin, eh.Position, ignore) then
                            best, bestD2 = eh, d2
                        end
                    end
                end
            end
        end
        return best
    end

    local function auraStart()
        if auraActive then return end
        auraActive = true
        auraThread = task.spawn(function()
            while auraActive do
                local _auraTool = equippedTool()
                local _reloading = _auraTool and _auraTool:GetAttribute("IsReloading")
                if hasGunEquipped() and not _reloading then
                    local target = _nearestEnemy()
                    if target then shoot(target) end
                end
                -- read FireRate from tool each tick
                local t        = equippedTool()
                local fireRate = (t and t:GetAttribute("FireRate")) or _auraIntervalFallback
                -- floor at 0.04s (~25/s) so a 0/missing FireRate can't spin the
                -- loop at ~100/s and flood remotes + effects -> freeze
                task.wait(math.max(0.04, fireRate))
            end
            auraThread = nil
        end)
    end

    local function auraStop()
        auraActive = false
        if auraThread then pcall(task.cancel, auraThread); auraThread = nil end
    end


    return {
        escape     = escape,
        autoEscape = { start = autoEscapeStart, stop = autoEscapeStop,
                       isActive = function() return autoActive end },
        shoot      = shoot,
        killAura   = {
            start    = auraStart,
            stop     = auraStop,
            isActive = function() return auraActive end,
            setTargetTeam = function(name, on)
                local s = tostring(name):lower()
                local key = (s:find("criminal") and "criminal")
                    or ((s:find("inmate") or s:find("prisoner")) and "inmate")
                    or ((s:find("guard") or s:find("police")) and "guard")
                if key then targetTeams[key] = (on == true) end
            end,
        },
        noSpread   = {
            start    = noSpreadStart,
            stop     = noSpreadStop,
            isActive = function() return noSpreadOn end,
        },
        autoFire   = {
            start    = autoFireStart,
            stop     = autoFireStop,
            isActive = function() return autoFireOn end,
        },
        fastFire   = {
            start    = fastFireStart,
            stop     = fastFireStop,
            isActive = function() return fastFireOn end,
            setRate  = function(n)
                fastFireRate = math.clamp(tonumber(n) or 0.05, 0.01, 1)
                if fastFireOn then _applyFastFire(equippedTool()) end
            end,
        },
        guns = {
            grabAll = grabAllGuns,
            grab    = grabGun,
            list    = listGunGivers,
        },
        autoReload = {
            start    = autoReloadStart,
            stop     = autoReloadStop,
            isActive = function() return autoReloadOn end,
        },
        hitSound = {
            setEnabled = function(v) plHitSoundOn  = v == true end,
            setId      = function(n) plHitSoundId  = tonumber(n) or plHitSoundId end,
            setVolume  = function(n) plHitSoundVol = math.clamp(tonumber(n) or 1, 0, 5) end,
        },
        hitMarker = {
            setMarker    = function(v) hitMarkerOn = v == true end,
            setNumber    = function(v) hitNumberOn = v == true end,
            setNumColor  = function(c) if typeof(c) == "Color3" then hitNumColor = c end end,
        },
        tracer = {
            setEnabled   = function(v) plTracerOn      = v == true end,
            setColor     = function(c) if typeof(c)=="Color3" then plTracerColor=c end end,
            setLifetime  = function(n) plTracerLifetime= math.clamp(tonumber(n) or 0.2, 0.05, 3) end,
            setThickness = function(n) plTracerThick   = math.clamp(tonumber(n) or 0.12, 0.01, 2) end,
            setStyle     = function(s) plTracerStyle   = tostring(s) end,
            setTrail     = function(v) plTrailOn       = v == true end,
        },
    }
end)()
end

local pl = hook.games and hook.games.prisonLife
if not pl then
    notify("Prison Life module unavailable", 5, "error")
    return
end

-- named hit sounds (label -> asset id)
local PL_SOUNDS = {
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
for _, s in ipairs(PL_SOUNDS) do soundLabels[#soundLabels + 1] = s[1]; idByLabel[s[1]] = s[2] end

-- ============================================================
--  AIMBOT  (kill aura + hit feedback + tracers)
-- ============================================================
local Aim = Window:NewTab("Aimbot")

Aim:NewSection("Kill aura")
regToggle(Aim, "PL_KillAura", "Kill aura", false, function(v)
    if v then
        -- killaura must only fire on genuinely visible targets:
        -- strict check (no see-through walls) from the head origin
        hook.utils.setStrictVisibleCheck(true)
        hook.utils.setVisibleOrigin("Head")
        pl.killAura.start()
    else
        pl.killAura.stop()
        hook.utils.setStrictVisibleCheck(false)
    end
end):AddKeybind(Enum.KeyCode.F, "Killaura Toggle")
-- which teams the kill aura is allowed to target (all on by default)
regToggle(Aim, "PL_AuraInmates",   "Target inmates",   true, function(v) pl.killAura.setTargetTeam("inmate", v) end)
regToggle(Aim, "PL_AuraGuards",    "Target guards",    true, function(v) pl.killAura.setTargetTeam("guard", v) end)
regToggle(Aim, "PL_AuraCriminals", "Target criminals", true, function(v) pl.killAura.setTargetTeam("criminal", v) end)
Aim:NewLabel("Auto-shoots the nearest visible enemy.", "left")

Aim:NewSection("Hit feedback")
regToggle(Aim, "PL_HitMarker", "Hit marker", false, function(v) pl.hitMarker.setMarker(v) end)
regToggle(Aim, "PL_HitNumber", "Hit number", false, function(v) pl.hitMarker.setNumber(v) end)
regToggle(Aim, "PL_HitSound",  "Hit sound",  false, function(v) pl.hitSound.setEnabled(v) end)
regDropdown(Aim, "PL_HitSoundId", "Sound", "crit", soundLabels, false, function(label)
    local id = idByLabel[label]; if id then pl.hitSound.setId(id) end
end)
regSlider(Aim, "PL_HitSoundVol", "Sound volume", "", { min = 0, max = 5, default = 1 }, function(v) pl.hitSound.setVolume(v) end)

Aim:NewSection("Tracer")
regToggle(Aim, "PL_Tracer",      "Bullet tracer", false, function(v) pl.tracer.setEnabled(v) end)
regDropdown(Aim, "PL_TracerStyle", "Tracer style", "Standard",
    { "Standard", "Laser", "Thin", "Lightning", "Plasma" }, false, function(v) pl.tracer.setStyle(v) end)
regToggle(Aim, "PL_TracerTrail", "Tracer trail",  false, function(v) pl.tracer.setTrail(v) end)
-- lifetime 0.05-3.00s shown as 5-300; thickness 0.01-2.00 shown as 1-200
regSlider(Aim, "PL_TracerLifetime", "Tracer lifetime", "", { min = 5, max = 300, default = 20 }, function(v)
    pl.tracer.setLifetime(v / 100)
end)
regSlider(Aim, "PL_TracerThick", "Tracer thickness", "", { min = 1, max = 200, default = 12 }, function(v)
    pl.tracer.setThickness(v / 100)
end)

-- ============================================================
--  GUNS  (gun mods + give guns)
-- ============================================================
local Guns = Window:NewTab("Guns")

Guns:NewSection("Gun mods")
regToggle(Guns, "PL_NoSpread", "No spread", false, function(v)
    if v then pl.noSpread.start() else pl.noSpread.stop() end
end)
regToggle(Guns, "PL_AutoFire", "Auto fire (hold to shoot)", false, function(v)
    if v then pl.autoFire.start() else pl.autoFire.stop() end
end)
regToggle(Guns, "PL_FastFire", "Fast fire", false, function(v)
    if v then pl.fastFire.start() else pl.fastFire.stop() end
end)
-- fire interval 0.01-1.00s shown as 1-100 (slider is integer-only; lower = faster)
regSlider(Guns, "PL_FastFireRate", "Fast fire interval", "", { min = 1, max = 100, default = 5 }, function(v)
    pl.fastFire.setRate(v / 100)
end)
regToggle(Guns, "PL_AutoReload", "Auto reload", false, function(v)
    if v then pl.autoReload.start() else pl.autoReload.stop() end
end)

Guns:NewSection("Give guns")
Guns:NewButton("Grab all guns", function()
    pl.guns.grabAll()
    notify("Grabbed all guns", 2, "success")
end)

local gunSel = nil
local gunDrop = Guns:NewDropdown("Gun", "—", pl.guns.list(), false, function(v) gunSel = v end)

Guns:NewButton("Grab selected", function()
    if gunSel and gunSel ~= "—" then
        pl.guns.grab(gunSel)
        notify("Grabbed " .. gunSel, 2, "success")
    else
        notify("Select a gun first", 3, "alert")
    end
end)
:AddButton("Refresh list", function()
    local list = pl.guns.list()
    if #list == 0 then list = { "—" } end
    gunDrop:SetOptions(list)
end)

-- ============================================================
--  GAME MISC
-- ============================================================
local GMisc = Window:NewTab("Game Misc")
GMisc:NewSection("Escape")
GMisc:NewButton("Escape prison", function()
    pl.escape()
    notify("Escaping...", 2, "information")
end)
regToggle(GMisc, "PL_AutoEscape", "Auto escape", false, function(v)
    if v then pl.autoEscape.start() else pl.autoEscape.stop() end
end)

-- shared tabs (Movement/Misc/Settings/Config) go BELOW the Prison Life tabs
api.buildShared()

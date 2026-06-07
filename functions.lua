-- witherhook // functions.lua
-- Shared backend used by every game (Games/main.lua + universal.lua):
-- movement, desync, visuals, aim/targeting, players, prompts, utils.
-- Each supported game's own logic lives in its Games/<placeId>.lua file.


--  VERSION  (bumped on every push so you can verify which build
local SCRIPT_VERSION = "v1.39.1"

--// services
local HttpService         = game:GetService("HttpService")
local TweenService        = game:GetService("TweenService")
local UserInputService    = game:GetService("UserInputService")
local RunService          = game:GetService("RunService")
local plrs                = game:GetService("Players")
local VirtualInputManager = game:GetService("VirtualInputManager")
local lplr             = plrs.LocalPlayer
local Camera           = workspace.CurrentCamera

--// forward-declare the public API table so functions defined below can
local F

--// cached player list
local _cachedPlayers = plrs:GetPlayers()
plrs.PlayerAdded:Connect(function() _cachedPlayers = plrs:GetPlayers() end)
plrs.PlayerRemoving:Connect(function() task.defer(function() _cachedPlayers = plrs:GetPlayers() end) end)

--// no-op GUI stubs (the original script wired these to the legacy GUI;

--// shared state
local G = { speedValue = 2 }
local FLY_SPEED   = 60
local SPIN_SPEED  = 50
local ICE_SLIDE   = 0.98
local BLINK_DIST  = 20
local CUSTOM_FOV  = 70

local BHOP_CFG = {
    AIR_ACCEL              = 250,
    AIR_SPEED              = 50,
    AIR_MAX_SPEED          = 100,
    AIR_MAX_SPEED_FRIC     = 3,
    AIR_MAX_SPEED_FRIC_DEC = 1,
    AIR_FRICTION           = 0.05,
    FRICTION               = 3,
    GROUND_DECCEL          = 10,
    JUMP_VELOCITY          = 20,
}

local AimbotSettings = {
    Enabled=false, TeamCheck=false, VisibleCheck=false,
    TargetPart="HumanoidRootPart", Method="Mouse.Hit/Target", ClosestPart=false,
    FOVRadius=130, ShowFOV=false, ShowTarget=false,
    Prediction=false, PredictionAmount=0.165, HitChance=100,
}

local CamLockSettings = {
    Enabled=false, TeamCheck=false, VisibleCheck=false,
    TargetPart="Head", ClosestPart=false,
    Mode="Mouse", FOVRadius=200, ShowFOV=false,
    Prediction=false, PredictionAmount=0.165,
    Smoothing=0.25, Sticky=true,
    ToolCheck=false, OnlyVisible=false, OnlyFirstPerson=false,
}

local TrigSettings = {
    Enabled=false, TeamCheck=false, VisibleCheck=false,
    Prediction=false, PredictionAmount=0.1,
    ClickDelay=0, FOVRadius=20, ShowFOV=false,
    TargetPart="HumanoidRootPart", ShowTarget=false,
    ToolCheck=false,
}

local RageSettings = {
    TargetUserId=nil, TargetPlayer=nil, SkipKnocked=false, IgnoreKnocked=false,
    ShowLine=true, ShowOutline=true, LineOrigin="Bottom", FaceTarget=false,
    OutlineColor = Color3.fromRGB(255, 80, 80),
    LineColor    = Color3.fromRGB(255, 60, 60),
    Orbit=false, OrbitDistance=15, OrbitSpeed=60, OrbitHeight=5,
    AutoShoot=false, AutoShootDist=50, AutoShootVis=true, AutoShootRequireTool=false,
    AutoShootCooldown=100, EquipDelay=0.5, FFCheck=true,
    -- when on, equip AutoShootEquipTool (from backpack) the moment
    AutoShootEquip=false, AutoShootEquipTool="",
    -- post-knocked grace window (ms). If the target was seen knocked
    KnockedGraceDelay=0,
    SilentForce=false, SilentMethod="All",
    SpeedPanic=false, SpeedPanicVal=0,
    TpBehind=false, TpBehindDist=0,
    CamSnap=false, CamSmoothing=0.15,
    AutoSwitch=true, NotifyTarget=true,
    SwitchByMouse=false,
    -- Priority mode for rbGetTarget. One of:
    Priority="Closest",
}

local EspSettings = {
    Enabled=false, BoxESP=false, NameESP=false, HealthESP=false, HealthNum=false,
    DistanceESP=false, TracerESP=false, SkeletonESP=false, TeamCheck=false,
    ChamsEnabled=false, HeldItem=false, SelfESP=false,
    RadarEnabled=false, XCTEnabled=false, TracerHistory=false, TracerHistLen=2,
    BoxStyle="Corners", TracerOrigin="Bottom", ChamsStyle="Overlay",
    -- Colors (live-readable by render code; setters on F.esp).
    EnemyColor    = Color3.fromRGB(220,  60,  60),
    TeamColor     = Color3.fromRGB( 80, 220,  80),
    NeutralColor  = Color3.fromRGB(255, 255, 255),
    ChamsFill     = Color3.fromRGB(255,  60,  60),
    ChamsOutline  = Color3.fromRGB(255, 255, 255),
    HealthBarColor= Color3.fromRGB( 80, 220,  80),
    TracerColor   = Color3.fromRGB(255,  60,  60),
}

local _rbTargetList = {}

--  VISIBILITY HELPER (cache raw Raycast before any hooks)
local rawRaycast = workspace.Raycast
local _visParams = RaycastParams.new()
_visParams.FilterType = Enum.RaycastFilterType.Exclude

-- when strict, any raycast hit blocks visibility (even see-through /
local _visStrict = false
-- which point the visibility raycast STARTS from. One of:
local _visOrigin = "Camera"
local function _visGetOrigin()
    local mode = _visOrigin
    local c = lplr.Character
    if mode == "Tool" and c then
        local tool = c:FindFirstChildOfClass("Tool")
        local handle = tool and tool:FindFirstChild("Handle")
        if handle then return handle.Position end
        mode = "Head"  -- fall through if no tool equipped
    end
    if mode == "Head" and c then
        local head = c:FindFirstChild("Head")
        if head then return head.Position end
    end
    return workspace.CurrentCamera.CFrame.Position
end
local function isReallyVisible(fromPos, toPos, ignoreList)
    local dir = toPos - fromPos
    local dist = dir.Magnitude
    if dist < 0.1 then return true end
    _visParams.FilterDescendantsInstances = ignoreList
    local remaining = dist
    local origin = fromPos
    local unit = dir.Unit
    for _ = 1, 3 do
        if remaining <= 0 then break end
        local result = rawRaycast(workspace, origin, unit * remaining, _visParams)
        if not result then return true end
        if _visStrict then return false end
        local hit = result.Instance
        if hit.Transparency >= 0.5 or not hit.CanCollide then
            local stepped = (result.Position - origin).Magnitude + 0.05
            origin = origin + unit * stepped
            remaining = remaining - stepped
        else
            return false
        end
    end
    return true
end

--  MOVEMENT: FLY / SPEED / BHOP / INFJUMP / ANTIAFK / CLICKTP
local function stopFly()
    G.flyActive=false; if G.flyConn then G.flyConn:Disconnect(); G.flyConn=nil end
end
local function startFly()
    G.flyActive=true
    if G.flyConn then G.flyConn:Disconnect() end
    G.flyConn=RunService.Heartbeat:Connect(function(dt)
        if not G.flyActive then return end
        local char=lplr.Character; if not char then return end
        local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
        local cam=workspace.CurrentCamera; local dir=Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W)         then dir+=cam.CFrame.LookVector  end
        if UserInputService:IsKeyDown(Enum.KeyCode.S)         then dir-=cam.CFrame.LookVector  end
        if UserInputService:IsKeyDown(Enum.KeyCode.A)         then dir-=cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D)         then dir+=cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space)     then dir+=Vector3.new(0,1,0)     end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then dir-=Vector3.new(0,1,0)     end
        hrp.AssemblyLinearVelocity=Vector3.zero; hrp.AssemblyAngularVelocity=Vector3.zero
        if UserInputService:GetFocusedTextBox() then return end
        if dir.Magnitude>0 then hrp.CFrame=hrp.CFrame+dir.Unit*FLY_SPEED*dt end
    end)
end

--  WALKSPEED  (real Humanoid.WalkSpeed override with anti-restore)
G.walkspeedValue  = 16
G.walkspeedActive = false
local _WS_BIND_NAME = "_F_WalkspeedEnforce"
local function _wsGetHum()
    local c = lplr.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function _wsEnforceOnce()
    if not G.walkspeedActive then return end
    local hum = _wsGetHum()
    if not hum then return end
    if hum.WalkSpeed ~= G.walkspeedValue then
        pcall(function() hum.WalkSpeed = G.walkspeedValue end)
    end
end
local function stopWalkspeed()
    G.walkspeedActive = false
    if G._wsHeartConn then G._wsHeartConn:Disconnect(); G._wsHeartConn = nil end
    pcall(function() RunService:UnbindFromRenderStep(_WS_BIND_NAME) end)
    local hum = _wsGetHum()
    if hum then pcall(function() hum.WalkSpeed = 16 end) end
end
local function startWalkspeed()
    G.walkspeedActive = true
    if G._wsHeartConn then G._wsHeartConn:Disconnect() end
    G._wsHeartConn = RunService.Heartbeat:Connect(_wsEnforceOnce)
    -- BindToRenderStep at the latest possible priority (after every
    pcall(function() RunService:UnbindFromRenderStep(_WS_BIND_NAME) end)
    pcall(function()
        RunService:BindToRenderStep(_WS_BIND_NAME, Enum.RenderPriority.Last.Value + 1, _wsEnforceOnce)
    end)
end

--  JUMPPOWER  (real Humanoid.JumpPower override with anti-restore)
G.jumpPowerValue  = 50
G.jumpPowerActive = false
local _JP_BIND_NAME = "_F_JumpPowerEnforce"
local function _jpGetHum()
    local c = lplr.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function _jpDesiredHeight()
    -- power 50 ~= height 7.2; mirror the slider in JumpHeight units
    return G.jumpPowerValue / 7
end
local function _jpEnforceOnce()
    if not G.jumpPowerActive then return end
    local hum = _jpGetHum()
    if not hum then return end
    pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true) end)
    pcall(function()
        if hum.UseJumpPower then
            if hum.JumpPower ~= G.jumpPowerValue then
                hum.JumpPower = G.jumpPowerValue
            end
        else
            local h = _jpDesiredHeight()
            if math.abs(hum.JumpHeight - h) > 0.05 then
                hum.JumpHeight = h
            end
        end
    end)
end
local function stopJumpPower()
    G.jumpPowerActive = false
    if G._jpHeartConn then G._jpHeartConn:Disconnect(); G._jpHeartConn = nil end
    pcall(function() RunService:UnbindFromRenderStep(_JP_BIND_NAME) end)
    local hum = _jpGetHum()
    if hum then
        pcall(function()
            if hum.UseJumpPower then hum.JumpPower = 50 else hum.JumpHeight = 7.2 end
        end)
    end
end
local function startJumpPower()
    G.jumpPowerActive = true
    if G._jpHeartConn then G._jpHeartConn:Disconnect() end
    G._jpHeartConn = RunService.Heartbeat:Connect(_jpEnforceOnce)
    pcall(function() RunService:UnbindFromRenderStep(_JP_BIND_NAME) end)
    pcall(function()
        RunService:BindToRenderStep(_JP_BIND_NAME, Enum.RenderPriority.Last.Value + 1, _jpEnforceOnce)
    end)
end

--  CFRAME SPEED  (camera-WASD-driven CFrame nudge - "speed hack")
local function stopCframeSpeed()
    G.speedActive=false; if G.speedConn then G.speedConn:Disconnect(); G.speedConn=nil end
end
local function startCframeSpeed(mult)
    G.speedActive=true; G.speedValue=mult or 2
    if G.speedConn then G.speedConn:Disconnect() end
    G.speedConn=RunService.Heartbeat:Connect(function(dt)
        if not G.speedActive then return end
        if UserInputService:GetFocusedTextBox() then return end
        local char=lplr.Character; if not char then return end
        local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
        local dir=Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir+=workspace.CurrentCamera.CFrame.LookVector  end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir-=workspace.CurrentCamera.CFrame.LookVector  end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir-=workspace.CurrentCamera.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir+=workspace.CurrentCamera.CFrame.RightVector end
        dir=Vector3.new(dir.X,0,dir.Z)
        if dir.Magnitude>0 then hrp.CFrame=hrp.CFrame+dir.Unit*(16*(G.speedValue-1))*dt end
    end)
end

-- bhop: pure AssemblyLinearVelocity, Quake-style air accel
local _bhopStepConn, _bhopJumpConn, _bhopAirFric, _bhopVel = nil, nil, 0, Vector3.zero

--  FORCE-ENABLE JUMP
local _forceJumpConns = {}
local function _fjClear()
    for _, c in ipairs(_forceJumpConns) do pcall(function() c:Disconnect() end) end
    _forceJumpConns = {}
end
local function _fjEnforce(hum)
    if not hum then return end
    pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true) end)
    pcall(function()
        if hum.UseJumpPower then
            if hum.JumpPower <= 0 then hum.JumpPower = 50 end
        else
            if hum.JumpHeight <= 0 then hum.JumpHeight = 7.2 end
        end
    end)
end
local function _fjHookChar(char)
    _fjClear()
    local hum = char:WaitForChild("Humanoid", 5)
    if not hum then return end
    _fjEnforce(hum)
    table.insert(_forceJumpConns, hum:GetPropertyChangedSignal("JumpPower"):Connect(function()
        if G.forceJumpActive then _fjEnforce(hum) end
    end))
    table.insert(_forceJumpConns, hum:GetPropertyChangedSignal("JumpHeight"):Connect(function()
        if G.forceJumpActive then _fjEnforce(hum) end
    end))
end
local function stopForceJump()
    G.forceJumpActive = false
    _fjClear()
    if G._fjCharConn  then G._fjCharConn:Disconnect();  G._fjCharConn  = nil end
    if G._fjInputConn then G._fjInputConn:Disconnect(); G._fjInputConn = nil end
end
local function startForceJump()
    G.forceJumpActive = true
    if G._fjCharConn then G._fjCharConn:Disconnect() end
    G._fjCharConn = lplr.CharacterAdded:Connect(function(c)
        if G.forceJumpActive then _fjHookChar(c) end
    end)
    if lplr.Character then _fjHookChar(lplr.Character) end
    if G._fjInputConn then G._fjInputConn:Disconnect() end
    G._fjInputConn = UserInputService.InputBegan:Connect(function(input, gp)
        if gp then return end
        if not G.forceJumpActive then return end
        if input.KeyCode ~= Enum.KeyCode.Space then return end
        local c = lplr.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if hum then
            -- re-enable state + JumpPower right before the actual jump
            _fjEnforce(hum)
            pcall(function() hum.Jump = true end)
        end
    end)
end

local function startAntiAfk()
    G.antiAfkActive=true
    local disabled = {}
    pcall(function()
        for _, conn in ipairs(getconnections(lplr.Idled)) do
            conn:Disable(); table.insert(disabled, conn)
        end
    end)
    G.antiAfkDisabled = disabled
    local t=0
    G.antiAfkConn=RunService.Heartbeat:Connect(function(dt)
        t+=dt
        if t>=55 then
            t=0
            -- firesignal(lplr.Idled) was here but is a no-op (and a footgun):
            pcall(function()
                local vim=VirtualInputManager
                vim:SendKeyEvent(true,Enum.KeyCode.W,false,game)
                vim:SendKeyEvent(false,Enum.KeyCode.W,false,game)
            end)
        end
    end)
end

local function stopClickTp()
    G.clickTpActive=false; if G.clickTpConn then G.clickTpConn:Disconnect(); G.clickTpConn=nil end
end
local function startClickTp()
    G.clickTpActive=true
    G.clickTpConn=UserInputService.InputBegan:Connect(function(inp,gp)
        if gp then return end
        if inp.UserInputType~=Enum.UserInputType.MouseButton1 then return end
        local cam=workspace.CurrentCamera; local ray=cam:ScreenPointToRay(inp.Position.X,inp.Position.Y)
        local result=workspace:Raycast(ray.Origin,ray.Direction*1000)
        if result then
            local lc=lplr.Character
            local hrp=lc and lc:FindFirstChild("HumanoidRootPart")
            if hrp then
                local pos = result.Position + Vector3.new(0, 3, 0)
                local lv  = hrp.CFrame.LookVector
                local horiz = Vector3.new(lv.X, 0, lv.Z)
                if horiz.Magnitude < 0.01 then horiz = Vector3.new(0, 0, -1) end
                horiz = horiz.Unit
                pcall(function()
                    hrp.CFrame = CFrame.new(pos, pos + horiz)
                    hrp.AssemblyLinearVelocity  = Vector3.zero
                    hrp.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end
    end)
end

--  AUTO-RESPAWN / RESPAWN
local function _uprightCF(cf)
    if not cf then return nil end
    local lv = cf.LookVector
    local horiz = Vector3.new(lv.X, 0, lv.Z)
    if horiz.Magnitude < 0.01 then horiz = Vector3.new(0, 0, -1) end
    horiz = horiz.Unit
    return CFrame.new(cf.Position, cf.Position + horiz)
end

-- force the new humanoid out of any ragdoll / sit / platform-stand state
local function _forceStanding(newChar)
    if not newChar then return end
    local hum = newChar:WaitForChild("Humanoid", 3)
    if not hum then return end
    pcall(function() hum.PlatformStand = false end)
    pcall(function() hum.Sit            = false end)
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    -- second nudge after a frame in case the game's own scripts re-set the state
    task.delay(0.1, function()
        if not hum.Parent then return end
        pcall(function() hum.PlatformStand = false end)
        pcall(function() hum.Sit            = false end)
        if hum:GetState() ~= Enum.HumanoidStateType.Running then
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end
    end)
end

-- generic upright-teleport helper used by every TP path so we never tip
local function _uprightTp(char, hrp, position, faceDir)
    -- pre-clean: if we're ragdolled / upside-down / sitting, joint
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function() hum.PlatformStand = false end)
            pcall(function() hum.Sit            = false end)
        end
    end

    local horiz
    if faceDir then
        horiz = Vector3.new(faceDir.X, 0, faceDir.Z)
    end
    if not horiz or horiz.Magnitude < 0.01 then
        local lv = hrp.CFrame.LookVector
        horiz = Vector3.new(lv.X, 0, lv.Z)
        if horiz.Magnitude < 0.01 then horiz = Vector3.new(0, 0, -1) end
    end
    horiz = horiz.Unit
    local newCF = CFrame.new(position, position + horiz)
    pcall(function()
        hrp.CFrame = newCF
        hrp.AssemblyLinearVelocity  = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)
    -- notify desync so its Heartbeat-captured realCF gets updated to the
    if F and F.desync and F.desync.notifyTeleport then
        F.desync.notifyTeleport(newCF)
    end
    if char then _forceStanding(char) end
end

local function cmdRe()
    local char=lplr.Character; if not char then return end
    local hrp=char:FindFirstChild("HumanoidRootPart")
    if hrp then G.savedCFrame=hrp.CFrame end
    lplr.CharacterAdded:Once(function(newChar)
        -- snapshot G.savedCFrame BEFORE the yield. Otherwise a second
        local cf = G.savedCFrame
        G.savedCFrame = nil
        if cf then
            local newHrp = newChar:WaitForChild("HumanoidRootPart",5)
            if newHrp then
                task.wait(0.1)
                local upright = _uprightCF(cf)
                if upright then pcall(function() newHrp.CFrame = upright end) end
            end
        end
        _forceStanding(newChar)
    end)
    local hum=char:FindFirstChildOfClass("Humanoid")
    task.spawn(function()
        pcall(function() replicatesignal(lplr.Kill) end)
        if hum then pcall(function() replicatesignal(hum.HealthChanged, 0) end) end
        if hum then pcall(function() hum.Health=0 end) end
        if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Dead) end) end
        if hum then pcall(function() hum:TakeDamage(math.huge) end) end
        if hum then pcall(function() hum.MaxHealth=0; hum.Health=0 end) end
        pcall(function() lplr:LoadCharacter() end)
    end)
end

--  NOCLIP / FULLBRIGHT / FREECAM / ZOOM
local function stopNoclip()
    G.noclipActive=false
    pcall(function() RunService:UnbindFromRenderStep("NoclipStep") end)
    if G.noclipHBConn then G.noclipHBConn:Disconnect(); G.noclipHBConn=nil end
    if G.noclipConn and type(G.noclipConn)~="boolean" then G.noclipConn:Disconnect() end
    G.noclipConn=nil
    -- restore CanCollide on the parts we were overriding. The engine
    local c = lplr.Character
    if c then
        for _, name in ipairs({"HumanoidRootPart","UpperTorso","Torso","Head","LowerTorso"}) do
            local p = c:FindFirstChild(name)
            if p and p:IsA("BasePart") then
                pcall(function() p.CanCollide = true end)
            end
        end
    end
end
local function startNoclip()
    G.noclipActive=true
    -- only the 5 collision-relevant parts need CanCollide=false; iterating
    RunService:BindToRenderStep("NoclipStep", Enum.RenderPriority.First.Value, function()
        if not G.noclipActive then return end
        local c=lplr.Character; if not c then return end
        for _,name in ipairs({"HumanoidRootPart","UpperTorso","Torso","Head","LowerTorso"}) do
            local p=c:FindFirstChild(name); if p then p.CanCollide=false end
        end
    end)
end

local function stopFullbright()
    G.fullbrightActive=false
    local L=game:GetService("Lighting")
    L.Brightness=1; L.ClockTime=14; L.GlobalShadows=true
    L.Ambient=Color3.fromRGB(70,70,70); L.OutdoorAmbient=Color3.fromRGB(128,128,128)
end
local function startFullbright()
    G.fullbrightActive=true
    local L=game:GetService("Lighting")
    L.Brightness=2; L.ClockTime=14; L.GlobalShadows=false
    L.Ambient=Color3.fromRGB(255,255,255); L.OutdoorAmbient=Color3.fromRGB(255,255,255)
    for _,v in ipairs(L:GetChildren()) do
        if v:IsA("Atmosphere") or v:IsA("BlurEffect") or v:IsA("ColorCorrectionEffect") or v:IsA("SunRaysEffect") then
            v.Enabled=false
        end
    end
end

local function stopFreecam()
    G.freecamActive=false
    if G.freecamConn then G.freecamConn:Disconnect(); G.freecamConn=nil end
    if G.freecamMouseConn then G.freecamMouseConn:Disconnect(); G.freecamMouseConn=nil end
    if G._freecamCharConn then G._freecamCharConn:Disconnect(); G._freecamCharConn=nil end
    pcall(function() RunService:UnbindFromRenderStep("FreecamRender") end)
    workspace.CurrentCamera.CameraType=Enum.CameraType.Custom
    UserInputService.MouseBehavior=Enum.MouseBehavior.Default
    local char=lplr.Character
    if char then
        local hrp=char:FindFirstChild("HumanoidRootPart")
        if hrp then local bv=hrp:FindFirstChild("FreecamAnchor"); if bv then bv:Destroy() end end
        local hum=char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed=16; hum.JumpPower=50 end
    end
end
local function startFreecam()
    G.freecamActive=true
    local cam=workspace.CurrentCamera
    G.freecamCF=cam.CFrame
    cam.CameraType=Enum.CameraType.Scriptable
    -- anchor body + zero walkspeed/jump on every (re)spawn while active.
    local function anchorChar(char)
        if not char then return end
        local hrp=char:WaitForChild("HumanoidRootPart",5)
        if hrp then
            local existing=hrp:FindFirstChild("FreecamAnchor")
            if existing then existing:Destroy() end
            local bv=Instance.new("BodyVelocity")
            bv.Name="FreecamAnchor"; bv.Velocity=Vector3.zero
            bv.MaxForce=Vector3.new(1e5,1e5,1e5); bv.Parent=hrp
        end
        local hum=char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed=0; hum.JumpPower=0 end
    end
    anchorChar(lplr.Character)
    if G._freecamCharConn then G._freecamCharConn:Disconnect() end
    G._freecamCharConn=lplr.CharacterAdded:Connect(function(c)
        if G.freecamActive then anchorChar(c) end
    end)
    local BASE_SPEED=40; local SPRINT_MULT=4
    local rotX=math.asin(math.clamp(cam.CFrame.LookVector.Y,-1,1))
    local rotY=math.atan2(-cam.CFrame.LookVector.X,-cam.CFrame.LookVector.Z)
    G.freecamMouseConn=UserInputService.InputChanged:Connect(function(inp)
        if not G.freecamActive then return end
        if inp.UserInputType==Enum.UserInputType.MouseMovement then
            rotY=rotY-inp.Delta.X*0.003
            rotX=math.clamp(rotX-inp.Delta.Y*0.003,-math.pi/2+0.01,math.pi/2-0.01)
        end
    end)
    RunService:BindToRenderStep("FreecamRender", Enum.RenderPriority.Camera.Value+1, function(dt)
        if not G.freecamActive then return end
        UserInputService.MouseBehavior=Enum.MouseBehavior.LockCurrentPosition
        local cf=CFrame.new(G.freecamCF.Position)*CFrame.fromEulerAnglesYXZ(rotX,rotY,0)
        local dir=Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir+=cf.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir-=cf.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir-=cf.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir+=cf.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir+=Vector3.new(0,1,0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.Q) then dir-=Vector3.new(0,1,0) end
        local sprint=UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and SPRINT_MULT or 1
        if dir.Magnitude>0 then
            G.freecamCF=CFrame.new(G.freecamCF.Position+dir.Unit*BASE_SPEED*sprint*dt)
        end
        cam.CFrame=CFrame.new(G.freecamCF.Position)*CFrame.fromEulerAnglesYXZ(rotX,rotY,0)
    end)
end

local function stopZoom()
    G.zoomActive=false
    if G.zoomConn then G.zoomConn:Disconnect(); G.zoomConn=nil end
    lplr.CameraMaxZoomDistance=400
end
local function startZoom()
    G.zoomActive=true
    local function applyZoom() lplr.CameraMaxZoomDistance=500 end
    applyZoom()
    G.zoomConn=lplr.CharacterAdded:Connect(function() task.wait(0.1); applyZoom() end)
end

--  SPIN / FLIP / ICE / BLINK
local function stopFlip()
    G.flipActive=false
    if G._flipHb then G._flipHb:Disconnect(); G._flipHb=nil end
    if G._flipRs then G._flipRs:Disconnect(); G._flipRs=nil end
    pcall(function() RunService:UnbindFromRenderStep("FlipRestore") end)
    if G._flipCharConn then G._flipCharConn:Disconnect(); G._flipCharConn=nil end
    local char=lplr.Character
    if char then
        local hum=char:FindFirstChildOfClass("Humanoid")
        if hum then hum.CameraOffset=Vector3.zero end
    end
end
local function startFlip()
    G.flipActive=true
    local function setup(char)
        if not char then return end
        local hrp=char:WaitForChild("HumanoidRootPart",5); if not hrp then return end
        local hum=char:FindFirstChildOfClass("Humanoid")
        -- camera offset zeroed: BindToRenderStep at First priority below
        if hum then hum.CameraOffset=Vector3.zero end
        local _real={}; local _spoofing=false
        if G._flipHb then G._flipHb:Disconnect() end
        pcall(function() RunService:UnbindFromRenderStep("FlipRestore") end)
        G._flipHb=RunService.Heartbeat:Connect(function()
            if not hrp or not hrp.Parent then return end
            _real[1]=hrp.CFrame; _real[2]=hrp.AssemblyLinearVelocity; _spoofing=true
            local look=hrp.CFrame.LookVector
            local yaw=math.atan2(look.X,look.Z)
            hrp.CFrame=CFrame.new(hrp.Position)*CFrame.fromEulerAnglesYXZ(0,yaw,0)*CFrame.Angles(math.pi,0,0)
        end)
        -- restore at First priority so the default camera sees the upright
        RunService:BindToRenderStep("FlipRestore", Enum.RenderPriority.First.Value, function()
            if _spoofing and _real[1] then
                if hrp and hrp.Parent then hrp.CFrame=_real[1]; hrp.AssemblyLinearVelocity=_real[2] end
                _spoofing=false
            end
        end)
    end
    setup(lplr.Character)
    G._flipCharConn=lplr.CharacterAdded:Connect(function(c)
        if G.flipActive then task.wait(0.1); setup(c) end
    end)
end

-- ---- Tilt 90° (sideways roll) ----
local function stopTilt()
    G.tiltActive=false
    if G._tiltHb then G._tiltHb:Disconnect(); G._tiltHb=nil end
    pcall(function() RunService:UnbindFromRenderStep("TiltRestore") end)
    if G._tiltCharConn then G._tiltCharConn:Disconnect(); G._tiltCharConn=nil end
    local char=lplr.Character
    if char then
        local hum=char:FindFirstChildOfClass("Humanoid")
        if hum then hum.CameraOffset=Vector3.zero end
    end
end
local function startTilt()
    G.tiltActive=true
    local function setup(char)
        if not char then return end
        local hrp=char:WaitForChild("HumanoidRootPart",5); if not hrp then return end
        local hum=char:FindFirstChildOfClass("Humanoid")
        if hum then hum.CameraOffset=Vector3.zero end
        local _real={}; local _spoofing=false
        if G._tiltHb then G._tiltHb:Disconnect() end
        pcall(function() RunService:UnbindFromRenderStep("TiltRestore") end)
        G._tiltHb=RunService.Heartbeat:Connect(function()
            if not hrp or not hrp.Parent then return end
            _real[1]=hrp.CFrame; _real[2]=hrp.AssemblyLinearVelocity; _spoofing=true
            local look=hrp.CFrame.LookVector
            local yaw=math.atan2(look.X,look.Z)
            -- preserve yaw, tilt 90° on Z (sideways)
            hrp.CFrame=CFrame.new(hrp.Position)*CFrame.fromEulerAnglesYXZ(0,yaw,0)*CFrame.Angles(0,0,math.pi/2)
        end)
        RunService:BindToRenderStep("TiltRestore", Enum.RenderPriority.First.Value, function()
            if _spoofing and _real[1] then
                if hrp and hrp.Parent then hrp.CFrame=_real[1]; hrp.AssemblyLinearVelocity=_real[2] end
                _spoofing=false
            end
        end)
    end
    setup(lplr.Character)
    G._tiltCharConn=lplr.CharacterAdded:Connect(function(c)
        if G.tiltActive then task.wait(0.1); setup(c) end
    end)
end

-- ---- Backwards (180° yaw - server sees us facing the opposite way) ----

local function stopSpin()
    G.spinActive=false
    if G._spinCharConn then G._spinCharConn:Disconnect(); G._spinCharConn=nil end
    G._spinGyro=nil
    pcall(function() RunService:UnbindFromRenderStep("SpinStep") end)
    local char=lplr.Character
    if char then
        local hrp=char:FindFirstChild("HumanoidRootPart")
        if hrp then local bg=hrp:FindFirstChild("SpinGyro"); if bg then bg:Destroy() end end
        local hum=char:FindFirstChildOfClass("Humanoid")
        if hum then hum.AutoRotate=true end
    end
end
local function startSpin()
    G.spinActive=true
    local function setup(char)
        if not char then return end
        local hrp=char:WaitForChild("HumanoidRootPart",5); if not hrp then return end
        local hum=char:FindFirstChildOfClass("Humanoid")
        if hum then hum.AutoRotate=false end
        -- clear any stale gyro on this (potentially recycled) HRP before re-creating
        local existing=hrp:FindFirstChild("SpinGyro")
        if existing then existing:Destroy() end
        local gyro=Instance.new("BodyAngularVelocity")
        gyro.Name="SpinGyro"; gyro.AngularVelocity=Vector3.new(0,SPIN_SPEED,0)
        gyro.MaxTorque=Vector3.new(0,1e6,0); gyro.Parent=hrp
        G._spinGyro=gyro
    end
    setup(lplr.Character)
    if G._spinCharConn then G._spinCharConn:Disconnect() end
    G._spinCharConn=lplr.CharacterAdded:Connect(function(c)
        if G.spinActive then setup(c) end
    end)
end

local function stopIce()
    G.iceActive=false
    pcall(function() RunService:UnbindFromRenderStep("IceStep") end)
end
local function startIce()
    G.iceActive=true
    local vel=Vector3.zero
    RunService:BindToRenderStep("IceStep", Enum.RenderPriority.Character.Value, function(dt)
        if not G.iceActive then return end
        local char=lplr.Character; if not char then return end
        local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
        local cam=workspace.CurrentCamera
        local dir=Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir+=cam.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir-=cam.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir-=cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir+=cam.CFrame.RightVector end
        dir=Vector3.new(dir.X,0,dir.Z)
        local accel=dir.Magnitude>0 and dir.Unit*60*dt or Vector3.zero
        vel=(vel+accel)*ICE_SLIDE
        if vel.Magnitude>0.1 then hrp.CFrame=hrp.CFrame+vel*dt end
    end)
end

-- Sticky emotes module lives down by F.stickyEmote registration

--  CAMERA FOV
local function setFov(n)
    CUSTOM_FOV = n
    pcall(function() workspace.CurrentCamera.FieldOfView = n end)
end

--  PLAYERS: GOTO / VIEW / FLING
local function findPlayerByName(target)
    if not target then return nil end
    local p = plrs:FindFirstChild(target)
    if p then return p end
    local t = target:lower()
    for _,pp in ipairs(plrs:GetPlayers()) do
        if pp.Name:lower():find(t,1,true) or pp.DisplayName:lower():find(t,1,true) then return pp end
    end
    return nil
end

local function gotoPlayer(plr)
    if typeof(plr)=="string" then plr=findPlayerByName(plr) end
    if not plr then return end
    local tHrp=plr.Character and plr.Character:FindFirstChild("HumanoidRootPart"); if not tHrp then return end
    local lc=lplr.Character
    local hrp=lc and lc:FindFirstChild("HumanoidRootPart")
    if hrp then _uprightTp(lc, hrp, tHrp.Position + Vector3.new(3, 0, 0), tHrp.CFrame.LookVector) end
end

local _viewPrevSubject, _viewPrevType, _viewConn = nil, nil, nil
local function viewPlayer(plr)
    local cam=workspace.CurrentCamera
    if _viewConn then
        _viewConn:Disconnect(); _viewConn=nil
        if _viewPrevSubject then cam.CameraSubject=_viewPrevSubject; _viewPrevSubject=nil end
        if _viewPrevType    then cam.CameraType=_viewPrevType;       _viewPrevType=nil    end
        return
    end
    if typeof(plr)=="string" then plr=findPlayerByName(plr) end
    if not plr then return end
    local function applySubject()
        local tc=plr.Character; local hum=tc and tc:FindFirstChildOfClass("Humanoid")
        if hum then
            _viewPrevSubject=_viewPrevSubject or cam.CameraSubject; _viewPrevType=_viewPrevType or cam.CameraType
            cam.CameraSubject=hum; cam.CameraType=Enum.CameraType.Follow
        end
    end
    applySubject()
    _viewConn=plr.CharacterAdded:Connect(function() task.wait(0.1); applySubject() end)
end

-- spin-desync fling
local function flingPlayer(plr)
    if typeof(plr)=="string" then plr=findPlayerByName(plr) end
    if not plr then return end
    local target=plr
    local char=lplr.Character; if not char then return end
    local lhrp=char:FindFirstChild("HumanoidRootPart"); if not lhrp then return end
    local savedCF=lhrp.CFrame
    task.spawn(function()
        local _types={}; local _spoofing=false; local _angle=0
        local _hbConn,_rsConn
        _hbConn=RunService.Heartbeat:Connect(function()
            local c=lplr.Character; if not c then return end
            local h=c:FindFirstChild("HumanoidRootPart"); if not h then return end
            _types[1]=h.CFrame; _types[2]=h.AssemblyLinearVelocity; _spoofing=true; _angle=(_angle+45)%360
            h.CFrame=h.CFrame*CFrame.Angles(math.rad(_angle),math.rad(_angle*2),math.rad(_angle*0.5))
            h.AssemblyLinearVelocity=Vector3.new(1,1,1)*16384
        end)
        _rsConn=RunService.RenderStepped:Connect(function()
            if _spoofing and _types[1] then
                local c=lplr.Character; if not c then return end
                local h=c:FindFirstChild("HumanoidRootPart"); if not h then return end
                h.CFrame=_types[1]; h.AssemblyLinearVelocity=_types[2]; _spoofing=false
            end
        end)
        local deadline=tick()+2.5
        while tick()<deadline do
            local echar=target.Character; if not echar then break end
            local ehrp=echar:FindFirstChild("HumanoidRootPart"); if not ehrp then break end
            if not lplr.Character then break end
            local lh=lplr.Character:FindFirstChild("HumanoidRootPart"); if not lh then break end
            lh.CFrame=ehrp.CFrame*CFrame.new(0,0,0.5); task.wait(0.016)
        end
        if _hbConn then _hbConn:Disconnect() end
        if _rsConn then _rsConn:Disconnect() end
        if lplr.Character then
            local lh=lplr.Character:FindFirstChild("HumanoidRootPart")
            if lh then
                lh.Anchored=true; lh.AssemblyLinearVelocity=Vector3.zero; lh.CFrame=savedCF
                task.delay(1,function() if lh and lh.Parent then lh.Anchored=false end end)
            end
        end
    end)
end

--  FOLLOW PLAYER (pathfinding)
local _PathfindingService = game:GetService("PathfindingService")
local _follow = {
    target = nil, conn = nil, path = nil, waypoints = {}, idx = 1,
    lastCompute = 0, viz = true, vizFolder = nil,
    -- Steering state read every Heartbeat by the steerConn loop.
    steerDir  = Vector3.zero,
    steerJump = false,
    steerConn = nil,
}

-- ---- pathfinding visualization ----
local function vizClear()
    if _follow.vizFolder then _follow.vizFolder:Destroy(); _follow.vizFolder = nil end
end

local function vizDot(pos, color, size)
    local p = Instance.new("Part")
    p.Anchored = true; p.CanCollide = false
    p.CanTouch = false; p.CanQuery = false; p.CastShadow = false
    p.Shape = Enum.PartType.Ball
    p.Material = Enum.Material.Neon
    p.Color = color
    p.Size = Vector3.new(size, size, size)
    p.CFrame = CFrame.new(pos)
    p.Parent = _follow.vizFolder
    return p
end

local function vizLine(a, b, color)
    local dist = (b - a).Magnitude
    if dist < 0.1 then return end
    local p = Instance.new("Part")
    p.Anchored = true; p.CanCollide = false
    p.CanTouch = false; p.CanQuery = false; p.CastShadow = false
    p.Material = Enum.Material.Neon
    p.Color = color
    p.Transparency = 0.4
    p.Size = Vector3.new(0.3, 0.3, dist)
    p.CFrame = CFrame.new((a + b) * 0.5, b)
    p.Parent = _follow.vizFolder
end

local function vizRebuild()
    vizClear()
    if not _follow.viz then return end
    if #_follow.waypoints < 2 then return end
    _follow.vizFolder = Instance.new("Folder")
    _follow.vizFolder.Name = "_follow_path_viz"
    _follow.vizFolder.Parent = workspace
    local walkCol = Color3.fromRGB(80, 200, 255)
    local jumpCol = Color3.fromRGB(255, 180, 60)
    local nextCol = Color3.fromRGB(120, 255, 120)
    for i = 1, #_follow.waypoints do
        local wp = _follow.waypoints[i]
        local isJump = wp.Action == Enum.PathWaypointAction.Jump
        local isNext = i == _follow.idx
        local col = isNext and nextCol or (isJump and jumpCol or walkCol)
        vizDot(wp.Position, col, isNext and 1.5 or 1.0)
        if i > 1 then
            vizLine(_follow.waypoints[i - 1].Position, wp.Position, col)
        end
    end
end

local function followStop()
    _follow.target = nil  -- the worker task exits on its next yield
    _follow.waypoints = {}
    _follow.idx = 1
    vizClear()
    local c = lplr.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    if hum then
        -- Move(0) halts the continuous direction set by the worker.
        pcall(function() hum:Move(Vector3.zero, false) end)
        local hrp = c and c:FindFirstChild("HumanoidRootPart")
        if hrp then pcall(function() hum:MoveTo(hrp.Position) end) end
    end
end

-- helpers for follow worker
local function _followGetLocal()
    local c = lplr.Character
    if not c then return nil, nil end
    return c:FindFirstChildOfClass("Humanoid"), c:FindFirstChild("HumanoidRootPart")
end

local function _followGetTargetHRP()
    local t = _follow.target
    if not t or not t.Parent then return nil end
    local tc = t.Character
    return tc and tc:FindFirstChild("HumanoidRootPart")
end

-- Walk to a waypoint: issue MoveTo, then wait until either we get close

local function followPlayer(plr)
    if typeof(plr) == "string" then plr = findPlayerByName(plr) end
    if _follow.target == plr then followStop(); return end
    followStop()
    if not plr then return end
    _follow.target = plr
    _follow.path = _PathfindingService:CreatePath({
        AgentRadius     = 1.5,
        AgentHeight     = 5,
        AgentCanJump    = true,
        AgentJumpHeight = 7.2,
        AgentMaxSlope   = 45,
    })

    -- Classic Humanoid:MoveTo() + MoveToFinished:Wait() pattern.
    task.spawn(function()
        local target = plr
        while _follow.target == target do
            local hum, hrp = _followGetLocal()
            local thrp     = _followGetTargetHRP()
            if not (hum and hrp and thrp) then
                task.wait(0.2); continue
            end

            local dToTarget = (hrp.Position - thrp.Position).Magnitude

            -- Close enough: direct walk, no pathfinding.
            if dToTarget < 8 then
                pcall(function() hum:MoveTo(thrp.Position) end)
                task.wait(0.1)
                continue
            end

            -- Recompute the path to the target's CURRENT position every 0.1s
            local ok = pcall(function()
                _follow.path:ComputeAsync(hrp.Position, thrp.Position)
            end)
            if ok and _follow.path.Status == Enum.PathStatus.Success then
                _follow.waypoints = _follow.path:GetWaypoints()
                _follow.idx = 2; vizRebuild()
                local wp = _follow.waypoints[2]
                if wp then
                    if wp.Action == Enum.PathWaypointAction.Jump then
                        pcall(function() hum.Jump = true end)
                    end
                    pcall(function() hum:MoveTo(wp.Position) end)
                end
                task.wait(0.1)
            else
                -- NoPath: try direct walk; next iteration recomputes.
                pcall(function() hum:MoveTo(thrp.Position) end)
                task.wait(0.1)
            end
        end
        vizClear()
    end)
end

local function followSetVisualize(v)
    _follow.viz = v == true
    if not _follow.viz then vizClear() else vizRebuild() end
end

--  AIMBOT CORE (drawing + closest target finder + namecall hook)
local A_fovCircle, A_targetBox
local cachedTarget, cachedHitPoint = nil, nil

if Drawing and Drawing.new then
    A_fovCircle = Drawing.new("Circle")
    A_fovCircle.Thickness=1; A_fovCircle.NumSides=100
    A_fovCircle.Radius=AimbotSettings.FOVRadius; A_fovCircle.Filled=false; A_fovCircle.Visible=false
    A_fovCircle.ZIndex=999; A_fovCircle.Transparency=1; A_fovCircle.Color=Color3.fromRGB(255,255,255)
    A_targetBox = Drawing.new("Circle")
    A_targetBox.Visible=false; A_targetBox.ZIndex=999; A_targetBox.Color=Color3.fromRGB(255,255,255)
    A_targetBox.Thickness=1; A_targetBox.Filled=true; A_targetBox.Radius=4; A_targetBox.NumSides=32
end

local function aimIsVisible(plr)
    local char=plr.Character; local lchar=lplr.Character
    if not char or not lchar then return false end
    local root=char:FindFirstChild(AimbotSettings.TargetPart) or char:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local camPos=_visGetOrigin()
    local ignore={lchar,char}
    for _,p in ipairs(_cachedPlayers) do
        if p.Character and p.Character~=char and p.Character~=lchar then
            table.insert(ignore,p.Character)
        end
    end
    return isReallyVisible(camPos, root.Position, ignore)
end

local ALL_PARTS = {
    "Head","HumanoidRootPart","UpperTorso","LowerTorso",
    "RightUpperArm","LeftUpperArm","RightLowerArm","LeftLowerArm",
    "RightHand","LeftHand","RightUpperLeg","LeftUpperLeg",
    "RightLowerLeg","LeftLowerLeg","RightFoot","LeftFoot",
    "Torso","Left Arm","Right Arm","Left Leg","Right Leg",
}
local function partScreenDist(cam, part, mousePos)
    local ray = cam:ViewportPointToRay(mousePos.X, mousePos.Y)
    local t = (part.Position - ray.Origin):Dot(ray.Direction)
    local closestWorld = ray.Origin + ray.Direction * math.max(t, 0)
    local local_p = part.CFrame:PointToObjectSpace(closestWorld)
    local hs = part.Size * 0.5
    local clamped = Vector3.new(
        math.clamp(local_p.X, -hs.X, hs.X),
        math.clamp(local_p.Y, -hs.Y, hs.Y),
        math.clamp(local_p.Z, -hs.Z, hs.Z))
    local worldPoint = part.CFrame:PointToWorldSpace(clamped)
    local sp, onScreen = cam:WorldToViewportPoint(worldPoint)
    if not onScreen then return math.huge, nil end
    return (mousePos - Vector2.new(sp.X, sp.Y)).Magnitude, worldPoint
end

local function aimFindClosest()
    local cam = workspace.CurrentCamera
    local closest, closestDist, closestHit = nil, AimbotSettings.FOVRadius + 1, nil
    local mousePos = UserInputService:GetMouseLocation()
    for _, plr in ipairs(_cachedPlayers or plrs:GetPlayers()) do
        if plr == lplr then continue end
        if F.whitelist and F.whitelist.contains(plr) then continue end
        if AimbotSettings.TeamCheck and plr.Team == lplr.Team then continue end
        local char = plr.Character; if not char then continue end
        local hum = char:FindFirstChildOfClass("Humanoid")
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp or not hum or hum.Health <= 0 then continue end
        if AimbotSettings.VisibleCheck and not aimIsVisible(plr) then continue end
        if AimbotSettings.ClosestPart then
            for _, partName in ipairs(ALL_PARTS) do
                local part = char:FindFirstChild(partName); if not part then continue end
                local dist, hitPt = partScreenDist(cam, part, mousePos)
                if dist < closestDist then closest=part; closestDist=dist; closestHit=hitPt end
            end
        else
            local partName = AimbotSettings.TargetPart
            if partName == "Random" then partName = ({"Head","HumanoidRootPart"})[math.random(1,2)] end
            local targetPart = char:FindFirstChild(partName) or hrp
            local sp, onScreen = cam:WorldToViewportPoint(targetPart.Position)
            if not onScreen then continue end
            local dist = (mousePos - Vector2.new(sp.X, sp.Y)).Magnitude
            if dist < closestDist then closest=targetPart; closestDist=dist; closestHit=targetPart.Position end
        end
    end
    return closest, closestHit
end

-- aimbot per-frame: update cached target + draw.
RunService.RenderStepped:Connect(function()
    if not AimbotSettings.Enabled
        and not AimbotSettings.ShowFOV
        and not AimbotSettings.ShowTarget then
        -- Cheap idle path: hide any drawings still left visible from
        if cachedTarget then cachedTarget = nil; cachedHitPoint = nil end
        if A_fovCircle and A_fovCircle.Visible  then A_fovCircle.Visible  = false end
        if A_targetBox and A_targetBox.Visible  then A_targetBox.Visible  = false end
        return
    end
    if AimbotSettings.Enabled then
        cachedTarget, cachedHitPoint = aimFindClosest()
    else
        cachedTarget = nil; cachedHitPoint = nil
    end
    if A_fovCircle then
        A_fovCircle.Visible = AimbotSettings.ShowFOV
        if AimbotSettings.ShowFOV then
            local mousePos = UserInputService:GetMouseLocation()
            A_fovCircle.Radius = AimbotSettings.FOVRadius
            A_fovCircle.Position = mousePos
        end
        if AimbotSettings.ShowTarget and AimbotSettings.Enabled and cachedTarget then
            local sp, onScreen = workspace.CurrentCamera:WorldToViewportPoint(cachedTarget.Position)
            if onScreen then
                A_targetBox.Position = Vector2.new(sp.X, sp.Y)
                A_targetBox.Visible = true
            else A_targetBox.Visible = false end
        else A_targetBox.Visible = false end
    end
end)

local function saDirection(origin, targetPos) return (targetPos - origin).Unit * 1000 end

if hookmetamethod then
    -- track tool presence with event-driven updates instead of per-frame
    local hasTool = false
    local _toolWatchers = {}
    local function _refreshTool(c)
        if not c then hasTool = false; return end
        hasTool = false
        for _, v in ipairs(c:GetChildren()) do
            if v:IsA("Tool") then hasTool = true; break end
        end
    end
    local function _hookChar(c)
        if not c then return end
        for _, conn in ipairs(_toolWatchers) do pcall(function() conn:Disconnect() end) end
        _toolWatchers = {}
        table.insert(_toolWatchers, c.ChildAdded:Connect(function(ch) if ch:IsA("Tool") then hasTool = true end end))
        table.insert(_toolWatchers, c.ChildRemoved:Connect(function(ch) if ch:IsA("Tool") then _refreshTool(c) end end))
        _refreshTool(c)
    end
    lplr.CharacterAdded:Connect(_hookChar)
    if lplr.Character then _hookChar(lplr.Character) end

    -- guard against re-stacking on script reload: if we've already
    if not getgenv()._F_NAMECALL_HOOKED then
        getgenv()._F_NAMECALL_HOOKED = true
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(...)
        -- Cheap-bool early-outs FIRST. Roblox calls __namecall thousands of
        if not AimbotSettings.Enabled then return oldNamecall(...) end
        if not cachedTarget then return oldNamecall(...) end
        if not hasTool then return oldNamecall(...) end
        if checkcaller() then return oldNamecall(...) end
        local method = getnamecallmethod()
        if method ~= "Raycast" and method ~= "FindPartOnRay" and method ~= "findPartOnRay"
            and method ~= "FindPartOnRayWithIgnoreList" and method ~= "FindPartOnRayWithWhitelist" then
            return oldNamecall(...)
        end
        if math.random(100) > AimbotSettings.HitChance then return oldNamecall(...) end
        local args = {...}
        if not rawequal(args[1], workspace) then return oldNamecall(...) end
        local _aimBase = cachedHitPoint or cachedTarget.Position
        local targetPos = AimbotSettings.Prediction
            and (_aimBase + (cachedTarget.AssemblyLinearVelocity * AimbotSettings.PredictionAmount))
            or _aimBase
        local m = AimbotSettings.Method
        if method == "Raycast" then
            if typeof(args[2]) ~= "Vector3" then return oldNamecall(...) end
            local dir = args[3]
            if typeof(dir) == "Vector3" and dir.Magnitude < 20 then return oldNamecall(...) end
            if m == "All" or m == "Raycast" then
                args[3] = saDirection(args[2], targetPos)
                return oldNamecall(unpack(args))
            end
        else
            local ray = args[2]; if not ray then return oldNamecall(...) end
            local origin = ray.Origin; if not origin then return oldNamecall(...) end
            if ray.Direction.Magnitude < 20 then return oldNamecall(...) end
            local matches = (m == "All")
                or (m == "FindPartOnRay" and (method == "FindPartOnRay" or method == "findPartOnRay"))
                or (m == "FindPartOnRayWithIgnoreList" and method == "FindPartOnRayWithIgnoreList")
                or (m == "FindPartOnRayWithWhitelist" and method == "FindPartOnRayWithWhitelist")
            if matches then
                args[2] = Ray.new(origin, saDirection(origin, targetPos))
                return oldNamecall(unpack(args))
            end
        end
        return oldNamecall(...)
    end))

    -- __index hook for Mouse.Hit / Mouse.Target
    local mouse = lplr:GetMouse()
    local oldIndex
    oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
        if not AimbotSettings.Enabled then return oldIndex(self, key) end
        if AimbotSettings.Method ~= "Mouse.Hit/Target" then return oldIndex(self, key) end
        if not rawequal(self, mouse) then return oldIndex(self, key) end
        if checkcaller() then return oldIndex(self, key) end
        if key ~= "Hit" and key ~= "hit" and key ~= "Target" and key ~= "target" then
            return oldIndex(self, key)
        end
        local part = cachedTarget; if not part then return oldIndex(self, key) end
        local _aimBase = cachedHitPoint or part.Position
        local tp = AimbotSettings.Prediction
            and (_aimBase + (part.AssemblyLinearVelocity * AimbotSettings.PredictionAmount))
            or _aimBase
        if key == "Target" or key == "target" then return part end
        return CFrame.new(tp)
    end))
    end -- _F_NAMECALL_HOOKED guard
end

do  -- scope camlock + triggerbot locals so they don't count toward the
    -- top-level 200-local (register) limit. The RenderStepped/Heartbeat
local CL_fovCircle
if Drawing and Drawing.new then
    CL_fovCircle = Drawing.new("Circle")
    CL_fovCircle.Thickness=1; CL_fovCircle.NumSides=100
    CL_fovCircle.Radius=CamLockSettings.FOVRadius; CL_fovCircle.Filled=false; CL_fovCircle.Visible=false
    CL_fovCircle.ZIndex=999; CL_fovCircle.Transparency=1; CL_fovCircle.Color=Color3.fromRGB(255,200,0)
end

local clStickyTarget = nil

-- true if WE currently have a Tool equipped (used by Tool Check on camlock +
local function lpHasTool()
    local c = lplr.Character
    return c ~= nil and c:FindFirstChildOfClass("Tool") ~= nil
end

-- relative mouse-move (executor global) used by camlock "Mouse" mode; nil if
local _mouseMoveRel = nil
pcall(function() _mouseMoveRel = mousemoverel end)

local function clIsVisible(plr)
    local char=plr.Character; local lchar=lplr.Character
    if not char or not lchar then return false end
    local root=char:FindFirstChild(CamLockSettings.TargetPart) or char:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local camPos=_visGetOrigin()
    local ignore={lchar,char}
    for _,p in ipairs(_cachedPlayers) do
        if p.Character and p.Character~=char and p.Character~=lchar then table.insert(ignore,p.Character) end
    end
    return isReallyVisible(camPos, root.Position, ignore)
end

-- visibility check for an arbitrary target PART (for camlock OnlyVisible)
local function clPartVisible(part)
    if not part then return false end
    local lchar = lplr.Character
    if not lchar then return false end
    local pchar = part.Parent
    local camPos = _visGetOrigin()
    local ignore = { lchar }
    if pchar then table.insert(ignore, pchar) end
    for _, p in ipairs(_cachedPlayers) do
        if p.Character and p.Character ~= pchar and p.Character ~= lchar then table.insert(ignore, p.Character) end
    end
    return isReallyVisible(camPos, part.Position, ignore)
end

local function clIsAlive(plr)
    if plr == lplr then return false end
    if CamLockSettings.TeamCheck and plr.Team == lplr.Team then return false end
    local char = plr.Character; if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    return hrp ~= nil and hum ~= nil and hum.Health > 0
end

local function clIsValidTarget(plr)
    if plr == lplr then return false end
    if CamLockSettings.TeamCheck and plr.Team == lplr.Team then return false end
    local char = plr.Character; if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp or not hum or hum.Health <= 0 then return false end
    if CamLockSettings.VisibleCheck and not clIsVisible(plr) then return false end
    return true, char, hrp
end

local function clGetPartForPlayer(char, hrp)
    if CamLockSettings.ClosestPart then
        local cam = workspace.CurrentCamera
        local mousePos = UserInputService:GetMouseLocation()
        local best, bestDist = hrp, math.huge
        for _, pname in ipairs(ALL_PARTS) do
            local part = char:FindFirstChild(pname); if not part then continue end
            local d = partScreenDist(cam, part, mousePos)
            if d < bestDist then bestDist = d; best = part end
        end
        return best
    else
        local pname = CamLockSettings.TargetPart
        if pname == "Random" then pname = ({"Head","HumanoidRootPart"})[math.random(1,2)] end
        return char:FindFirstChild(pname) or hrp
    end
end

local function clFindTarget()
    local cam = workspace.CurrentCamera
    local mousePos = UserInputService:GetMouseLocation()
    if CamLockSettings.Sticky and clStickyTarget then
        local sPlr = plrs:GetPlayerFromCharacter(clStickyTarget.Parent)
        if sPlr and clIsAlive(sPlr) then
            local char = sPlr.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            -- keep the sticky target ONLY while they're still inside the FOV;
            local checkPart = hrp and (char:FindFirstChild(CamLockSettings.TargetPart) or hrp)
            if checkPart then
                local sp, onScreen = cam:WorldToViewportPoint(checkPart.Position)
                if onScreen and (mousePos - Vector2.new(sp.X, sp.Y)).Magnitude <= CamLockSettings.FOVRadius then
                    clStickyTarget = clGetPartForPlayer(char, hrp)
                    return clStickyTarget
                end
            end
        end
        clStickyTarget = nil
    end
    local closest, closestDist = nil, CamLockSettings.FOVRadius + 1
    for _, plr in ipairs(_cachedPlayers or plrs:GetPlayers()) do
        local ok, char, hrp = clIsValidTarget(plr); if not ok then continue end
        local checkPart = char:FindFirstChild(CamLockSettings.TargetPart) or hrp
        local sp, onScreen = cam:WorldToViewportPoint(checkPart.Position)
        if not onScreen then continue end
        local d = (mousePos - Vector2.new(sp.X, sp.Y)).Magnitude
        if d < closestDist then closestDist = d; closest = clGetPartForPlayer(char, hrp) end
    end
    clStickyTarget = closest
    return closest
end

RunService.RenderStepped:Connect(function(dt)
    -- Fast early-out: skip the entire camlock per-frame when nothing
    if not CamLockSettings.Enabled and not CamLockSettings.ShowFOV then
        if clStickyTarget then clStickyTarget = nil end
        if CL_fovCircle and CL_fovCircle.Visible then CL_fovCircle.Visible = false end
        return
    end
    if CL_fovCircle then
        CL_fovCircle.Visible = CamLockSettings.ShowFOV
        if CamLockSettings.ShowFOV then
            local mp = UserInputService:GetMouseLocation()
            CL_fovCircle.Radius = CamLockSettings.FOVRadius
            CL_fovCircle.Position = mp
        end
    end
    if not CamLockSettings.Enabled then clStickyTarget = nil; return end
    if G.freecamActive then return end
    -- "Only in 1st Person": only lock when the mouse is locked to center
    if CamLockSettings.OnlyFirstPerson
        and not (UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
            or UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)) then
        clStickyTarget = nil
        return
    end
    -- Tool Check: don't lock while we have no tool equipped
    if CamLockSettings.ToolCheck and not lpHasTool() then return end
    local part = clFindTarget(); if not part then return end
    -- Only visible: pause the lock while the target is behind cover; it
    if CamLockSettings.OnlyVisible and not clPartVisible(part) then return end
    local targetPos = CamLockSettings.Prediction
        and (part.Position + (part.AssemblyLinearVelocity * CamLockSettings.PredictionAmount))
        or part.Position
    local cam = workspace.CurrentCamera
    local alpha = math.clamp(1 - (CamLockSettings.Smoothing ^ (dt * 60)), 0, 1)
    if CamLockSettings.Mode == "Mouse" then
        -- Mouse mode: nudge the MOUSE toward the target's on-screen position.
        if _mouseMoveRel then
            local sp, onScreen = cam:WorldToViewportPoint(targetPos)
            if onScreen then
                local mp = UserInputService:GetMouseLocation()
                local dx, dy = sp.X - mp.X, sp.Y - mp.Y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist > 0.5 then
                    -- pure smoothed step (Smoothing controls the speed). Low
                    local mvx, mvy = dx * alpha, dy * alpha
                    -- only floor to a 1px step so a sub-pixel value doesn't
                    if math.abs(mvx) < 1 and math.abs(mvy) < 1 then
                        if dist <= 1 then
                            mvx, mvy = dx, dy           -- close the final pixel exactly
                        else
                            mvx, mvy = dx / dist, dy / dist  -- 1px toward target
                        end
                    end
                    pcall(_mouseMoveRel, mvx, mvy)
                end
            end
        end
    else
        -- Camera mode: steer the camera toward the target (smoothed)
        local desired = CFrame.new(cam.CFrame.Position, targetPos)
        cam.CFrame = cam.CFrame:Lerp(desired, alpha)
    end
end)

--  TRIGGERBOT
local TB_fovCircle, TB_targetBox
if Drawing and Drawing.new then
    TB_fovCircle = Drawing.new("Circle"); TB_fovCircle.Thickness=1; TB_fovCircle.NumSides=100
    TB_fovCircle.Radius=TrigSettings.FOVRadius; TB_fovCircle.Filled=false; TB_fovCircle.Visible=false
    TB_fovCircle.Color=Color3.fromRGB(255,180,0); TB_fovCircle.Transparency=1

    TB_targetBox = Drawing.new("Circle")
    TB_targetBox.Visible=false; TB_targetBox.ZIndex=999
    TB_targetBox.Color=Color3.fromRGB(255,180,0)
    TB_targetBox.Thickness=1; TB_targetBox.Filled=true; TB_targetBox.Radius=4; TB_targetBox.NumSides=32
end

-- map a chosen part name to the equivalent on the OTHER rig, so picking an
local _PART_EQUIV = {
    -- R15 name -> R6 name
    UpperTorso = "Torso", LowerTorso = "Torso",
    LeftUpperArm = "Left Arm", LeftLowerArm = "Left Arm", LeftHand = "Left Arm",
    RightUpperArm = "Right Arm", RightLowerArm = "Right Arm", RightHand = "Right Arm",
    LeftUpperLeg = "Left Leg", LeftLowerLeg = "Left Leg", LeftFoot = "Left Leg",
    RightUpperLeg = "Right Leg", RightLowerLeg = "Right Leg", RightFoot = "Right Leg",
    -- R6 name -> R15 name
    Torso = "UpperTorso",
    ["Left Arm"] = "LeftUpperArm", ["Right Arm"] = "RightUpperArm",
    ["Left Leg"] = "LeftUpperLeg", ["Right Leg"] = "RightUpperLeg",
}

-- pick the target part by name, with R6/R15 friendly fallbacks
local function tbResolvePart(char, name)
    if not char then return nil end
    if name == "Random" then
        local parts = {}
        for _, p in ipairs(char:GetChildren()) do
            if p:IsA("BasePart") then table.insert(parts, p) end
        end
        if #parts == 0 then return char:FindFirstChild("HumanoidRootPart") end
        return parts[math.random(1, #parts)]
    end
    -- exact match first
    local p = char:FindFirstChild(name)
    if p and p:IsA("BasePart") then return p end
    -- try the other-rig equivalent (e.g. UpperTorso <-> Torso)
    local alt = _PART_EQUIV[name]
    if alt then
        p = char:FindFirstChild(alt)
        if p and p:IsA("BasePart") then return p end
    end
    -- last resort
    return char:FindFirstChild("HumanoidRootPart")
end

local function trigIsVisible(plr)
    local char=plr.Character; local lchar=lplr.Character
    if not char or not lchar then return false end
    local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return false end
    local camPos=_visGetOrigin()
    local ignore={lchar,char}
    for _,p in ipairs(_cachedPlayers) do
        if p.Character and p.Character~=char and p.Character~=lchar then table.insert(ignore,p.Character) end
    end
    return isReallyVisible(camPos, hrp.Position, ignore)
end

local _trigLastShot = 0
local _trigCurrentPart = nil  -- currently-best target part this frame, for ShowTarget
local _trigScanAccum = 0
local _trigHitPlr, _trigHitPart = nil, nil
RunService.Heartbeat:Connect(function(dt)
    -- Fast early-out: skip GetMouseLocation + camera lookup + everything
    if not TrigSettings.Enabled and not TrigSettings.ShowFOV and not TrigSettings.ShowTarget then
        if TB_fovCircle and TB_fovCircle.Visible then TB_fovCircle.Visible = false end
        if TB_targetBox and TB_targetBox.Visible then TB_targetBox.Visible = false end
        return
    end
    local cam = workspace.CurrentCamera
    local mousePos = UserInputService:GetMouseLocation()

    if TB_fovCircle then
        TB_fovCircle.Visible = TrigSettings.ShowFOV
        if TrigSettings.ShowFOV then
            TB_fovCircle.Position = mousePos
            TB_fovCircle.Radius   = TrigSettings.FOVRadius
        end
    end

    -- early-out: if nothing is asking for a target this frame, skip the
    if not TrigSettings.Enabled and not TrigSettings.ShowTarget then
        if TB_targetBox then TB_targetBox.Visible = false end
        return
    end

    -- find best player inside FOV.
    _trigScanAccum = _trigScanAccum + (dt or 0)
    if _trigScanAccum >= (1 / 120) or _trigHitPlr == nil then
        _trigScanAccum = 0
        local hitPlr, hitPart, bestD = nil, nil, math.huge
        for _, plr in ipairs(_cachedPlayers or plrs:GetPlayers()) do
            if plr == lplr then continue end
            if F.whitelist and F.whitelist.contains(plr) then continue end
            if TrigSettings.TeamCheck and plr.Team == lplr.Team then continue end
            local char = plr.Character; if not char then continue end
            local hum = char:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 then continue end
            if TrigSettings.VisibleCheck and not trigIsVisible(plr) then continue end

            if TrigSettings.TargetPart == "All" then
                for _, part in ipairs(char:GetChildren()) do
                    if part:IsA("BasePart") then
                        local sp, onScreen = cam:WorldToViewportPoint(part.Position)
                        if onScreen then
                            local d = (mousePos - Vector2.new(sp.X, sp.Y)).Magnitude
                            if d <= TrigSettings.FOVRadius and d < bestD then
                                hitPlr, hitPart, bestD = plr, part, d
                            end
                        end
                    end
                end
            else
                local part = tbResolvePart(char, TrigSettings.TargetPart)
                if part then
                    local sp, onScreen = cam:WorldToViewportPoint(part.Position)
                    if onScreen then
                        local d = (mousePos - Vector2.new(sp.X, sp.Y)).Magnitude
                        if d <= TrigSettings.FOVRadius and d < bestD then
                            hitPlr, hitPart, bestD = plr, part, d
                        end
                    end
                end
            end
        end
        _trigHitPlr, _trigHitPart = hitPlr, hitPart
    end
    local hitPlr, hitPart = _trigHitPlr, _trigHitPart
    -- drop a stale cached target if its character/part went away
    if hitPart and not hitPart.Parent then hitPlr, hitPart = nil, nil; _trigHitPlr, _trigHitPart = nil, nil end
    _trigCurrentPart = hitPart

    if TB_targetBox then
        if TrigSettings.ShowTarget and TrigSettings.Enabled and hitPart then
            local sp, onScreen = cam:WorldToViewportPoint(hitPart.Position)
            if onScreen then
                TB_targetBox.Position = Vector2.new(sp.X, sp.Y)
                TB_targetBox.Visible  = true
            else TB_targetBox.Visible = false end
        else TB_targetBox.Visible = false end
    end

    if not TrigSettings.Enabled then return end
    -- Tool Check: don't fire a click while we have no tool equipped
    if TrigSettings.ToolCheck and not lpHasTool() then return end
    if (tick() - _trigLastShot) * 1000 < TrigSettings.ClickDelay then return end
    if not hitPlr then return end
    _trigLastShot = tick()
    pcall(function()
        local vim = VirtualInputManager
        vim:SendMouseButtonEvent(0,0,0,true,game,0)
        vim:SendMouseButtonEvent(0,0,0,false,game,0)
    end)
end)
end  -- end camlock + triggerbot scope

--  RAGEBOT CORE
local _rbMousePos = UserInputService:GetMouseLocation()
UserInputService.InputChanged:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseMovement then
        _rbMousePos = UserInputService:GetMouseLocation()
    end
end)

local rbCachedTarget = nil
local _rbFaceStepBound = false
-- Snapshot of Humanoid.AutoRotate before we forced it off lives on G
local rbOrbitAngle = 0

-- target visualization
local RB_targetLine, RB_outlineHL
if Drawing and Drawing.new then
    RB_targetLine = Drawing.new("Line")
    RB_targetLine.Visible     = false
    RB_targetLine.Thickness   = 2
    RB_targetLine.Color       = Color3.fromRGB(255, 80, 80)
    RB_targetLine.Transparency= 1
end
local function ensureRBHighlight()
    if RB_outlineHL and RB_outlineHL.Parent then return RB_outlineHL end
    RB_outlineHL = Instance.new("Highlight")
    RB_outlineHL.Name = "_wh_rb_outline"
    RB_outlineHL.FillTransparency    = 1
    RB_outlineHL.OutlineColor        = Color3.fromRGB(255, 80, 80)
    RB_outlineHL.OutlineTransparency = 0
    RB_outlineHL.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
    RB_outlineHL.Enabled             = false
    pcall(function() RB_outlineHL.Parent = game:GetService("CoreGui") end)
    if not RB_outlineHL.Parent then RB_outlineHL.Parent = workspace end
    return RB_outlineHL
end

local function rbIsVisible(plr)
    local char = plr.Character; local lchar = lplr.Character
    if not char or not lchar then return false end
    local root = char:FindFirstChild("HumanoidRootPart"); if not root then return false end
    local camPos = _visGetOrigin()
    local ignore = {lchar, char}
    for _, p in ipairs(plrs:GetPlayers()) do
        if p.Character and p.Character ~= char and p.Character ~= lchar then table.insert(ignore, p.Character) end
    end
    return isReallyVisible(camPos, root.Position, ignore)
end

-- Returns true if the target should be completely skipped from selection
local function rbIgnoreByKnocked(plr)
    if not RageSettings.IgnoreKnocked then return false end
    local hc = F and F.games and F.games.hoodCustoms
    if not hc or not hc.isKnocked then return false end
    local ok, knocked = pcall(hc.isKnocked, plr)
    return ok and knocked
end

-- score a candidate target for a priority mode. lower = better.
local function rbScoreTarget(plr, char, hrp, hum, lhrp, cam, mousePos, camPos, camLook)
    local mode = RageSettings.Priority or "Closest"
    if RageSettings.SwitchByMouse and mode == "Closest" then mode = "Mouse" end
    if mode == "Mouse" then
        local sp, onScreen = cam:WorldToViewportPoint(hrp.Position)
        if not onScreen then return math.huge end
        return (mousePos - Vector2.new(sp.X, sp.Y)).Magnitude
    elseif mode == "Camera" then
        local toTarget = (hrp.Position - camPos).Unit
        local dotV = toTarget:Dot(camLook)
        if dotV <= 0 then return math.huge end  -- behind us
        return 1 - dotV  -- closer to 0 = more directly in front
    elseif mode == "LowestHP" then
        return hum.Health
    elseif mode == "HighestThreat" then
        -- threat = closeness + tool drawn. lower distance + tool out = best.
        local d = lhrp and (lhrp.Position - hrp.Position).Magnitude or math.huge
        local hasTool = char:FindFirstChildOfClass("Tool") ~= nil
        return d + (hasTool and 0 or 1000)
    end
    -- Closest (default fallback)
    return lhrp and (lhrp.Position - hrp.Position).Magnitude or math.huge
end

local function rbGetTarget()
    if #_rbTargetList > 0 then
        local lchar=lplr.Character
        local lhrp=lchar and lchar:FindFirstChild("HumanoidRootPart")
        local cam = workspace.CurrentCamera
        local mousePos = UserInputService:GetMouseLocation()
        local camCF = cam.CFrame
        local camPos, camLook = camCF.Position, camCF.LookVector
        local best, bestScore = nil, math.huge
        for _,entry in ipairs(_rbTargetList) do
            if not entry.plr or not entry.plr.Parent then
                for _,p in ipairs(plrs:GetPlayers()) do
                    if p.UserId==entry.userId then entry.plr=p; break end
                end
            end
            local plr=entry.plr; if not plr or not plr.Parent then continue end
            if F.whitelist and F.whitelist.contains(plr) then continue end  -- skip whitelisted players
            local char=plr.Character; local hrp=char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then continue end
            local hum=char:FindFirstChildOfClass("Humanoid"); if not hum or hum.Health<=0 then continue end
            if rbIgnoreByKnocked(plr) then continue end
            local score = rbScoreTarget(plr, char, hrp, hum, lhrp, cam, mousePos, camPos, camLook)
            if score < bestScore then bestScore = score; best = plr end
        end
        if best then RageSettings.TargetPlayer=best; RageSettings.TargetUserId=best.UserId; return best end
    end
    local uid=RageSettings.TargetUserId; if not uid then return nil end
    local plr=RageSettings.TargetPlayer
    if plr and plr.Parent and plr.UserId==uid then
        if rbIgnoreByKnocked(plr) then return nil end
        return plr
    end
    for _,p in ipairs(plrs:GetPlayers()) do
        if p.UserId==uid then
            if F.whitelist and F.whitelist.contains(p) then return nil end
            if rbIgnoreByKnocked(p) then return nil end
            RageSettings.TargetPlayer=p; return p
        end
    end
    return nil
end

-- expose lockClosest / unlock / tpBehind / etc.
local function rbLockClosest()
    local cam = workspace.CurrentCamera
    local mousePos = UserInputService:GetMouseLocation()
    local best, bestDist = nil, math.huge
    for _, plr in ipairs(plrs:GetPlayers()) do
        if plr == lplr then continue end
        if F.whitelist and F.whitelist.contains(plr) then continue end
        local char = plr.Character; local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end
        local sp, onScreen = cam:WorldToViewportPoint(hrp.Position)
        if not onScreen then continue end
        local d = (mousePos - Vector2.new(sp.X, sp.Y)).Magnitude
        if d < bestDist then bestDist = d; best = plr end
    end
    if best then
        _rbTargetList = {{userId=best.UserId, plr=best}}
        RageSettings.TargetPlayer = best
        RageSettings.TargetUserId = best.UserId
    end
    return best
end
local function rbLockByPlayer(plr)
    if typeof(plr)=="string" then plr=findPlayerByName(plr) end
    if not plr then return nil end
    _rbTargetList = {{userId=plr.UserId, plr=plr}}
    RageSettings.TargetPlayer = plr
    RageSettings.TargetUserId = plr.UserId
    return plr
end
local function rbAddTarget(plr)
    if typeof(plr)=="string" then plr=findPlayerByName(plr) end
    if not plr then return end
    for _,e in ipairs(_rbTargetList) do if e.userId==plr.UserId then return end end
    table.insert(_rbTargetList, {userId=plr.UserId, plr=plr})
end
local function rbUnlock()
    _rbTargetList = {}
    RageSettings.TargetPlayer = nil
    RageSettings.TargetUserId = nil
end
local function rbTpBehind()
    local plr = RageSettings.TargetPlayer; if not plr then return end
    local char = plr.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local lchar = lplr.Character
    local lhrp = lchar and lchar:FindFirstChild("HumanoidRootPart")
    if not lhrp then return end

    -- direction the target is facing, projected horizontal
    local lv = hrp.CFrame.LookVector
    local horiz = Vector3.new(lv.X, 0, lv.Z)
    if horiz.Magnitude < 0.01 then horiz = Vector3.new(0, 0, -1) end
    horiz = horiz.Unit

    -- TpBehindDist=0 (default) puts us inside the target's HRP, larger values
    local position = hrp.Position - horiz * (RageSettings.TpBehindDist or 0)
    _uprightTp(lchar, lhrp, position, horiz)
end

-- ragebot per-frame: face target / orbit / cam snap / speed panic
RunService.RenderStepped:Connect(function(dt)
    -- early-out when nothing is asking for ragebot work - skips the
    if not RageSettings.SilentForce
        and not RageSettings.AutoShoot
        and not RageSettings.ShowLine
        and not RageSettings.ShowOutline
        and not RageSettings.CamSnap
        and not RageSettings.FaceTarget
        and not RageSettings.SpeedPanic
        and not RageSettings.TargetPlayer
        and (not _rbTargetList or #_rbTargetList == 0)
    then
        if RB_targetLine then RB_targetLine.Visible = false end
        if RB_outlineHL  then RB_outlineHL.Enabled  = false end
        rbCachedTarget = nil
        return
    end
    local plr = rbGetTarget()
    local char = plr and plr.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    rbCachedTarget = hrp

    -- target line origin: Bottom / Center / Top / Mouse
    if RB_targetLine then
        local function isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

        local cam = hrp and workspace.CurrentCamera
        local pos = hrp and hrp.Position
        local validPos = pos and isFinite(pos.X) and isFinite(pos.Y) and isFinite(pos.Z)

        if RageSettings.ShowLine and hrp and validPos and cam then
            local sp = cam:WorldToViewportPoint(pos)
            local vs = cam.ViewportSize
            local toX, toY = sp.X, sp.Y

            -- if behind camera, mirror across screen center and push outward
            if sp.Z < 0 then
                local cx, cy = vs.X * 0.5, vs.Y * 0.5
                toX = cx + (cx - toX) * 4
                toY = cy + (cy - toY) * 4
            end

            -- if anything went non-finite during projection, hide instead of
            if not (isFinite(toX) and isFinite(toY)) then
                RB_targetLine.Visible = false
            else
                local origin = RageSettings.LineOrigin
                local from
                if origin == "Top" then
                    from = Vector2.new(vs.X * 0.5, 0)
                elseif origin == "Center" then
                    from = Vector2.new(vs.X * 0.5, vs.Y * 0.5)
                elseif origin == "Mouse" then
                    from = UserInputService:GetMouseLocation()
                else
                    from = Vector2.new(vs.X * 0.5, vs.Y)
                end
                RB_targetLine.From = from
                RB_targetLine.To   = Vector2.new(toX, toY)
                RB_targetLine.Color = RageSettings.LineColor or Color3.fromRGB(255, 80, 80)
                RB_targetLine.Visible = true
            end
        else
            RB_targetLine.Visible = false
        end
    end

    -- target outline: highlight on the locked character
    if RageSettings.ShowOutline and char then
        local hl = ensureRBHighlight()
        if hl.Adornee ~= char then hl.Adornee = char end
        hl.OutlineColor = RageSettings.OutlineColor or Color3.fromRGB(255, 80, 80)
        hl.Enabled = true
    elseif RB_outlineHL then
        RB_outlineHL.Enabled = false
    end

    if RageSettings.CamSnap and hrp then
        local cam = workspace.CurrentCamera
        local desired = CFrame.new(cam.CFrame.Position, hrp.Position)
        local alpha = math.clamp(1-(RageSettings.CamSmoothing^(dt*60)),0,1)
        cam.CFrame = cam.CFrame:Lerp(desired, alpha)
    end

    local lc = lplr.Character
    local lhrp = lc and lc:FindFirstChild("HumanoidRootPart")
    if RageSettings.FaceTarget and hrp and lhrp then
        if not _rbFaceStepBound then
            _rbFaceStepBound = true
            -- Bind at Last+1 so we run AFTER everything:
            RunService:BindToRenderStep("rbFaceStep", Enum.RenderPriority.Last.Value+1, function()
                if not RageSettings.FaceTarget then
                    RunService:UnbindFromRenderStep("rbFaceStep")
                    _rbFaceStepBound = false
                    -- restore the AutoRotate we forced off below
                    local c   = lplr.Character
                    local hum = c and c:FindFirstChildOfClass("Humanoid")
                    if hum and G._rbFaceSavedAutoRotate ~= nil then
                        pcall(function() hum.AutoRotate = G._rbFaceSavedAutoRotate end)
                    end
                    G._rbFaceSavedAutoRotate = nil
                    return
                end
                local char2=lplr.Character; if not char2 then return end
                local lhrp2=char2:FindFirstChild("HumanoidRootPart"); if not lhrp2 then return end
                -- Pin AutoRotate=false so the engine doesn't rotate the
                local hum = char2:FindFirstChildOfClass("Humanoid")
                if hum then
                    if G._rbFaceSavedAutoRotate == nil then
                        G._rbFaceSavedAutoRotate = hum.AutoRotate
                    end
                    if hum.AutoRotate then
                        pcall(function() hum.AutoRotate = false end)
                    end
                end
                local tplr=RageSettings.TargetPlayer; if not tplr then return end
                local tchar=tplr.Character; if not tchar then return end
                local thrp=tchar:FindFirstChild("HumanoidRootPart"); if not thrp then return end
                local dir=(thrp.Position-lhrp2.Position)*Vector3.new(1,0,1)
                if dir.Magnitude<0.1 then return end
                local yaw=math.atan2(-dir.X,-dir.Z)
                lhrp2.CFrame=CFrame.new(lhrp2.Position)*CFrame.fromEulerAnglesYXZ(0,yaw,0)
            end)
        end
    elseif lhrp then
        if _rbFaceStepBound then
            RunService:UnbindFromRenderStep("rbFaceStep")
            _rbFaceStepBound=false
            -- restore AutoRotate when face-target toggles off via the outer
            local hum = lc:FindFirstChildOfClass("Humanoid")
            if hum and G._rbFaceSavedAutoRotate ~= nil then
                pcall(function() hum.AutoRotate = G._rbFaceSavedAutoRotate end)
            end
            G._rbFaceSavedAutoRotate = nil
        end
    end

    if RageSettings.SpeedPanic and char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed=0; hum.JumpPower=0 end
    end

    if RageSettings.Orbit and hrp then
        if lhrp then
            rbOrbitAngle = (rbOrbitAngle + RageSettings.OrbitSpeed * dt) % 360
            local rad = math.rad(rbOrbitAngle); local d = RageSettings.OrbitDistance
            local targetPos = hrp.Position + Vector3.new(math.cos(rad)*d, RageSettings.OrbitHeight, math.sin(rad)*d)
            lhrp.CFrame = CFrame.new(targetPos, hrp.Position)
        end
    end
end)

-- silent force hooks (independent of aimbot).
if hookmetamethod and not getgenv()._F_RB_NAMECALL_HOOKED then
    getgenv()._F_RB_NAMECALL_HOOKED = true
    local rbOldNamecall
    rbOldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(...)
        -- cheap bool / userdata checks first; only do getnamecallmethod
        if not RageSettings.SilentForce then return rbOldNamecall(...) end
        local part = rbCachedTarget; if not part then return rbOldNamecall(...) end
        if RageSettings.SilentMethod == "Mouse.Hit/Target" then return rbOldNamecall(...) end
        if checkcaller() then return rbOldNamecall(...) end
        local method = getnamecallmethod()
        if method ~= "Raycast" and method ~= "FindPartOnRay" and method ~= "findPartOnRay"
            and method ~= "FindPartOnRayWithIgnoreList" and method ~= "FindPartOnRayWithWhitelist" then
            return rbOldNamecall(...)
        end
        local args = {...}
        if not rawequal(args[1], workspace) then return rbOldNamecall(...) end
        local m = RageSettings.SilentMethod; local targetPos = part.Position
        if method == "Raycast" then
            if typeof(args[2]) ~= "Vector3" then return rbOldNamecall(...) end
            if args[3] and typeof(args[3])=="Vector3" and args[3].Magnitude < 20 then return rbOldNamecall(...) end
            if m=="All" or m=="Raycast" then
                args[3] = (targetPos - args[2]).Unit * 1000
                return rbOldNamecall(unpack(args))
            end
        else
            local ray = args[2]; if not ray then return rbOldNamecall(...) end
            local origin = ray.Origin; if not origin then return rbOldNamecall(...) end
            if ray.Direction.Magnitude < 20 then return rbOldNamecall(...) end
            if m=="All" or (m=="FindPartOnRay" and (method=="FindPartOnRay" or method=="findPartOnRay"))
                or (m=="FindPartOnRayWithIgnoreList" and method=="FindPartOnRayWithIgnoreList")
                or (m=="FindPartOnRayWithWhitelist" and method=="FindPartOnRayWithWhitelist") then
                args[2] = Ray.new(origin, (targetPos-origin).Unit*1000)
                return rbOldNamecall(unpack(args))
            end
        end
        return rbOldNamecall(...)
    end))

    local rbMouse = lplr:GetMouse()
    local rbOldIndex
    rbOldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
        if not RageSettings.SilentForce then return rbOldIndex(self, key) end
        if RageSettings.SilentMethod ~= "Mouse.Hit/Target" then return rbOldIndex(self, key) end
        if not rawequal(self, rbMouse) then return rbOldIndex(self, key) end
        if checkcaller() then return rbOldIndex(self, key) end
        if key ~= "Hit" and key ~= "hit" and key ~= "Target" and key ~= "target" then return rbOldIndex(self, key) end
        local part = rbCachedTarget; if not part then return rbOldIndex(self, key) end
        if key == "Target" or key == "target" then return part end
        return CFrame.new(part.Position)
    end))
end

--  ANTI-KICK  (best-effort client-side kick interception)
getgenv()._F_ANTIKICK_ACTIVE = getgenv()._F_ANTIKICK_ACTIVE or false
if hookmetamethod and not getgenv()._F_ANTIKICK_NAMECALL_HOOKED then
    getgenv()._F_ANTIKICK_NAMECALL_HOOKED = true
    local akOldNamecall
    akOldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(...)
        if not getgenv()._F_ANTIKICK_ACTIVE then return akOldNamecall(...) end
        local method = getnamecallmethod()
        -- fast-path early-out: only the methods we care about
        if method ~= "Kick"
            and method ~= "Shutdown"
            and method ~= "Teleport"
            and method ~= "TeleportToPlaceInstance"
            and method ~= "TeleportToPrivateServer"
            and method ~= "TeleportPartyAsync"
            and method ~= "TeleportAsync" then
            return akOldNamecall(...)
        end
        local args = {...}
        local self = args[1]
        if method == "Kick" then
            -- block Kick on our local player
            if rawequal(self, lplr) or rawequal(self, game.Players.LocalPlayer) then
                warn("[anti-kick] blocked Player:Kick(", args[2], ")")
                return
            end
        elseif method == "Shutdown" then
            -- block any Shutdown call from script
            warn("[anti-kick] blocked Shutdown()")
            return
        elseif method:sub(1, 8) == "Teleport" then
            -- block teleport calls that include the local player. Server-
            for i = 2, #args do
                if rawequal(args[i], lplr) then
                    warn("[anti-kick] blocked ", method, "(... local player ...)")
                    return
                end
                if type(args[i]) == "table" then
                    for _, v in pairs(args[i]) do
                        if rawequal(v, lplr) then
                            warn("[anti-kick] blocked ", method, "(... {local player} ...)")
                            return
                        end
                    end
                end
            end
        end
        return akOldNamecall(...)
    end))
end

-- ragebot auto-shoot
local _rbEquipTime = 0
local function watchToolEquip(char)
    if not char then return end
    char.ChildAdded:Connect(function(c) if c:IsA("Tool") then _rbEquipTime = tick() end end)
end
lplr.CharacterAdded:Connect(watchToolEquip)
if lplr.Character then watchToolEquip(lplr.Character) end

local _rbLastShot = 0
-- [Player] = tick() last time we saw them in a knocked state.
local _rbLastKnockedAt = {}
local _rbLastAutoEquipAt = 0  -- throttle: don't try to equip every frame
plrs.PlayerRemoving:Connect(function(p) _rbLastKnockedAt[p] = nil end)
RunService.Heartbeat:Connect(function()
    if not RageSettings.AutoShoot then return end
    local now = tick()
    if (now - _rbEquipTime) < RageSettings.EquipDelay then return end
    if (now - _rbLastShot) < (RageSettings.AutoShootCooldown / 1000) then return end
    local plr = rbGetTarget(); if not plr then return end
    -- HC knocked status: stamp _rbLastKnockedAt every frame the target is
    local _hcMod = F.games and F.games.hoodCustoms
    local _isKnockedNow = false
    if _hcMod and _hcMod.isKnocked then
        local okK, knocked = pcall(_hcMod.isKnocked, plr)
        _isKnockedNow = okK and knocked or false
    end
    if _isKnockedNow then
        _rbLastKnockedAt[plr] = now
        if RageSettings.SkipKnocked then return end
    end
    -- Post-knocked grace: even when the target now reads alive, if they
    if RageSettings.KnockedGraceDelay > 0 then
        local lastK = _rbLastKnockedAt[plr]
        if lastK and (now - lastK) * 1000 < RageSettings.KnockedGraceDelay then return end
    end
    local char = plr.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local lchar = lplr.Character
    local lhrp = lchar and lchar:FindFirstChild("HumanoidRootPart"); if not lhrp then return end
    local dist = (lhrp.Position - hrp.Position).Magnitude
    if dist > RageSettings.AutoShootDist then return end
    if RageSettings.AutoShootVis and not rbIsVisible(plr) then return end
    if RageSettings.FFCheck and char:FindFirstChildOfClass("ForceField") then return end
    -- Auto-equip on shoot range: if the chosen tool isn't currently held,
    if RageSettings.AutoShootEquip and RageSettings.AutoShootEquipTool ~= "" then
        local heldTool = lchar:FindFirstChildOfClass("Tool")
        if not heldTool or heldTool.Name ~= RageSettings.AutoShootEquipTool then
            -- Wrong / no tool held: try to equip, then wait a frame
            if (now - _rbLastAutoEquipAt) > 0.2 then
                _rbLastAutoEquipAt = now
                local bp = lplr:FindFirstChild("Backpack")
                local tool = bp and bp:FindFirstChild(RageSettings.AutoShootEquipTool)
                local hum = lchar:FindFirstChildOfClass("Humanoid")
                if tool and hum then
                    pcall(function() hum:EquipTool(tool) end)
                end
            end
            return
        end
        -- Correct tool already held: do nothing, fall through to shoot.
    end
    if RageSettings.AutoShootRequireTool then
        local lc = lplr.Character
        if not lc or not lc:FindFirstChildOfClass("Tool") then return end
    end
    _rbLastShot = tick()
    -- HC Force Hit hook: when active, fire the synthetic Shoot remote
    if G.hcForceHitActive
        and F and F.games and F.games.hoodCustoms
        and F.games.hoodCustoms.forceHit
        and F.games.hoodCustoms.forceHit.fire then
        F.games.hoodCustoms.forceHit.fire()
        return
    end
    VirtualInputManager:SendMouseButtonEvent(0,0,0,true,game,0)
    VirtualInputManager:SendMouseButtonEvent(0,0,0,false,game,0)
end)

--  ESP CORE (drawings + render loop)
local EspDrawings, EspHighlights = {}, {}
local _tracerHistory = {}
local espRenderConn = nil

local function newLine()  if not Drawing then return nil end local l=Drawing.new("Line");   l.Visible=false; l.Thickness=1; l.Color=Color3.new(1,1,1); l.Transparency=1; return l end
local function newSquare() if not Drawing then return nil end local s=Drawing.new("Square"); s.Visible=false; s.Filled=false; s.Color=Color3.new(1,1,1); s.Transparency=1; s.Thickness=1; return s end
local function newText()  if not Drawing then return nil end local t=Drawing.new("Text");   t.Visible=false; t.Size=13; t.Center=true; t.Outline=true; t.Color=Color3.new(1,1,1); t.Font=2; return t end

local function espColor(plr)
    if EspSettings.TeamCheck then
        return plr.Team==lplr.Team and EspSettings.TeamColor or EspSettings.EnemyColor
    end
    return EspSettings.NeutralColor
end

local function createEspForPlayer(plr)
    if plr==lplr or not Drawing then return end
    local d={
        box={newLine(),newLine(),newLine(),newLine(),newLine(),newLine(),newLine(),newLine()},
        boxFull=newSquare(), tracer=newLine(), hpBg=newSquare(), hpFill=newSquare(), hpText=newText(),
        name=newText(), dist=newText(), held=newText(),
        skeleton={newLine(),newLine(),newLine(),newLine(),newLine(),newLine(),newLine(),
                  newLine(),newLine(),newLine(),newLine(),newLine(),newLine(),newLine()},
    }
    EspDrawings[plr]=d
    local hi=Instance.new("Highlight")
    hi.FillColor=EspSettings.ChamsFill; hi.OutlineColor=EspSettings.ChamsOutline
    hi.FillTransparency=0.5; hi.OutlineTransparency=0
    hi.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop; hi.Enabled=false
    EspHighlights[plr]=hi
end

local function removeEspForPlayer(plr)
    local d=EspDrawings[plr]
    if d then
        for _,l in ipairs(d.box) do l:Remove() end; d.boxFull:Remove(); d.tracer:Remove()
        d.hpBg:Remove(); d.hpFill:Remove(); d.hpText:Remove(); d.name:Remove(); d.dist:Remove(); d.held:Remove()
        for _,l in ipairs(d.skeleton) do l:Remove() end
        if d.trailLines then for _,l in ipairs(d.trailLines) do l:Remove() end end
        EspDrawings[plr]=nil; _tracerHistory[plr]=nil
    end
    local hi=EspHighlights[plr]; if hi then hi:Destroy(); EspHighlights[plr]=nil end
end

local function hideEsp(d)
    for _,l in ipairs(d.box) do l.Visible=false end; d.boxFull.Visible=false
    d.tracer.Visible=false; d.hpBg.Visible=false; d.hpFill.Visible=false; d.hpText.Visible=false
    d.name.Visible=false; d.dist.Visible=false; d.held.Visible=false
    for _,l in ipairs(d.skeleton) do l.Visible=false end
end

local function updateEspForPlayer(plr)
    local d=EspDrawings[plr]; if not d then return end
    local char=plr.Character
    local hrp=char and char:FindFirstChild("HumanoidRootPart")
    local hum=char and char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health<=0 then hideEsp(d); return end
    local rootPos,_onScreen=Camera:WorldToViewportPoint(hrp.Position)
    -- Hide only when the player is BEHIND the camera (sp.Z <= 0).
    if rootPos.Z <= 0 then hideEsp(d); return end
    if EspSettings.TracerHistory then
        if not _tracerHistory[plr] then _tracerHistory[plr]={} end
        table.insert(_tracerHistory[plr],{pos=hrp.Position,t=tick()})
        local cutoff=tick()-EspSettings.TracerHistLen
        while #_tracerHistory[plr]>0 and _tracerHistory[plr][1].t<cutoff do
            table.remove(_tracerHistory[plr],1)
        end
        if not d.trailLines then d.trailLines={} end
        local pts=_tracerHistory[plr]
        for _,ln in ipairs(d.trailLines) do ln.Visible=false end
        for i=2,#pts do
            local ln=d.trailLines[i-1]
            if not ln then
                ln=Drawing.new("Line"); ln.Thickness=1.5; ln.ZIndex=50; ln.Visible=false
                d.trailLines[i-1]=ln
            end
            local sp1=Camera:WorldToViewportPoint(pts[i-1].pos)
            local sp2=Camera:WorldToViewportPoint(pts[i].pos)
            local age=tick()-pts[i].t
            local alpha=1-(age/EspSettings.TracerHistLen)
            ln.From=Vector2.new(sp1.X,sp1.Y); ln.To=Vector2.new(sp2.X,sp2.Y)
            ln.Color=Color3.fromRGB(220,220,220); ln.Transparency=math.clamp(alpha,0,1); ln.Visible=true
        end
    else
        if d.trailLines then for _,ln in ipairs(d.trailLines) do ln.Visible=false end end
        _tracerHistory[plr]=nil
    end
    local dist=(hrp.Position-Camera.CFrame.Position).Magnitude
    if dist>1000 then hideEsp(d); return end
    local col=espColor(plr)
    -- Compute size from KNOWN body parts only (not GetExtentsSize, which
    local _BODY_PARTS_FOR_BOX = {
        "Head","HumanoidRootPart","Torso","UpperTorso","LowerTorso",
        "LeftFoot","RightFoot","LeftHand","RightHand",
    }
    local minP, maxP
    for _, _bname in ipairs(_BODY_PARTS_FOR_BOX) do
        local _bp = char:FindFirstChild(_bname)
        if _bp and _bp:IsA("BasePart") then
            local _ppos, _psz = _bp.Position, _bp.Size
            local _lo = _ppos - _psz/2
            local _hi = _ppos + _psz/2
            if not minP then minP, maxP = _lo, _hi
            else
                minP = Vector3.new(math.min(minP.X,_lo.X), math.min(minP.Y,_lo.Y), math.min(minP.Z,_lo.Z))
                maxP = Vector3.new(math.max(maxP.X,_hi.X), math.max(maxP.Y,_hi.Y), math.max(maxP.Z,_hi.Z))
            end
        end
    end
    local size = (minP and maxP) and (maxP - minP) or Vector3.new(4, 5.5, 2)
    local cf=hrp.CFrame
    local topV,_topOn=Camera:WorldToViewportPoint((cf*CFrame.new(0,size.Y/2,0)).Position)
    local botV,_botOn=Camera:WorldToViewportPoint((cf*CFrame.new(0,-size.Y/2,0)).Position)
    -- Same fix as above: only hide when the body's top or bottom is
    if topV.Z <= 0 or botV.Z <= 0 then hideEsp(d); return end
    local bH=botV.Y-topV.Y; local bW=bH*0.55; local bX=topV.X-bW/2; local bY=topV.Y; local cS=math.max(4,bW*0.22)

    if EspSettings.BoxESP then
        if EspSettings.BoxStyle=="Full" then
            for _,l in ipairs(d.box) do l.Visible=false end
            d.boxFull.Position=Vector2.new(bX,bY); d.boxFull.Size=Vector2.new(bW,bH)
            d.boxFull.Color=col; d.boxFull.Thickness=1; d.boxFull.Filled=false; d.boxFull.Visible=true
        else
            d.boxFull.Visible=false
            local tl=Vector2.new(bX,bY); local tr=Vector2.new(bX+bW,bY)
            local bl=Vector2.new(bX,bY+bH); local br=Vector2.new(bX+bW,bY+bH)
            local corners={{tl,tl+Vector2.new(cS,0)},{tl,tl+Vector2.new(0,cS)},
                           {tr,tr+Vector2.new(-cS,0)},{tr,tr+Vector2.new(0,cS)},
                           {bl,bl+Vector2.new(cS,0)},{bl,bl+Vector2.new(0,-cS)},
                           {br,br+Vector2.new(-cS,0)},{br,br+Vector2.new(0,-cS)}}
            for i,c in ipairs(corners) do
                d.box[i].From=c[1]; d.box[i].To=c[2]; d.box[i].Color=col; d.box[i].Thickness=1; d.box[i].Transparency=1; d.box[i].Visible=true
            end
        end
    else for _,l in ipairs(d.box) do l.Visible=false end; d.boxFull.Visible=false end

    if EspSettings.TracerESP then
        local vp=Camera.ViewportSize; local from
        if EspSettings.TracerOrigin=="Top" then from=Vector2.new(vp.X/2,0)
        elseif EspSettings.TracerOrigin=="Center" then from=Vector2.new(vp.X/2,vp.Y/2)
        elseif EspSettings.TracerOrigin=="Mouse" then local mp=UserInputService:GetMouseLocation(); from=Vector2.new(mp.X,mp.Y)
        else from=Vector2.new(vp.X/2,vp.Y) end
        d.tracer.From=from; d.tracer.To=Vector2.new(rootPos.X,rootPos.Y)
        d.tracer.Color=col; d.tracer.Thickness=1; d.tracer.Transparency=1; d.tracer.Visible=true
    else d.tracer.Visible=false end

    if EspSettings.HealthESP then
        local pct=math.clamp(hum.Health/hum.MaxHealth,0,1)
        local barX=bX-4; local barY=bY
        d.hpBg.Size=Vector2.new(2,bH); d.hpBg.Position=Vector2.new(barX,barY)
        d.hpBg.Color=Color3.fromRGB(20,20,20); d.hpBg.Filled=true; d.hpBg.Transparency=1; d.hpBg.Visible=true
        local fillH=bH*pct
        d.hpFill.Size=Vector2.new(2,fillH); d.hpFill.Position=Vector2.new(barX,barY+bH-fillH)
        d.hpFill.Color=Color3.fromRGB(math.floor((1-pct)*255),math.floor(pct*200)+55,30)
        d.hpFill.Filled=true; d.hpFill.Transparency=1; d.hpFill.Visible=true
    else d.hpBg.Visible=false; d.hpFill.Visible=false end

    if EspSettings.HealthNum then
        local pct=math.clamp(hum.Health/hum.MaxHealth,0,1)
        local nameOffset = EspSettings.NameESP and 24 or 13
        d.hpText.Text=math.floor(hum.Health).."/"..math.floor(hum.MaxHealth).." hp"
        d.hpText.Position=Vector2.new(bX+bW/2, bY-nameOffset)
        d.hpText.Color=Color3.fromRGB(math.floor((1-pct)*220)+35, math.floor(pct*200)+55, 40)
        d.hpText.Size=11; d.hpText.Visible=true
    else d.hpText.Visible=false end

    if EspSettings.NameESP then
        d.name.Text=plr.Name; d.name.Position=Vector2.new(bX+bW/2,bY-13); d.name.Color=col; d.name.Size=13; d.name.Visible=true
    else d.name.Visible=false end

    if EspSettings.DistanceESP then
        d.dist.Text=math.floor(dist).." st"; d.dist.Position=Vector2.new(bX+bW/2,bY+bH+2)
        d.dist.Color=Color3.fromRGB(180,180,180); d.dist.Size=11; d.dist.Visible=true
    else d.dist.Visible=false end

    if EspSettings.HeldItem then
        local tool = char:FindFirstChildOfClass("Tool")
        if tool then
            d.held.Text="["..tool.Name.."]"; d.held.Position=Vector2.new(bX+bW/2, bY+bH+13)
            d.held.Color=Color3.fromRGB(255,215,60); d.held.Size=11; d.held.Visible=true
        else d.held.Visible=false end
    else d.held.Visible=false end

    if EspSettings.SkeletonESP then
        local joints={{"Head","UpperTorso"},{"UpperTorso","LowerTorso"},
            {"UpperTorso","LeftUpperArm"},{"LeftUpperArm","LeftLowerArm"},{"LeftLowerArm","LeftHand"},
            {"UpperTorso","RightUpperArm"},{"RightUpperArm","RightLowerArm"},{"RightLowerArm","RightHand"},
            {"LowerTorso","LeftUpperLeg"},{"LeftUpperLeg","LeftLowerLeg"},{"LeftLowerLeg","LeftFoot"},
            {"LowerTorso","RightUpperLeg"},{"RightUpperLeg","RightLowerLeg"},{"RightLowerLeg","RightFoot"}}
        for i,pair in ipairs(joints) do
            local pA=char:FindFirstChild(pair[1]); local pB=char:FindFirstChild(pair[2]); local line=d.skeleton[i]
            if pA and pB and line then
                local sA=Camera:WorldToViewportPoint(pA.Position); local sB=Camera:WorldToViewportPoint(pB.Position)
                -- Only hide when EITHER joint is behind the camera (Z<=0).
                if sA.Z>0 and sB.Z>0 then line.From=Vector2.new(sA.X,sA.Y); line.To=Vector2.new(sB.X,sB.Y); line.Color=col; line.Thickness=1; line.Transparency=1; line.Visible=true
                else line.Visible=false end
            elseif line then line.Visible=false end
        end
    else for _,l in ipairs(d.skeleton) do l.Visible=false end end

    local hi=EspHighlights[plr]
    if hi then
        if EspSettings.ChamsEnabled and char then
            if EspSettings.ChamsStyle=="Overlay" then hi.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop; hi.FillTransparency=0.4; hi.OutlineTransparency=0
            elseif EspSettings.ChamsStyle=="Occluded" then hi.DepthMode=Enum.HighlightDepthMode.Occluded; hi.FillTransparency=0.3; hi.OutlineTransparency=0
            elseif EspSettings.ChamsStyle=="Outline" then hi.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop; hi.FillTransparency=1; hi.OutlineTransparency=0 end
            -- Re-apply colors each frame so the color picker updates live.
            hi.FillColor    = EspSettings.ChamsFill
            hi.OutlineColor = EspSettings.ChamsOutline
            hi.Parent=char; hi.Enabled=true
        else hi.Enabled=false end
    end
end

local function startEspRender()
    if espRenderConn or not Drawing then return end
    -- Throttle the ESP render to ~120 Hz max. Caps the cost
    local MIN_DT = 1 / 120
    local accum = 0
    espRenderConn = RunService.RenderStepped:Connect(function(dt)
        if not EspSettings.Enabled then
            for _,d in pairs(EspDrawings) do hideEsp(d) end
            for _,h in pairs(EspHighlights) do h.Enabled=false end
            return
        end
        accum = accum + dt
        if accum < MIN_DT then return end
        accum = 0
        for _,plr in ipairs(_cachedPlayers or plrs:GetPlayers()) do
            if plr~=lplr then
                if not EspDrawings[plr] then createEspForPlayer(plr) end
                updateEspForPlayer(plr)
            end
        end
    end)
end
local function stopEspRender()
    if espRenderConn then espRenderConn:Disconnect(); espRenderConn=nil end
    for _,d in pairs(EspDrawings) do hideEsp(d) end
    for _,h in pairs(EspHighlights) do h.Enabled=false end
end

plrs.PlayerRemoving:Connect(function(plr) removeEspForPlayer(plr) end)

--  PUBLIC API
local function makeToggle(startFn, stopFn, isActiveKey)
    return {
        start  = startFn,
        stop   = stopFn,
        toggle = function() if G[isActiveKey] then stopFn() else startFn() end end,
        isActive = function() return G[isActiveKey] == true end,
    }
end

F = {}  -- assigns the forward-declared local

-- Version string baked at push time. Use F.getVersion() from the loader
F.SCRIPT_VERSION = SCRIPT_VERSION
F.getVersion = function() return SCRIPT_VERSION end

F.fly = makeToggle(startFly, stopFly, "flyActive")
F.fly.setSpeed   = function(n) FLY_SPEED = tonumber(n) or FLY_SPEED end
F.fly.getSpeed   = function() return FLY_SPEED end

-- anti-kick: wraps the getgenv flag that the namecall hook reads

-- Real Humanoid.WalkSpeed override w/ anti-restore. Setting the value
F.walkspeed = {
    start  = startWalkspeed,
    stop   = stopWalkspeed,
    toggle = function() if G.walkspeedActive then stopWalkspeed() else startWalkspeed() end end,
    isActive = function() return G.walkspeedActive == true end,
    setValue = function(n)
        G.walkspeedValue = tonumber(n) or G.walkspeedValue
        -- Apply immediately so the slider feels responsive; the Heartbeat
        if G.walkspeedActive then
            local c = lplr.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if hum then pcall(function() hum.WalkSpeed = G.walkspeedValue end) end
        end
    end,
    getValue = function() return G.walkspeedValue end,
}

-- Real Humanoid.JumpPower override w/ anti-restore. Pair with Force
F.jumpPower = {
    start  = startJumpPower,
    stop   = stopJumpPower,
    toggle = function() if G.jumpPowerActive then stopJumpPower() else startJumpPower() end end,
    isActive = function() return G.jumpPowerActive == true end,
    setValue = function(n)
        G.jumpPowerValue = tonumber(n) or G.jumpPowerValue
        if G.jumpPowerActive then
            local c = lplr.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if hum then
                pcall(function()
                    if hum.UseJumpPower then
                        hum.JumpPower = G.jumpPowerValue
                    else
                        hum.JumpHeight = G.jumpPowerValue / 7
                    end
                end)
            end
        end
    end,
    getValue = function() return G.jumpPowerValue end,
}

-- CFrame-based "speed hack" (camera-WASD-driven HRP nudge).
F.cframeSpeed = {
    start  = function(mult) startCframeSpeed(mult) end,
    stop   = stopCframeSpeed,
    toggle = function(mult) if G.speedActive then stopCframeSpeed() else startCframeSpeed(mult) end end,
    isActive = function() return G.speedActive == true end,
    setMultiplier = function(n) G.speedValue = tonumber(n) or G.speedValue end,
    getMultiplier = function() return G.speedValue end,
}
-- legacy alias (old code referenced F.speed)

F.forceJump = makeToggle(startForceJump, stopForceJump, "forceJumpActive")
F.clickTp   = makeToggle(startClickTp,   stopClickTp,   "clickTpActive")
F.noclip    = makeToggle(startNoclip,    stopNoclip,    "noclipActive")
F.fullbright= makeToggle(startFullbright,stopFullbright,"fullbrightActive")
F.freecam   = makeToggle(startFreecam,   stopFreecam,   "freecamActive")
F.zoom      = makeToggle(startZoom,      stopZoom,      "zoomActive")
F.spin      = makeToggle(startSpin,      stopSpin,      "spinActive")

--  CSGO HVH MOVEMENT
F.hvhMovement = (function()
    local active        = false
    local jiggleAmtMin  = 15   -- random ±degree range, rolled per snap
    local jiggleAmtMax  = 35
    local jiggleHzMin   = 1    -- random snap-rate range, full cycles/sec
    local jiggleHzMax   = 3
    local _savedAR      = nil  -- captured Humanoid.AutoRotate
    -- snap scheduling: per-snap we roll a fresh Hz in [min,max] and
    local _sign         = 1
    local _curAmt       = 0    -- magnitude held since last snap
    local _nextSnapAt   = 0

    local function start()
        if active then return end
        active      = true
        _sign       = (math.random() < 0.5) and -1 or 1
        _curAmt     = (jiggleAmtMin + jiggleAmtMax) * 0.5
        _nextSnapAt = 0
        RunService:BindToRenderStep("wh_hvh", Enum.RenderPriority.Last.Value + 1, function()
            if not active then
                RunService:UnbindFromRenderStep("wh_hvh")
                return
            end
            local c = lplr.Character; if not c then return end
            local hrp = c:FindFirstChild("HumanoidRootPart"); if not hrp then return end
            local hum = c:FindFirstChildOfClass("Humanoid")
            if hum then
                if _savedAR == nil then _savedAR = hum.AutoRotate end
                if hum.AutoRotate then pcall(function() hum.AutoRotate = false end) end
            end
            local cam = workspace.CurrentCamera; if not cam then return end
            -- Face TOWARD the camera position.
            local dx = cam.CFrame.Position.X - hrp.Position.X
            local dz = cam.CFrame.Position.Z - hrp.Position.Z
            if dx*dx + dz*dz < 0.01 then return end
            local baseYaw = math.atan2(-dx, -dz)
            -- Snap scheduling: when the planned snap time arrives,
            local now = tick()
            if now >= _nextSnapAt then
                _sign = -_sign
                local hzLo = math.max(jiggleHzMin, 0.01)
                local hzHi = math.max(jiggleHzMax, hzLo)
                local hz   = hzLo + math.random() * (hzHi - hzLo)
                _nextSnapAt = now + 1 / (2 * hz)
                local amLo = math.max(jiggleAmtMin, 0)
                local amHi = math.max(jiggleAmtMax, amLo)
                _curAmt = amLo + math.random() * (amHi - amLo)
            end
            local j = _sign * math.rad(_curAmt)
            hrp.CFrame = CFrame.new(hrp.Position) * CFrame.fromEulerAnglesYXZ(0, baseYaw + j, 0)
        end)
    end

    local function stop()
        active = false
        pcall(function() RunService:UnbindFromRenderStep("wh_hvh") end)
        local c = lplr.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if hum and _savedAR ~= nil then
            pcall(function() hum.AutoRotate = _savedAR end)
        end
        _savedAR = nil
    end

    return {
        start    = start,
        stop     = stop,
        toggle   = function() if active then stop() else start() end end,
        isActive = function() return active end,
        setJiggleAmountMin = function(n)
            jiggleAmtMin = math.clamp(tonumber(n) or 15, 0, 180)
            if jiggleAmtMin > jiggleAmtMax then jiggleAmtMax = jiggleAmtMin end
        end,
        setJiggleAmountMax = function(n)
            jiggleAmtMax = math.clamp(tonumber(n) or 35, 0, 180)
            if jiggleAmtMax < jiggleAmtMin then jiggleAmtMin = jiggleAmtMax end
        end,
        setJiggleFreqMin = function(n)
            jiggleHzMin = math.clamp(tonumber(n) or 1, 0.05, 30)
            if jiggleHzMin > jiggleHzMax then jiggleHzMax = jiggleHzMin end
        end,
        setJiggleFreqMax = function(n)
            jiggleHzMax = math.clamp(tonumber(n) or 3, 0.05, 30)
            if jiggleHzMax < jiggleHzMin then jiggleHzMin = jiggleHzMax end
        end,
        getJiggleAmountMin = function() return jiggleAmtMin end,
        getJiggleAmountMax = function() return jiggleAmtMax end,
        getJiggleFreqMin   = function() return jiggleHzMin end,
        getJiggleFreqMax   = function() return jiggleHzMax end,
    }
end)()
F.spin.setSpeed = function(n)
    SPIN_SPEED = tonumber(n) or SPIN_SPEED
    -- live-update the running gyro so the slider takes effect immediately
    if G._spinGyro and G._spinGyro.Parent then
        G._spinGyro.AngularVelocity = Vector3.new(0, SPIN_SPEED, 0)
    end
end
F.flip      = makeToggle(startFlip,      stopFlip,      "flipActive")
F.tilt      = makeToggle(startTilt,      stopTilt,      "tiltActive")
F.ice       = makeToggle(startIce,       stopIce,       "iceActive")
F.ice.setSlide = function(n) ICE_SLIDE = math.clamp(tonumber(n) or ICE_SLIDE, 0, 0.999) end

--  STICKY EMOTES  (entire module inlined here)
F.stickyEmote = (function()
    local BUILTIN_ANIM_NAMES = {
        WalkAnim = true, RunAnim = true, JumpAnim = true, IdleAnim = true,
        FallAnim = true, ClimbAnim = true, SwimAnim = true, SwimIdleAnim = true,
        ToolNoneAnim = true, ToolSlashAnim = true, ToolLungeAnim = true,
        ["Idle Anim"] = true, ["Walk Anim"] = true, ["Run Anim"] = true,
        ["Jump Anim"] = true, ["Fall Anim"] = true, ["Climb Anim"] = true,
        PoseAnim = true, DeathAnim = true, SitAnim = true,
    }
    local BUILTIN_PARENT_NAMES = {
        walk = true, run = true, jump = true, idle = true, fall = true,
        climb = true, swim = true, swimidle = true, sit = true,
        toolnone = true, toolslash = true, toollunge = true,
    }
    local function getAnimator()
        local c = lplr.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        return hum and hum:FindFirstChildOfClass("Animator")
    end
    local function isToolAnim(track)
        local a = track.Animation
        if not a then return false end
        local p = a.Parent
        for _ = 1, 12 do
            if not p or p == game then return false end
            if p:IsA("Tool") or p:IsA("HopperBin") then return true end
            p = p.Parent
        end
        return false
    end
    local function isBuiltin(track)
        local a = track.Animation
        if not a then return true end
        if BUILTIN_ANIM_NAMES[a.Name or ""] then return true end
        local parent = a.Parent
        if parent then
            if BUILTIN_PARENT_NAMES[(parent.Name or ""):lower()] then return true end
            local grand = parent.Parent
            if grand and grand.Name == "Animate" then return true end
        end
        local prio = track.Priority
        if prio == Enum.AnimationPriority.Idle
           or prio == Enum.AnimationPriority.Movement
           or prio == Enum.AnimationPriority.Core then
            return true
        end
        return false
    end
    local function shouldStick(track)
        if isToolAnim(track) then return false end
        if isBuiltin(track) then return false end
        return true
    end
    local function stopOurs()
        G._stickyTracks = G._stickyTracks or {}
        for t, _ in pairs(G._stickyTracks) do
            pcall(function() t:Stop(0) end)
        end
        table.clear(G._stickyTracks)
    end
    local function stopFn()
        G.stickyEmoteActive   = false
        G._currentEmoteId     = nil
        G._emoteStopRequested = false
        if G._emoteAnimConn     then G._emoteAnimConn:Disconnect();     G._emoteAnimConn     = nil end
        if G._emoteCharConn     then G._emoteCharConn:Disconnect();     G._emoteCharConn     = nil end
        if G._emoteChatConn     then G._emoteChatConn:Disconnect();     G._emoteChatConn     = nil end
        if G._emoteTextChatConn then G._emoteTextChatConn:Disconnect(); G._emoteTextChatConn = nil end
        if G._emoteHbConn       then G._emoteHbConn:Disconnect();       G._emoteHbConn       = nil end
        stopOurs()
    end
    local function startFn()
        G.stickyEmoteActive   = true
        G._emoteStopRequested = false
        G._currentEmoteId     = nil
        G._stickyTracks       = G._stickyTracks or {}

        local function hookChar(char)
            if not char then return end
            local hum = char:WaitForChild("Humanoid", 5); if not hum then return end
            local animator = hum:WaitForChild("Animator", 5); if not animator then return end
            if G._emoteAnimConn then G._emoteAnimConn:Disconnect() end
            G._emoteAnimConn = animator.AnimationPlayed:Connect(function(track)
                if not G.stickyEmoteActive or G._emoteStopRequested then return end
                if not shouldStick(track) then return end
                local a = track.Animation
                if not a or a.AnimationId == "" then return end
                -- our own Heartbeat replay of the current emote - just track it
                if G._currentEmoteId == a.AnimationId then
                    G._stickyTracks[track] = true
                    pcall(function() track.Priority = Enum.AnimationPriority.Action4 end)
                    return
                end
                -- different emote - supersede old set so they don't stack
                stopOurs()
                G._stickyTracks[track] = true
                G._currentEmoteId = a.AnimationId
                pcall(function() track.Priority = Enum.AnimationPriority.Action4 end)
            end)
        end
        hookChar(lplr.Character)
        if G._emoteCharConn then G._emoteCharConn:Disconnect() end
        G._emoteCharConn = lplr.CharacterAdded:Connect(function(c)
            if G.stickyEmoteActive then
                G._currentEmoteId = nil
                table.clear(G._stickyTracks)
                hookChar(c)
            end
        end)

        -- Heartbeat keep-alive: re-create from AssetId when our tracks die
        if G._emoteHbConn then G._emoteHbConn:Disconnect() end
        G._emoteHbConn = RunService.Heartbeat:Connect(function()
            if not G.stickyEmoteActive or G._emoteStopRequested then return end
            local id = G._currentEmoteId
            if not id or id == "" then return end
            local animator = getAnimator()
            if not animator then return end
            for t, _ in pairs(G._stickyTracks) do
                if not t.IsPlaying and t.Parent ~= animator then
                    G._stickyTracks[t] = nil
                end
            end
            for t, _ in pairs(G._stickyTracks) do
                if t.IsPlaying and t.Animation and t.Animation.AnimationId == id then
                    if t.Priority ~= Enum.AnimationPriority.Action4 then
                        pcall(function() t.Priority = Enum.AnimationPriority.Action4 end)
                    end
                    return
                end
            end
            local anim = Instance.new("Animation")
            anim.AnimationId = id
            local newTrack
            pcall(function() newTrack = animator:LoadAnimation(anim) end)
            if newTrack then
                pcall(function() newTrack.Priority = Enum.AnimationPriority.Action4 end)
                pcall(function() newTrack:Play(0) end)
                G._stickyTracks[newTrack] = true
            end
        end)

        -- /e stop interception, both chat systems
        local function onChat(msg)
            if not G.stickyEmoteActive or type(msg) ~= "string" then return end
            local m = msg:lower():gsub("^%s+", "")
            if m:match("^/e%s+stop") or m:match("^/emote%s+stop") then
                G._emoteStopRequested = true
                G._currentEmoteId     = nil
                stopOurs()
                task.delay(0.5, function() G._emoteStopRequested = false end)
            end
        end
        if G._emoteChatConn then G._emoteChatConn:Disconnect() end
        G._emoteChatConn = lplr.Chatted:Connect(onChat)
        if G._emoteTextChatConn then G._emoteTextChatConn:Disconnect() end
        pcall(function()
            local TCS = game:GetService("TextChatService")
            if TCS and TCS.SendingMessage then
                G._emoteTextChatConn = TCS.SendingMessage:Connect(function(message)
                    if message and message.Text then onChat(message.Text) end
                end)
            end
        end)
    end
    -- Copy whatever emote `plr` is currently playing onto us, ONCE.
    local function syncWith(plr)
        local ch  = plr and plr.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        local tAnimator = hum and hum:FindFirstChildOfClass("Animator")
        if not tAnimator then return false end
        local id
        local ok, tracks = pcall(function() return tAnimator:GetPlayingAnimationTracks() end)
        if ok and tracks then
            for _, tr in ipairs(tracks) do
                if shouldStick(tr) then
                    local a = tr.Animation
                    if a and a.AnimationId ~= "" then id = a.AnimationId; break end
                end
            end
        end
        if not id then return false end
        local myAnimator = getAnimator()
        if not myAnimator then return false end
        local anim = Instance.new("Animation"); anim.AnimationId = id
        local tr; pcall(function() tr = myAnimator:LoadAnimation(anim) end)
        if not tr then return false end
        if G.stickyEmoteActive then
            -- sticky on: let the keep-alive loop it through movement
            G._emoteStopRequested = false
            stopOurs()
            G._currentEmoteId = id
            pcall(function() tr.Priority = Enum.AnimationPriority.Action4 end)
            G._stickyTracks[tr] = true
        end
        pcall(function() tr:Play(0) end)
        return true
    end

    return {
        start    = startFn,
        stop     = stopFn,
        toggle   = function() if G.stickyEmoteActive then stopFn() else startFn() end end,
        isActive = function() return G.stickyEmoteActive == true end,
        syncWith = syncWith,
    }
end)()

F.respawn = { fire = cmdRe }
-- upright teleport (clears ragdoll/sit, faces horizontally, zeroes velocity,
F.uprightTp = _uprightTp
F.fov = { set = setFov, get = function() return CUSTOM_FOV end }

--  TOOL GLOW
F.toolMaterial = (function()
    -- Strip every texture off the equipped tool and force the
    local active     = false
    local color      = Color3.fromRGB(255, 60, 60)
    local transp     = 0.0
    local material   = Enum.Material.Neon
    local equipConn, unequipConn, charConn, descConn, pushLoopThread

    -- Per-instance snapshot. Keyed by Instance ref (weak), value is a
    local snap = setmetatable({}, { __mode = "k" })

    local function recolourPart(p)
        if snap[p] then return end
        snap[p] = {
            kind         = "part",
            mat          = p.Material,
            color        = p.Color,
            transparency = p.Transparency,
            texId        = p:IsA("MeshPart") and p.TextureID or nil,
        }
        p.Material      = material
        p.Color         = color
        p.Transparency  = transp
        if p:IsA("MeshPart") then p.TextureID = "" end
    end

    local function stripMesh(m)
        if snap[m] then return end
        snap[m] = {
            kind        = "mesh",
            texId       = m.TextureId,
            vertexColor = m.VertexColor,
        }
        m.TextureId   = ""
        m.VertexColor = Vector3.new(1, 1, 1)
    end

    local function hideDeco(d)
        if snap[d] then return end
        snap[d] = { kind = "deco", transparency = d.Transparency }
        d.Transparency = 1
    end

    -- SurfaceAppearance (PBR) sits on a MeshPart and OVERRIDES .Material,
    local function stripSurface(sa)
        if snap[sa] then return end
        snap[sa] = { kind = "surface", parent = sa.Parent }
        sa.Parent = nil
    end

    local function walkTool(tool)
        if not tool then return end
        for _, inst in ipairs(tool:GetDescendants()) do
            if inst:IsA("BasePart") then
                recolourPart(inst)
            elseif inst:IsA("SpecialMesh") then
                stripMesh(inst)
            elseif inst:IsA("Texture") or inst:IsA("Decal") then
                hideDeco(inst)
            elseif inst:IsA("SurfaceAppearance") then
                stripSurface(inst)
            end
        end
    end

    local function restoreAll()
        for inst, s in pairs(snap) do
            pcall(function()
                if s.kind == "surface" then
                    -- re-attach even though we detached it (Parent is nil)
                    if inst and s.parent and s.parent.Parent then inst.Parent = s.parent end
                elseif inst and inst.Parent then
                    if s.kind == "part" then
                        inst.Material      = s.mat
                        inst.Color         = s.color
                        inst.Transparency  = s.transparency
                        if s.texId ~= nil and inst:IsA("MeshPart") then
                            inst.TextureID = s.texId
                        end
                    elseif s.kind == "mesh" then
                        inst.TextureId   = s.texId
                        inst.VertexColor = s.vertexColor
                    elseif s.kind == "deco" then
                        inst.Transparency = s.transparency
                    end
                end
            end)
            snap[inst] = nil
        end
    end

    -- Re-push the current material/colour/transparency onto every
    local function pushLiveValues()
        for inst, s in pairs(snap) do
            if inst and inst.Parent then
                pcall(function()
                    if s.kind == "part" then
                        inst.Material     = material
                        inst.Color        = color
                        inst.Transparency = transp
                        if inst:IsA("MeshPart") then inst.TextureID = "" end
                    elseif s.kind == "mesh" then
                        inst.TextureId   = ""
                        inst.VertexColor = Vector3.new(1, 1, 1)
                    elseif s.kind == "deco" then
                        inst.Transparency = 1
                    elseif s.kind == "surface" then
                        inst.Parent = nil
                    end
                end)
            end
        end
    end

    -- Catch descendants added AFTER the initial walk - tools spawn
    local function bindDescAdded(tool)
        if descConn then descConn:Disconnect() end
        if not tool then return end
        descConn = tool.DescendantAdded:Connect(function(inst)
            if not active then return end
            if inst:IsA("BasePart") then recolourPart(inst)
            elseif inst:IsA("SpecialMesh") then stripMesh(inst)
            elseif inst:IsA("Texture") or inst:IsA("Decal") then hideDeco(inst)
            elseif inst:IsA("SurfaceAppearance") then stripSurface(inst)
            end
        end)
    end

    local function attachToCurrent()
        if not active then return end
        local c = lplr.Character; if not c then return end
        local tool = c:FindFirstChildOfClass("Tool")
        if tool then
            walkTool(tool)
            bindDescAdded(tool)
        else
            if descConn then descConn:Disconnect(); descConn = nil end
        end
    end

    local function wireChar(c)
        if equipConn   then equipConn:Disconnect();   equipConn   = nil end
        if unequipConn then unequipConn:Disconnect(); unequipConn = nil end
        if not c then return end
        equipConn = c.ChildAdded:Connect(function(ch)
            if ch:IsA("Tool") then task.defer(attachToCurrent) end
        end)
        unequipConn = c.ChildRemoved:Connect(function(ch)
            -- Drop unequipped tool's parts from snap so re-equipping a
            if ch:IsA("Tool") then
                for _, d in ipairs(ch:GetDescendants()) do snap[d] = nil end
                snap[ch] = nil
            end
        end)
        attachToCurrent()
    end

    local function start()
        if active then return end
        active = true
        if charConn then charConn:Disconnect() end
        charConn = lplr.CharacterAdded:Connect(function(c)
            if active then task.wait(0.3); wireChar(c) end
        end)
        wireChar(lplr.Character)
        -- periodic re-push to defeat game-script overrides
        if pushLoopThread then pcall(task.cancel, pushLoopThread) end
        pushLoopThread = task.spawn(function()
            while active do
                task.wait(0.4)
                pushLiveValues()
            end
            pushLoopThread = nil
        end)
    end

    local function stop()
        active = false
        if pushLoopThread then pcall(task.cancel, pushLoopThread); pushLoopThread = nil end
        if descConn       then descConn:Disconnect();              descConn       = nil end
        restoreAll()
        if equipConn   then equipConn:Disconnect();   equipConn   = nil end
        if unequipConn then unequipConn:Disconnect(); unequipConn = nil end
        if charConn    then charConn:Disconnect();    charConn    = nil end
    end

    -- Material setter: accept Enum.Material directly, OR a string
    local function setMaterial(m)
        local picked
        if typeof(m) == "EnumItem" and m.EnumType == Enum.Material then
            picked = m
        elseif type(m) == "string" then
            local norm = m:lower():gsub("[%s%.]+", "")
            if     norm == "neon"          then picked = Enum.Material.Neon
            elseif norm == "forcefield"    then picked = Enum.Material.ForceField
            elseif norm == "glass"         then picked = Enum.Material.Glass
            elseif norm == "plastic"       then picked = Enum.Material.Plastic
            elseif norm == "metal"         then picked = Enum.Material.Metal
            elseif norm == "smoothplastic" then picked = Enum.Material.SmoothPlastic
            else
                local ok, em = pcall(function() return Enum.Material[m] end)
                if ok and em then picked = em end
            end
        elseif type(m) == "table" then
            -- Linoria multi-select returns {["Neon"]=true} or {"Neon"}.
            for k, v in pairs(m) do
                local name = (type(k) == "string") and k or v
                if type(name) == "string" then
                    setMaterial(name)  -- recurse - picks the first match
                    return
                end
            end
        end
        if picked then
            material = picked
            print("[witherhook] tool material ->", picked.Name,
                  active and "(live)" or "(stored - turn toggle on to apply)")
        else
            warn("[witherhook] tool material: unknown input", typeof(m), m)
        end
        if active then pushLiveValues() end
    end

    return {
        start    = start,
        stop     = stop,
        toggle   = function() if active then stop() else start() end end,
        isActive = function() return active end,
        setColor = function(c)
            if typeof(c) == "Color3" then
                color = c
                if active then pushLiveValues() end
            end
        end,
        setTransparency = function(n)
            transp = math.clamp(tonumber(n) or 0, 0, 1)
            if active then pushLiveValues() end
        end,
        setMaterial  = setMaterial,
        getColor     = function() return color end,
        getMaterial  = function() return material end,
    }
end)()

--  BODY MATERIAL
F.bodyMaterial = (function()
    local active     = false
    local color      = Color3.fromRGB(255, 60, 60)
    local transp     = 0.0
    local material   = Enum.Material.Neon
    local charConn, descConn, pushLoopThread

    local snap = setmetatable({}, { __mode = "k" })

    local function recolourPart(p)
        if snap[p] then return end
        snap[p] = {
            kind         = "part",
            mat          = p.Material,
            color        = p.Color,
            transparency = p.Transparency,
            texId        = p:IsA("MeshPart") and p.TextureID or nil,
        }
        p.Material      = material
        p.Color         = color
        p.Transparency  = transp
        if p:IsA("MeshPart") then p.TextureID = "" end
    end

    local function stripMesh(m)
        if snap[m] then return end
        snap[m] = { kind = "mesh", texId = m.TextureId, vertexColor = m.VertexColor }
        m.TextureId   = ""
        m.VertexColor = Vector3.new(1, 1, 1)
    end

    local function hideDeco(d)
        if snap[d] then return end
        snap[d] = { kind = "deco", transparency = d.Transparency }
        d.Transparency = 1
    end

    -- Skip everything inside an equipped Tool - that's toolMaterial's
    local function isInsideTool(inst, char)
        local p = inst.Parent
        while p and p ~= char do
            if p:IsA("Tool") then return true end
            p = p.Parent
        end
        return false
    end

    local function walkChar(c)
        if not c then return end
        for _, inst in ipairs(c:GetDescendants()) do
            if not isInsideTool(inst, c) then
                if inst:IsA("BasePart") then
                    recolourPart(inst)
                elseif inst:IsA("SpecialMesh") then
                    stripMesh(inst)
                elseif inst:IsA("Texture") or inst:IsA("Decal") then
                    hideDeco(inst)
                end
            end
        end
    end

    local function restoreAll()
        for inst, s in pairs(snap) do
            pcall(function()
                if s.kind == "surface" then
                    -- re-attach even though we detached it (Parent is nil)
                    if inst and s.parent and s.parent.Parent then inst.Parent = s.parent end
                elseif inst and inst.Parent then
                    if s.kind == "part" then
                        inst.Material      = s.mat
                        inst.Color         = s.color
                        inst.Transparency  = s.transparency
                        if s.texId ~= nil and inst:IsA("MeshPart") then
                            inst.TextureID = s.texId
                        end
                    elseif s.kind == "mesh" then
                        inst.TextureId   = s.texId
                        inst.VertexColor = s.vertexColor
                    elseif s.kind == "deco" then
                        inst.Transparency = s.transparency
                    end
                end
            end)
            snap[inst] = nil
        end
    end

    -- Re-push all our values onto every snapped instance. The game's
    local function pushLiveValues()
        for inst, s in pairs(snap) do
            if inst and inst.Parent then
                pcall(function()
                    if s.kind == "part" then
                        inst.Material     = material
                        inst.Color        = color
                        inst.Transparency = transp
                        if inst:IsA("MeshPart") then inst.TextureID = "" end
                    elseif s.kind == "mesh" then
                        inst.TextureId   = ""
                        inst.VertexColor = Vector3.new(1, 1, 1)
                    elseif s.kind == "deco" then
                        inst.Transparency = 1
                    elseif s.kind == "surface" then
                        inst.Parent = nil
                    end
                end)
            end
        end
    end

    -- DescendantAdded catches accessories / shirts / face decals that
    local function bindDescAdded(c)
        if descConn then descConn:Disconnect() end
        if not c then return end
        descConn = c.DescendantAdded:Connect(function(inst)
            if not active then return end
            if isInsideTool(inst, c) then return end
            if inst:IsA("BasePart") then recolourPart(inst)
            elseif inst:IsA("SpecialMesh") then stripMesh(inst)
            elseif inst:IsA("Texture") or inst:IsA("Decal") then hideDeco(inst)
            end
        end)
    end

    local function start()
        if active then return end
        active = true
        if charConn then charConn:Disconnect() end
        charConn = lplr.CharacterAdded:Connect(function(c)
            if active then
                task.wait(0.3)
                walkChar(c)
                bindDescAdded(c)
            end
        end)
        walkChar(lplr.Character)
        bindDescAdded(lplr.Character)
        -- periodic re-push to defeat game-script overrides
        if pushLoopThread then pcall(task.cancel, pushLoopThread) end
        pushLoopThread = task.spawn(function()
            while active do
                task.wait(0.4)
                pushLiveValues()
            end
            pushLoopThread = nil
        end)
    end

    local function stop()
        active = false
        if pushLoopThread then pcall(task.cancel, pushLoopThread); pushLoopThread = nil end
        if descConn       then descConn:Disconnect();              descConn       = nil end
        restoreAll()
        if charConn then charConn:Disconnect(); charConn = nil end
    end

    local function setMaterial(m)
        local picked
        if typeof(m) == "EnumItem" and m.EnumType == Enum.Material then
            picked = m
        elseif type(m) == "string" then
            local norm = m:lower():gsub("[%s%.]+", "")
            if     norm == "neon"          then picked = Enum.Material.Neon
            elseif norm == "forcefield"    then picked = Enum.Material.ForceField
            elseif norm == "glass"         then picked = Enum.Material.Glass
            elseif norm == "plastic"       then picked = Enum.Material.Plastic
            elseif norm == "metal"         then picked = Enum.Material.Metal
            elseif norm == "smoothplastic" then picked = Enum.Material.SmoothPlastic
            else
                local ok, em = pcall(function() return Enum.Material[m] end)
                if ok and em then picked = em end
            end
        elseif type(m) == "table" then
            for k, v in pairs(m) do
                local name = (type(k) == "string") and k or v
                if type(name) == "string" then setMaterial(name); return end
            end
        end
        if picked then
            material = picked
            print("[witherhook] body material ->", picked.Name,
                  active and "(live)" or "(stored - turn toggle on to apply)")
        else
            warn("[witherhook] body material: unknown input", typeof(m), m)
        end
        if active then pushLiveValues() end
    end

    return {
        start    = start,
        stop     = stop,
        toggle   = function() if active then stop() else start() end end,
        isActive = function() return active end,
        setColor = function(c)
            if typeof(c) == "Color3" then
                color = c
                if active then pushLiveValues() end
            end
        end,
        setTransparency = function(n)
            transp = math.clamp(tonumber(n) or 0, 0, 1)
            if active then pushLiveValues() end
        end,
        setMaterial  = setMaterial,
        getColor     = function() return color end,
        getMaterial  = function() return material end,
    }
end)()

--  ROCKET JUMP

-- aimbot
F.aimbot = {
    settings   = AimbotSettings,
    setEnabled = function(b) AimbotSettings.Enabled = b == true end,
    toggle     = function() AimbotSettings.Enabled = not AimbotSettings.Enabled end,
    isActive   = function() return AimbotSettings.Enabled end,
    setFov     = function(n) AimbotSettings.FOVRadius = math.clamp(tonumber(n) or 130, 1, 1000) end,
    setHitPart = function(s) AimbotSettings.TargetPart = tostring(s) end,
    setMethod  = function(s) AimbotSettings.Method = tostring(s) end,
    setTeamCheck    = function(b) AimbotSettings.TeamCheck = b == true end,
    setVisibleCheck = function(b) AimbotSettings.VisibleCheck = b == true end,
    setShowFov      = function(b) AimbotSettings.ShowFOV = b == true end,
    setShowTarget   = function(b) AimbotSettings.ShowTarget = b == true end,
    setPrediction   = function(b) AimbotSettings.Prediction = b == true end,
    setPredictionAmount = function(n) AimbotSettings.PredictionAmount = math.clamp(tonumber(n) or 0.165, 0, 2) end,
    setHitChance    = function(n) AimbotSettings.HitChance = math.clamp(tonumber(n) or 100, 0, 100) end,
    setClosestPart  = function(b) AimbotSettings.ClosestPart = b == true end,
    getTarget       = function() return cachedTarget end,
}

-- camlock
F.camLock = {
    settings   = CamLockSettings,
    setEnabled = function(b) CamLockSettings.Enabled = b == true end,
    toggle     = function() CamLockSettings.Enabled = not CamLockSettings.Enabled end,
    isActive   = function() return CamLockSettings.Enabled end,
    setFov     = function(n) CamLockSettings.FOVRadius = math.clamp(tonumber(n) or 200, 1, 2000) end,
    setHitPart = function(s) CamLockSettings.TargetPart = tostring(s) end,
    setMode    = function(s) CamLockSettings.Mode = tostring(s) end,
    setSmoothing = function(n) CamLockSettings.Smoothing = math.clamp(tonumber(n) or 0.25, 0, 0.99) end,
    setTeamCheck    = function(b) CamLockSettings.TeamCheck = b == true end,
    setVisibleCheck = function(b) CamLockSettings.VisibleCheck = b == true end,
    setShowFov      = function(b) CamLockSettings.ShowFOV = b == true end,
    setSticky       = function(b) CamLockSettings.Sticky = b == true end,
    setPrediction   = function(b) CamLockSettings.Prediction = b == true end,
    setPredictionAmount = function(n) CamLockSettings.PredictionAmount = math.clamp(tonumber(n) or 0.165, 0, 2) end,
    setClosestPart  = function(b) CamLockSettings.ClosestPart = b == true end,
    setToolCheck    = function(b) CamLockSettings.ToolCheck = b == true end,
    setOnlyVisible  = function(b) CamLockSettings.OnlyVisible = b == true end,
    setOnlyFirstPerson = function(b) CamLockSettings.OnlyFirstPerson = b == true end,
}

-- triggerbot
F.triggerbot = {
    settings   = TrigSettings,
    setEnabled = function(b) TrigSettings.Enabled = b == true end,
    toggle     = function() TrigSettings.Enabled = not TrigSettings.Enabled end,
    isActive   = function() return TrigSettings.Enabled end,
    setFov     = function(n) TrigSettings.FOVRadius = math.clamp(tonumber(n) or 20, 1, 500) end,
    setDelay   = function(n) TrigSettings.ClickDelay = math.clamp(tonumber(n) or 0, 0, 2000) end,
    setTeamCheck    = function(b) TrigSettings.TeamCheck = b == true end,
    setVisibleCheck = function(b) TrigSettings.VisibleCheck = b == true end,
    setShowFov      = function(b) TrigSettings.ShowFOV = b == true end,
    setHitPart      = function(s) TrigSettings.TargetPart = tostring(s) end,
    setShowTarget   = function(b) TrigSettings.ShowTarget = b == true end,
    setToolCheck    = function(b) TrigSettings.ToolCheck = b == true end,
}

-- ragebot
F.ragebot = {
    settings    = RageSettings,
    lockClosest = rbLockClosest,
    lockPlayer  = rbLockByPlayer,
    addTarget   = rbAddTarget,
    unlock      = rbUnlock,
    tpBehind    = rbTpBehind,
    setSilentForce  = function(b) RageSettings.SilentForce = b == true end,
    setSilentMethod = function(s) RageSettings.SilentMethod = tostring(s) end,
    setShowLine     = function(b) RageSettings.ShowLine = b == true end,
    setShowOutline  = function(b) RageSettings.ShowOutline = b == true end,
    setLineOrigin   = function(s) RageSettings.LineOrigin = tostring(s) end,
    setOutlineColor = function(c) if typeof(c) == "Color3" then RageSettings.OutlineColor = c; if RB_outlineHL then RB_outlineHL.OutlineColor = c end end end,
    setLineColor    = function(c) if typeof(c) == "Color3" then RageSettings.LineColor    = c end end,
    setSkipKnocked  = function(b) RageSettings.SkipKnocked = b == true end,
    setIgnoreKnocked = function(b) RageSettings.IgnoreKnocked = b == true end,
    setFaceTarget  = function(b) RageSettings.FaceTarget = b == true end,
    setOrbit       = function(b) RageSettings.Orbit = b == true end,
    setOrbitDistance = function(n) RageSettings.OrbitDistance = math.clamp(tonumber(n) or 15, 2, 200) end,
    setOrbitSpeed    = function(n) RageSettings.OrbitSpeed    = math.clamp(tonumber(n) or 60, 1, 9999) end,
    setOrbitHeight   = function(n) RageSettings.OrbitHeight   = math.clamp(tonumber(n) or 5, -50, 50) end,
    setAutoShoot     = function(b) RageSettings.AutoShoot = b == true end,
    setAutoShootDist     = function(n) RageSettings.AutoShootDist = math.clamp(tonumber(n) or 50, 1, 500) end,
    setAutoShootCooldown = function(n) RageSettings.AutoShootCooldown = math.clamp(tonumber(n) or 100, 0, 10000) end,
    setAutoShootRequireTool = function(b) RageSettings.AutoShootRequireTool = b == true end,
    -- auto-equip-on-shoot
    setAutoShootEquip     = function(b) RageSettings.AutoShootEquip = b == true end,
    setAutoShootEquipTool = function(s) RageSettings.AutoShootEquipTool = tostring(s or "") end,
    getAutoShootEquipTool = function() return RageSettings.AutoShootEquipTool end,
    -- knocked grace
    setKnockedGraceDelay = function(n) RageSettings.KnockedGraceDelay = math.clamp(tonumber(n) or 0, 0, 20) end,
    getKnockedGraceDelay = function() return RageSettings.KnockedGraceDelay end,
    setAutoShootVis  = function(b) RageSettings.AutoShootVis = b == true end,
    setFFCheck       = function(b) RageSettings.FFCheck = b == true end,
    setEquipDelay    = function(n) RageSettings.EquipDelay = math.clamp(tonumber(n) or 0.5, 0, 5) end,
    setCamSnap       = function(b) RageSettings.CamSnap = b == true end,
    setCamSmoothing  = function(n) RageSettings.CamSmoothing = math.clamp(tonumber(n) or 0.15, 0.01, 0.99) end,
    setSpeedPanic    = function(b) RageSettings.SpeedPanic = b == true end,
    setSwitchByMouse = function(b) RageSettings.SwitchByMouse = b == true end,
    setPriority = function(s)
        local valid = { Closest=true, Mouse=true, Camera=true,
                        LowestHP=true, HighestThreat=true }
        if valid[s] then RageSettings.Priority = s end
    end,
    getPriority = function() return RageSettings.Priority end,
    getTarget        = function() return RageSettings.TargetPlayer end,
    getTargetList    = function()
        local out = {}
        for _, e in ipairs(_rbTargetList) do
            if e.plr and e.plr.Parent then table.insert(out, e.plr) end
        end
        return out
    end,
    isTargeted       = function(plr)
        if not plr then return false end
        for _, e in ipairs(_rbTargetList) do
            if e.userId == plr.UserId then return true end
        end
        return false
    end,
}

-- ESP
F.esp = {
    settings = EspSettings,
    start    = function() EspSettings.Enabled = true; startEspRender() end,
    stop     = function() EspSettings.Enabled = false; stopEspRender() end,
    toggle   = function()
        EspSettings.Enabled = not EspSettings.Enabled
        if EspSettings.Enabled then startEspRender() else stopEspRender() end
    end,
    isActive = function() return EspSettings.Enabled end,
    -- toggles
    setBox        = function(b) EspSettings.BoxESP        = b == true end,
    setNames      = function(b) EspSettings.NameESP       = b == true end,
    setHealth     = function(b) EspSettings.HealthESP     = b == true end,
    setHealthNum  = function(b) EspSettings.HealthNum     = b == true end,
    setDistance   = function(b) EspSettings.DistanceESP   = b == true end,
    setTracer     = function(b) EspSettings.TracerESP     = b == true end,
    setSkeleton   = function(b) EspSettings.SkeletonESP   = b == true end,
    setTeamCheck  = function(b) EspSettings.TeamCheck     = b == true end,
    setChams      = function(b) EspSettings.ChamsEnabled  = b == true end,
    setHeldItem   = function(b) EspSettings.HeldItem      = b == true end,
    setSelf       = function(b) EspSettings.SelfESP       = b == true end,
    setTracerHistory = function(b) EspSettings.TracerHistory = b == true end,
    setBoxStyle      = function(s) EspSettings.BoxStyle      = tostring(s) end,
    setTracerOrigin  = function(s) EspSettings.TracerOrigin  = tostring(s) end,
    setChamsStyle    = function(s) EspSettings.ChamsStyle    = tostring(s) end,
    setTracerHistLen = function(n) EspSettings.TracerHistLen = math.clamp(tonumber(n) or 2, 0.5, 10) end,
    -- Color setters. Render loop reads EspSettings.* each frame so
    setEnemyColor     = function(c) if typeof(c) == "Color3" then EspSettings.EnemyColor    = c end end,
    setTeamColor      = function(c) if typeof(c) == "Color3" then EspSettings.TeamColor     = c end end,
    setNeutralColor   = function(c) if typeof(c) == "Color3" then EspSettings.NeutralColor  = c end end,
    setChamsFill      = function(c) if typeof(c) == "Color3" then EspSettings.ChamsFill     = c end end,
    setChamsOutline   = function(c) if typeof(c) == "Color3" then EspSettings.ChamsOutline  = c end end,
    setTracerColor    = function(c) if typeof(c) == "Color3" then EspSettings.TracerColor   = c end end,
}

-- players
F.players = {
    list   = function() return plrs:GetPlayers() end,
    find   = findPlayerByName,
    goto   = gotoPlayer,
    view   = viewPlayer,
    fling  = flingPlayer,
    follow = followPlayer,
    followStop = followStop,
    isFollowing = function() return _follow.target end,
    setFollowVisualize = followSetVisualize,
    getFollowVisualize = function() return _follow.viz end,
}

--  AUTO-TARGETER

-- utility helpers (exposed for advanced users)
F.utils = {
    isReallyVisible = isReallyVisible,
    setStrictVisibleCheck = function(v) _visStrict = v == true end,
    getStrictVisibleCheck = function() return _visStrict end,
    setVisibleOrigin = function(s)
        local valid = { Camera = true, Head = true, Tool = true }
        if valid[s] then _visOrigin = s end
    end,
    getVisibleOrigin = function() return _visOrigin end,
    findClosestPlayer = function(opts)
        opts = opts or {}
        local cam = workspace.CurrentCamera
        local mp  = UserInputService:GetMouseLocation()
        local maxDist = opts.fov or math.huge
        local exclude = opts.exclude  -- table mapping [Player] = true
        local best, bestD = nil, maxDist + 1
        for _, p in ipairs(plrs:GetPlayers()) do
            if p == lplr then continue end
            if exclude and exclude[p] then continue end
            if opts.teamCheck and p.Team == lplr.Team then continue end
            local char = p.Character; if not char then continue end
            local hum = char:FindFirstChildOfClass("Humanoid"); local hrp = char:FindFirstChild("HumanoidRootPart")
            if not hrp or not hum or hum.Health <= 0 then continue end
            local sp, on = cam:WorldToViewportPoint(hrp.Position); if not on then continue end
            local d = (mp - Vector2.new(sp.X, sp.Y)).Magnitude
            if d < bestD then bestD = d; best = p end
        end
        return best
    end,
    getCharacter = function() return lplr.Character end,
    getRoot      = function() local c=lplr.Character; return c and c:FindFirstChild("HumanoidRootPart") end,
    getHumanoid  = function() local c=lplr.Character; return c and c:FindFirstChildOfClass("Humanoid") end,
}

--  ANTI-FLING
F.antiFling = (function()
    local cap     = 5000      -- stud/sec, both linear and angular
    local hbConn
    local charConn

    local function clampHrp()
        local c = lplr.Character; if not c then return end
        local hrp = c:FindFirstChild("HumanoidRootPart"); if not hrp then return end
        local v  = hrp.AssemblyLinearVelocity
        local av = hrp.AssemblyAngularVelocity
        if v and v.Magnitude > cap then
            pcall(function() hrp.AssemblyLinearVelocity = Vector3.zero end)
        end
        if av and av.Magnitude > cap then
            pcall(function() hrp.AssemblyAngularVelocity = Vector3.zero end)
        end
        -- some flings target other body parts (Torso, limbs); sweep
        for _, name in ipairs({"UpperTorso","LowerTorso","Torso","Head"}) do
            local p = c:FindFirstChild(name)
            if p and p:IsA("BasePart") then
                local pv  = p.AssemblyLinearVelocity
                local pav = p.AssemblyAngularVelocity
                if pv and pv.Magnitude > cap then
                    pcall(function() p.AssemblyLinearVelocity = Vector3.zero end)
                end
                if pav and pav.Magnitude > cap then
                    pcall(function() p.AssemblyAngularVelocity = Vector3.zero end)
                end
            end
        end
    end

    local function start()
        G.antiFlingActive = true
        if hbConn then hbConn:Disconnect() end
        hbConn = RunService.Heartbeat:Connect(function()
            if not G.antiFlingActive then return end
            clampHrp()
        end)
        if charConn then charConn:Disconnect() end
        charConn = lplr.CharacterAdded:Connect(function() task.wait(0.2); clampHrp() end)
    end

    local function stop()
        G.antiFlingActive = false
        if hbConn   then hbConn:Disconnect();   hbConn   = nil end
        if charConn then charConn:Disconnect(); charConn = nil end
    end

    local t = makeToggle(start, stop, "antiFlingActive")
    t.setCap = function(n) cap = math.max(50, tonumber(n) or 5000) end
    t.getCap = function() return cap end
    return t
end)()

--  FORCE CHAT  (re-enable chat in games that hid it)
F.forceChat = (function()
    local StarterGui = game:GetService("StarterGui")
    local TextChatService = game:GetService("TextChatService")

    -- Apply chat state. The input box (chatbox) is ALWAYS kept usable; only
    local function applyState(showWindow)
        pcall(function()
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
        end)
        if TextChatService then
            for _, c in ipairs(TextChatService:GetDescendants()) do
                if c:IsA("ChatInputBarConfiguration") or c:IsA("BubbleChatConfiguration") then
                    pcall(function() c.Enabled = true end)          -- chatbox + bubbles stay
                elseif c:IsA("ChatWindowConfiguration") then
                    pcall(function() c.Enabled = showWindow end)    -- only the message window
                end
            end
        end
    end

    -- keep-alive loop; runs while a state is set ("on"/"off"), exits on unload
    local function ensureLoop()
        if G._forceChatLoop then return end
        G._forceChatLoop = true
        task.spawn(function()
            while G.forceChatState do
                applyState(G.forceChatState == "on")
                task.wait(2)
            end
            G._forceChatLoop = false
        end)
    end

    local function start()
        G.forceChatActive = true
        G.forceChatState  = "on"     -- message window + chatbox
        ensureLoop()
        applyState(true)
    end

    -- Off hides the message window (where people's messages appear) but keeps
    local function stop()
        G.forceChatActive = false
        G.forceChatState  = "off"    -- window hidden, chatbox kept
        ensureLoop()
        applyState(false)
    end

    local toggle = makeToggle(start, stop, "forceChatActive")
    -- unload: stop the loop and restore the full normal chat
    toggle.fullStop = function()
        G.forceChatActive = false
        G.forceChatState  = nil      -- loop exits
        applyState(true)
    end
    return toggle
end)()

--  PROXIMITY PROMPTS  (3 independent modules)
F.prompts = (function()
    -- Each prompt: ONE PropertyChangedSignal per watched property + ONE

    local installed = setmetatable({}, { __mode = "k" })
    local ATTR_HOLD = "_F_origHoldDuration"
    local ATTR_DIST = "_F_origMaxDist"
    local ATTR_LOS  = "_F_origRequiresLoS"

    local function installAll(prompt)
        if installed[prompt] then return end
        installed[prompt] = true

        -- stash originals once. Only write the attribute if it's missing,
        if prompt:GetAttribute(ATTR_HOLD) == nil then
            prompt:SetAttribute(ATTR_HOLD, prompt.HoldDuration)
        end
        if prompt:GetAttribute(ATTR_DIST) == nil then
            prompt:SetAttribute(ATTR_DIST, prompt.MaxActivationDistance)
        end
        if prompt:GetAttribute(ATTR_LOS) == nil then
            prompt:SetAttribute(ATTR_LOS, prompt.RequiresLineOfSight)
        end

        prompt:GetPropertyChangedSignal("HoldDuration"):Connect(function()
            if G.promptInstantActive and prompt.HoldDuration ~= 0 then
                pcall(function() prompt.HoldDuration = 0 end)
            end
        end)
        prompt:GetPropertyChangedSignal("MaxActivationDistance"):Connect(function()
            if G.promptRangeActive and prompt.MaxActivationDistance ~= math.huge then
                pcall(function() prompt.MaxActivationDistance = math.huge end)
            end
        end)
        prompt:GetPropertyChangedSignal("RequiresLineOfSight"):Connect(function()
            if G.promptWallsActive and prompt.RequiresLineOfSight then
                pcall(function() prompt.RequiresLineOfSight = false end)
            end
        end)
        prompt.PromptShown:Connect(function()
            if G.promptAutoFireActive and fireproximityprompt then
                pcall(function() fireproximityprompt(prompt) end)
            end
        end)

        -- apply currently-active states
        if G.promptInstantActive then pcall(function() prompt.HoldDuration = 0 end) end
        if G.promptRangeActive   then pcall(function() prompt.MaxActivationDistance = math.huge end) end
        if G.promptWallsActive   then pcall(function() prompt.RequiresLineOfSight   = false end) end
    end

    if not getgenv()._F_PROMPT_HOOKED then
        getgenv()._F_PROMPT_HOOKED = true
        workspace.DescendantAdded:Connect(function(d)
            if d:IsA("ProximityPrompt") then installAll(d) end
        end)
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") then installAll(d) end
        end
    end

    -- ---- generic apply / restore helpers ----
    local function sweep(applyFn)
        for prompt in pairs(installed) do
            if prompt.Parent then pcall(function() applyFn(prompt) end) end
        end
    end
    local function restoreFromAttr(attr, prop, fallback)
        for prompt in pairs(installed) do
            if prompt.Parent then
                local orig = prompt:GetAttribute(attr)
                if orig == nil then orig = fallback end
                pcall(function() prompt[prop] = orig end)
            end
        end
    end

    local instantActivation = makeToggle(
        function()
            G.promptInstantActive = true
            sweep(function(p) p.HoldDuration = 0 end)
        end,
        function()
            G.promptInstantActive = false
            restoreFromAttr(ATTR_HOLD, "HoldDuration", 1)
        end,
        "promptInstantActive"
    )
    local unlimitedRange = makeToggle(
        function()
            G.promptRangeActive = true
            sweep(function(p) p.MaxActivationDistance = math.huge end)
        end,
        function()
            G.promptRangeActive = false
            restoreFromAttr(ATTR_DIST, "MaxActivationDistance", 10)
        end,
        "promptRangeActive"
    )
    local throughWalls = makeToggle(
        function()
            G.promptWallsActive = true
            sweep(function(p) p.RequiresLineOfSight = false end)
        end,
        function()
            G.promptWallsActive = false
            restoreFromAttr(ATTR_LOS, "RequiresLineOfSight", true)
        end,
        "promptWallsActive"
    )
    local autoFire = makeToggle(
        function() G.promptAutoFireActive = true end,
        function() G.promptAutoFireActive = false end,
        "promptAutoFireActive"
    )

    return {
        instantActivation = instantActivation,
        unlimitedRange    = unlimitedRange,
        throughWalls      = throughWalls,
        autoFire          = autoFire,
    }
end)()

--  SERVER HOPPER
local TeleportService = game:GetService("TeleportService")

--  DAMAGE DETECTION  ("creator" tag pattern)
local _damageCallbacks = {}

local function _isDamageTag(name)
    if not name then return false end
    local n = string.lower(name)
    return n == "creator" or n == "damagesource" or n == "attacker" or n == "killer"
end

local function _watchDamage(char)
    if not char then return end
    local hum = char:WaitForChild("Humanoid", 5); if not hum then return end
    local conn = hum.ChildAdded:Connect(function(c)
        if not c:IsA("ObjectValue") then return end
        if not _isDamageTag(c.Name) then return end
        local v = c.Value
        if typeof(v) ~= "Instance" then return end
        local attacker
        if v:IsA("Player") then attacker = v
        elseif v:IsA("Model") then attacker = plrs:GetPlayerFromCharacter(v)
        end
        if attacker and attacker ~= lplr then
            for _, cb in ipairs(_damageCallbacks) do pcall(cb, attacker) end
        end
    end)
    char.AncestryChanged:Connect(function()
        if not char.Parent then pcall(function() conn:Disconnect() end) end
    end)
end

if lplr.Character then task.spawn(_watchDamage, lplr.Character) end
lplr.CharacterAdded:Connect(_watchDamage)

--  RAGEBOT: TP-SHOOT
F.ragebot.tpShoot = function()
    local target = RageSettings.TargetPlayer
    if not target then return end
    local char = target.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local lc   = lplr.Character
    local lhrp = lc and lc:FindFirstChild("HumanoidRootPart")
    if not lhrp then return end

    local saved = lhrp.CFrame
    -- TP into the target, upright, facing target's horizontal direction
    local lv = hrp.CFrame.LookVector
    local horiz = Vector3.new(lv.X, 0, lv.Z)
    if horiz.Magnitude < 0.01 then horiz = Vector3.new(0, 0, -1) end
    horiz = horiz.Unit
    local position = hrp.Position - horiz * (RageSettings.TpBehindDist or 0)
    _uprightTp(lc, lhrp, position, horiz)

    pcall(function()
        local vim = VirtualInputManager
        vim:SendMouseButtonEvent(0, 0, 0, true,  game, 0)
        vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
    end)

    -- Detect rage-target stomp mode at call time. If on, instead of the
    local rageOn = F.games and F.games.hoodCustoms
        and F.games.hoodCustoms.autoStomp
        and F.games.hoodCustoms.autoStomp.getRageTargets
        and F.games.hoodCustoms.autoStomp.getRageTargets()

    -- run the wait + restore in a separate coroutine so the keybind handler
    task.spawn(function()
        if rageOn then
            -- wait for the TARGET's BodyEffects.Dead to become true.
            local deadline = tick() + 10
            local function targetDead()
                local function isTrue(node)
                    local fx = node and node:FindFirstChild("BodyEffects")
                    local d  = fx and fx:FindFirstChild("Dead")
                    return d ~= nil and d.Value == true
                end
                if isTrue(target.Character) then return true end
                local wsp = workspace:FindFirstChild("Players")
                local chars = wsp and wsp:FindFirstChild("Characters")
                local mdl = chars and chars:FindFirstChild(target.Name)
                if isTrue(mdl) then return true end
                return false
            end
            while tick() < deadline do
                if targetDead() then break end
                task.wait()
            end
        else
            task.wait(0.15)
        end

        local nc = lplr.Character
        local nhrp = nc and nc:FindFirstChild("HumanoidRootPart")
        if nhrp then
            _uprightTp(nc, nhrp, saved.Position, saved.LookVector)
        end
    end)
end

--  RAGEBOT: TARGET HUD  (floating panel with avatar/name/hp/tool/dist)
local _rbHud, _rbHudConn, _rbHudFrame, _rbAvatar, _rbName, _rbHpFill, _rbHeld, _rbDist
local _rbHudLastUid = nil

local function _buildRbHud()
    if _rbHud and _rbHud.Parent then return end
    local sg = Instance.new("ScreenGui")
    sg.Name = "_wh_rb_hud"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Global
    sg.DisplayOrder = 9997
    pcall(function() sg.Parent = lplr:WaitForChild("PlayerGui") end)
    if not sg.Parent then sg.Parent = game:GetService("CoreGui") end
    _rbHud = sg

    local frame = Instance.new("Frame")
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
    frame.BackgroundTransparency = 0.12
    frame.BorderSizePixel = 0
    frame.AnchorPoint = Vector2.new(0.5, 1)
    frame.Position = UDim2.new(0.5, 0, 1, -90)
    frame.Size = UDim2.new(0, 320, 0, 64)
    frame.Visible = false
    frame.Parent = sg
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = frame end
    do local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(60, 60, 70); s.Thickness = 1
       s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; s.Parent = frame end
    _rbHudFrame = frame

    local avatar = Instance.new("ImageLabel")
    avatar.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
    avatar.BorderSizePixel = 0
    avatar.Size = UDim2.new(0, 52, 0, 52)
    avatar.AnchorPoint = Vector2.new(0, 0.5)
    avatar.Position = UDim2.new(0, 6, 0.5, 0)
    avatar.ScaleType = Enum.ScaleType.Crop
    avatar.Image = ""
    avatar.Parent = frame
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = avatar end
    _rbAvatar = avatar

    local text = Instance.new("Frame")
    text.BackgroundTransparency = 1
    text.BorderSizePixel = 0
    text.AnchorPoint = Vector2.new(0, 0)
    text.Position = UDim2.new(0, 64, 0, 4)
    text.Size = UDim2.new(1, -70, 1, -8)
    text.Parent = frame
    do local l = Instance.new("UIListLayout"); l.SortOrder = Enum.SortOrder.LayoutOrder
       l.Padding = UDim.new(0, 2); l.Parent = text end

    local function lbl(order, h)
        local l = Instance.new("TextLabel"); l.BackgroundTransparency = 1; l.BorderSizePixel = 0
        l.Size = UDim2.new(1, 0, 0, h or 13); l.LayoutOrder = order
        l.Font = Enum.Font.Gotham; l.Text = ""; l.TextColor3 = Color3.fromRGB(235, 235, 240)
        l.TextScaled = true; l.TextXAlignment = Enum.TextXAlignment.Left; l.Parent = text
        local c = Instance.new("UITextSizeConstraint"); c.MaxTextSize = 11; c.Parent = l
        return l
    end

    _rbName = lbl(1, 13)
    -- health bar (between name and held)
    local hpBg = Instance.new("Frame"); hpBg.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    hpBg.BorderSizePixel = 0; hpBg.Size = UDim2.new(1, 0, 0, 6); hpBg.LayoutOrder = 2
    hpBg.Parent = text
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 3); c.Parent = hpBg end
    _rbHpFill = Instance.new("Frame")
    _rbHpFill.BackgroundColor3 = Color3.fromRGB(75, 200, 95)
    _rbHpFill.BorderSizePixel = 0; _rbHpFill.Size = UDim2.new(1, 0, 1, 0); _rbHpFill.Parent = hpBg
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 3); c.Parent = _rbHpFill end

    _rbHeld = lbl(3, 11)
    _rbDist = lbl(4, 11)
end

local function _rbHudUpdate()
    if not _rbHudFrame then return end
    local plr = RageSettings.TargetPlayer
    local char = plr and plr.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not plr or not hrp or not hum or hum.Health <= 0 then
        _rbHudFrame.Visible = false
        return
    end
    _rbHudFrame.Visible = true

    local dn = plr.DisplayName
    local un = plr.Name
    _rbName.Text = (dn ~= un and dn .. " (@" .. un .. ")" or "@" .. un) .. " / " .. tostring(plr.UserId)
    _rbName.TextColor3 = Color3.fromRGB(140, 200, 255)

    local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
    _rbHpFill.Size = UDim2.new(pct, 0, 1, 0)
    _rbHpFill.BackgroundColor3 = Color3.fromRGB(
        math.floor((1 - pct) * 220) + 35,
        math.floor(pct * 180) + 55,
        40)

    local tool = char:FindFirstChildOfClass("Tool")
    _rbHeld.Text = "Holding: " .. (tool and tool.Name or "none")
    _rbHeld.TextColor3 = tool and Color3.fromRGB(255, 215, 60) or Color3.fromRGB(160, 160, 170)

    local lc = lplr.Character
    local lhrp = lc and lc:FindFirstChild("HumanoidRootPart")
    if lhrp then
        _rbDist.Text = ("Distance: %d studs"):format(math.floor((lhrp.Position - hrp.Position).Magnitude))
    else _rbDist.Text = "" end
    _rbDist.TextColor3 = Color3.fromRGB(160, 160, 170)

    if plr.UserId ~= _rbHudLastUid then
        _rbHudLastUid = plr.UserId
        _rbAvatar.Image = ""
        task.spawn(function()
            local ok, img = pcall(function()
                return plrs:GetUserThumbnailAsync(plr.UserId,
                    Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size420x420)
            end)
            if ok and _rbAvatar then _rbAvatar.Image = img end
        end)
    end
end

local function startRbTargetGui()
    G.rbTargetGuiActive = true
    _buildRbHud()
    if _rbHud then _rbHud.Enabled = true end
    if _rbHudConn then _rbHudConn:Disconnect() end
    _rbHudConn = RunService.RenderStepped:Connect(function()
        if not G.rbTargetGuiActive then return end
        _rbHudUpdate()
    end)
end

local function stopRbTargetGui()
    G.rbTargetGuiActive = false
    if _rbHudConn then _rbHudConn:Disconnect(); _rbHudConn = nil end
    if _rbHudFrame then _rbHudFrame.Visible = false end
    if _rbHud then _rbHud.Enabled = false end
end

F.ragebot.targetGui = makeToggle(startRbTargetGui, stopRbTargetGui, "rbTargetGuiActive")

--  AUTO-EQUIP

--  AUTO WEAPON SWITCH

--  AUTO-REJOIN ON KICK / VOTEKICK
F.games = F.games or {}
F.util = {
    lplr              = lplr,
    players           = plrs,
    runService        = RunService,
    uis               = UserInputService,
    vim               = VirtualInputManager,
    replicatedStorage = ReplicatedStorage,
    makeToggle        = makeToggle,
    uprightTp         = _uprightTp,
    state             = G,
    visibleCheck      = isReallyVisible,   -- (fromPos, toPos, ignoreList)
    getVisOrigin      = _visGetOrigin,
}

--  MOVEMENT: DESYNC  (multiple spoof methods)
F.desync = (function()
    local VOID_MIN     = 5000
    local VOID_MAX     = 20000
    -- Knife Voidspam has its own tighter range so the spoofed
    local VOIDSPAM_MIN = 5000
    local VOIDSPAM_MAX = 10000
    local SHOT_SYNC_MS = 100
    local SPIN_STEP    = 47
    local VEL_MAGNITUDE = 16384
    -- sky desync: how many studs to shove HRP up server-side (X/Z preserved)
    local SKY_HEIGHT   = 5000
    -- invisible desync: tight-radius void TP. Picks a base void point
    local INVIS_BASE_DIST = 1500   -- how far the cluster center is from origin
    local INVIS_RADIUS    = 25     -- jitter radius around the cluster center

    -- shared state in getgenv() so the raknet hook (which is installed
    getgenv()._F_DESYNC_STATE = getgenv()._F_DESYNC_STATE or { active = false, mode = "off" }
    local SHARED = getgenv()._F_DESYNC_STATE

    local active   = false
    local mode     = "off"   -- "void"|"voidspam"|"sky"|"spin"|"velocity"|"raknet"|"invisible"|"off"
    local _invisBase  -- cluster center for invisible mode (picked once per session)
    local realCF, realLV, realAV
    local syncEnd  = 0
    local hbConn
    local RESTORE_BIND = "_F_DESYNC_RESTORE"
    local _spinAngle = 0

    local function randVoidPos()
        local function axis()
            local mag = VOID_MIN + math.random() * (VOID_MAX - VOID_MIN)
            return (math.random() < 0.5) and -mag or mag
        end
        return Vector3.new(axis(), axis(), axis())
    end

    -- compute the spoofed HRP state for the current mode. Caller is
    local function applySpoof(hrp)
        if mode == "void" then
            hrp.CFrame = CFrame.new(randVoidPos())
        elseif mode == "voidspam" then
            -- Tighter range than regular void (VOIDSPAM_MIN..MAX,
            local function axis()
                local m = VOIDSPAM_MIN + math.random() * (VOIDSPAM_MAX - VOIDSPAM_MIN)
                return (math.random() < 0.5) and -m or m
            end
            hrp.CFrame = CFrame.new(Vector3.new(axis(), axis(), axis()))
        elseif mode == "sky" then
            -- preserve XZ + rotation, push Y up by SKY_HEIGHT. server sees
            local cf = hrp.CFrame
            hrp.CFrame = cf + Vector3.new(0, SKY_HEIGHT, 0)
        elseif mode == "spin" then
            _spinAngle = (_spinAngle + SPIN_STEP) % 360
            hrp.CFrame = hrp.CFrame * CFrame.Angles(
                math.rad(_spinAngle),
                math.rad(_spinAngle * 2),
                math.rad(_spinAngle * 0.5)
            )
        elseif mode == "velocity" then
            -- CFrame untouched - we only spoof the velocity vector
            hrp.AssemblyLinearVelocity = Vector3.new(1, 1, 1) * VEL_MAGNITUDE
        elseif mode == "invisible" then
            -- Tight-radius void cluster. Pick the cluster center once
            if not _invisBase then
                local function axis()
                    return ((math.random() < 0.5) and -1 or 1) * INVIS_BASE_DIST
                end
                _invisBase = Vector3.new(axis(), axis(), axis())
            end
            local r = INVIS_RADIUS
            local jitter = Vector3.new(
                (math.random() * 2 - 1) * r,
                (math.random() * 2 - 1) * r,
                (math.random() * 2 - 1) * r
            )
            hrp.CFrame = CFrame.new(_invisBase + jitter)
        end
    end

    local function bind()
        if hbConn then hbConn:Disconnect() end
        pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)

        hbConn = RunService.Heartbeat:Connect(function()
            if not active then return end
            local c = lplr.Character
            local hrp = c and c:FindFirstChild("HumanoidRootPart")
            if not hrp then return end
            realCF = hrp.CFrame
            realLV = hrp.AssemblyLinearVelocity
            realAV = hrp.AssemblyAngularVelocity
            -- voidspam: pure void desync (random per-frame position)
            if mode == "voidspam" then
                local ge = getgenv()._F_DESYNC_SYNC_END or 0
                if tick() < ge then return end
            end
            pcall(function() applySpoof(hrp) end)
        end)

        RunService:BindToRenderStep(
            RESTORE_BIND, Enum.RenderPriority.First.Value,
            function()
                if not active then return end
                local c = lplr.Character
                local hrp = c and c:FindFirstChild("HumanoidRootPart")
                if not hrp or not realCF then return end
                pcall(function()
                    hrp.CFrame = realCF
                    if realLV then hrp.AssemblyLinearVelocity  = realLV end
                    if realAV then hrp.AssemblyAngularVelocity = realAV end
                end)
            end
        )
    end

    -- raknet desync: hook outbound packet 0x1B (physics replication) and
    local function findRaknet()
        local r = rawget(getgenv(), "raknet")
        if r then return r end
        local ok, val = pcall(function() return raknet end)
        if ok and val then return val end
        return nil
    end

    local function ensureRaknetHook()
        if getgenv()._F_DESYNC_RAKNET_INSTALLED then return true end
        local r = findRaknet()
        if not r or not r.add_send_hook then return false end
        getgenv()._F_DESYNC_RAKNET_INSTALLED = true
        -- pin the hook function on getgenv so it can't be garbage-collected
        getgenv()._F_DESYNC_RAKNET_FN = function(packet)
            local s = getgenv()._F_DESYNC_STATE
            if not s or not s.active or s.mode ~= "raknet" then return end
            if packet.PacketId == 0x1B then
                -- BLOCK the outbound physics replication packet entirely
                pcall(function() packet:SetCanBeSent(false) end)
                pcall(function() packet:Drop() end)
                pcall(function() packet:Block() end)
                pcall(function() packet:Ignore() end)
                return false
            end
        end
        pcall(function()
            r.add_send_hook(getgenv()._F_DESYNC_RAKNET_FN)
        end)
        return true
    end

    -- watchdog: re-asserts SHARED.active state every 1s AND re-installs the
    if not getgenv()._F_DESYNC_RAKNET_WATCHDOG then
        getgenv()._F_DESYNC_RAKNET_WATCHDOG = true
        task.spawn(function()
            local lastReinstall = 0
            while true do
                task.wait(1)
                local s = getgenv()._F_DESYNC_STATE
                local want = getgenv()._F_DESYNC_RAKNET_WANTED
                if want and s then
                    -- (a) state re-assert (fast path)
                    if not s.active or s.mode ~= "raknet" then
                        s.active = true
                        s.mode   = "raknet"
                    end
                    -- (b) hook re-install (slow path, every 10s)
                    if tick() - lastReinstall >= 10 then
                        lastReinstall = tick()
                        local r = findRaknet()
                        if r and r.add_send_hook and getgenv()._F_DESYNC_RAKNET_FN then
                            pcall(function()
                                r.add_send_hook(getgenv()._F_DESYNC_RAKNET_FN)
                            end)
                        end
                    end
                end
            end
        end)
    end

    -- voidspam: pure input-based trigger. On MouseButton1 down, set
    local KNIFE_SWING_ANIM_ID = "rbxassetid://15862130681"

    local function _voidspamArmFromAnim(track)
        local L = track.Length
        if not L or L <= 0 then
            -- Length isn't published yet (e.g., first play). Fall
            L = 0.5
        end
        local startFrac = (getgenv()._F_DESYNC_SHOT_DELAY_MS or 40) / 100
        local endFrac   = (getgenv()._F_DESYNC_SHOT_SYNC_MS  or 90) / 100
        startFrac = math.clamp(startFrac, 0, 1)
        endFrac   = math.clamp(endFrac,   0, 1)
        if endFrac < startFrac then endFrac = startFrac end  -- guard
        local startAt = startFrac * L            -- seconds from anim start
        local endAt   = endFrac   * L            -- seconds from anim start
        local hold    = math.max(0, endAt - startAt)

        task.delay(startAt, function()
            local s2 = getgenv()._F_DESYNC_STATE
            if not s2 or not s2.active or s2.mode ~= "voidspam" then return end
            local endTime = tick() + hold
            -- extend SYNC_END if the new end is later; never shrink
            if endTime > (getgenv()._F_DESYNC_SYNC_END or 0) then
                getgenv()._F_DESYNC_SYNC_END = endTime
            end
        end)
    end

    if not getgenv()._F_DESYNC_ANIM_HOOK then
        getgenv()._F_DESYNC_ANIM_HOOK = true
        local connByAnimator = setmetatable({}, { __mode = "k" })

        local function hookAnimator(animator)
            if not animator or connByAnimator[animator] then return end
            connByAnimator[animator] = animator.AnimationPlayed:Connect(function(track)
                local s = getgenv()._F_DESYNC_STATE
                if not s or not s.active or s.mode ~= "voidspam" then return end
                local a = track.Animation
                if not a or a.AnimationId ~= KNIFE_SWING_ANIM_ID then return end
                _voidspamArmFromAnim(track)
            end)
        end

        local function hookChar(char)
            if not char then return end
            local hum = char:WaitForChild("Humanoid", 5); if not hum then return end
            local animator = hum:WaitForChild("Animator", 5)
            hookAnimator(animator)
        end

        if lplr.Character then hookChar(lplr.Character) end
        lplr.CharacterAdded:Connect(hookChar)
    end
    -- mirror SHOT_SYNC_MS into getgenv so the input listener (which is
    getgenv()._F_DESYNC_SHOT_SYNC_MS  = SHOT_SYNC_MS
    getgenv()._F_DESYNC_SHOT_DELAY_MS = getgenv()._F_DESYNC_SHOT_DELAY_MS or 40

    --  Server-position marker (lightweight)
    local ghostPart, ghostHighlight, ghostVfxConn

    local function ghostRemove()
        if ghostVfxConn   then ghostVfxConn:Disconnect();   ghostVfxConn   = nil end
        if ghostHighlight then ghostHighlight:Destroy();    ghostHighlight = nil end
        if ghostPart      then ghostPart:Destroy();         ghostPart      = nil end
    end

    local function ghostCreate(pos)
        ghostRemove()

        ghostPart = Instance.new("Part")
        ghostPart.Name         = "_DesyncServerMarker"
        ghostPart.Anchored     = true
        ghostPart.CanCollide   = false
        ghostPart.CanTouch     = false
        ghostPart.CanQuery     = false
        ghostPart.CastShadow   = false
        ghostPart.Massless     = true
        ghostPart.Material     = Enum.Material.Neon
        ghostPart.Color        = Color3.fromRGB(0, 220, 255)
        ghostPart.Size         = Vector3.new(2, 5, 1)
        ghostPart.Transparency = 0.35
        ghostPart.CFrame       = CFrame.new(pos)
        ghostPart.Parent       = workspace

        ghostHighlight = Instance.new("Highlight")
        ghostHighlight.FillColor           = Color3.fromRGB(0, 220, 255)
        ghostHighlight.OutlineColor        = Color3.fromRGB(255, 255, 255)
        ghostHighlight.FillTransparency    = 0.35
        ghostHighlight.OutlineTransparency = 0
        ghostHighlight.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
        ghostHighlight.Adornee             = ghostPart
        ghostHighlight.Parent              = ghostPart

        -- slow pulse so it's clearly visible without flashing.
        ghostVfxConn = RunService.RenderStepped:Connect(function()
            if not ghostPart or not ghostPart.Parent then return end
            local t = tick() * 4
            ghostPart.Transparency           = 0.20 + 0.15 * (math.sin(t)           * 0.5 + 0.5)
            ghostHighlight.FillTransparency  = 0.20 + 0.20 * (math.sin(t + math.pi) * 0.5 + 0.5)
        end)
    end

    local function startMode(newMode)
        mode = newMode
        active = true
        syncEnd = 0
        SHARED.active = true
        SHARED.mode   = newMode
        -- watchdog flag: tells the periodic re-asserter to keep SHARED in
        getgenv()._F_DESYNC_RAKNET_WANTED = (newMode == "raknet")
        if newMode == "raknet" then
            if hbConn then hbConn:Disconnect(); hbConn = nil end
            pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
            -- build the ghost at the current HRP position so the user
            local c = lplr.Character
            local hrp = c and c:FindFirstChild("HumanoidRootPart")
            if hrp then ghostCreate(hrp.Position) end
            return
        end
        -- non-raknet mode: tear down any existing ghost
        ghostRemove()
        bind()
    end

    local function stopAll()
        active = false
        SHARED.active = false
        SHARED.mode   = "off"
        getgenv()._F_DESYNC_RAKNET_WANTED = false
        getgenv()._F_DESYNC_SYNC_END      = 0
        -- always remove the ghost on any stop (cheap if it doesn't exist)
        ghostRemove()
        -- We intentionally DO NOT call r.remove_send_hook here. The hook
        if hbConn then hbConn:Disconnect(); hbConn = nil end
        pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
        local c = lplr.Character
        local hrp = c and c:FindFirstChild("HumanoidRootPart")
        if hrp and realCF then
            pcall(function()
                hrp.CFrame = realCF
                if realLV then hrp.AssemblyLinearVelocity  = realLV end
                if realAV then hrp.AssemblyAngularVelocity = realAV end
            end)
        end
        realCF, realLV, realAV = nil, nil, nil
        mode = "off"
    end

    --  Sync window visualizer
    local syncVisualEnabled = false
    local syncVisualText, syncVisualBg, syncVisualConn

    local function syncVisualRemove()
        if syncVisualConn then syncVisualConn:Disconnect(); syncVisualConn = nil end
        if syncVisualText then pcall(function() syncVisualText:Remove() end); syncVisualText = nil end
        if syncVisualBg   then pcall(function() syncVisualBg:Remove()   end); syncVisualBg   = nil end
    end

    local function syncVisualCreate()
        if syncVisualText then return end
        if not Drawing or not Drawing.new then return end
        syncVisualBg = Drawing.new("Square")
        syncVisualBg.Visible      = false
        syncVisualBg.Color        = Color3.fromRGB(220, 40, 40)
        syncVisualBg.Filled       = true
        syncVisualBg.Transparency = 0.55
        syncVisualBg.Thickness    = 1

        syncVisualText = Drawing.new("Text")
        syncVisualText.Visible      = false
        syncVisualText.Center       = true
        syncVisualText.Outline      = true
        syncVisualText.OutlineColor = Color3.new(0, 0, 0)
        syncVisualText.Color        = Color3.fromRGB(255, 230, 230)
        syncVisualText.Size         = 22
        syncVisualText.Font         = 2  -- bold
        syncVisualText.Text         = "VULNERABLE"

        syncVisualConn = RunService.RenderStepped:Connect(function()
            if not syncVisualEnabled then
                if syncVisualText then syncVisualText.Visible = false end
                if syncVisualBg   then syncVisualBg.Visible   = false end
                return
            end
            local active = tick() < (getgenv()._F_DESYNC_SYNC_END or 0)
            if active then
                local cam = workspace.CurrentCamera
                local vs  = cam and cam.ViewportSize or Vector2.new(800, 600)
                local cx  = vs.X * 0.5
                local cy  = 60
                local w, h = 200, 30
                syncVisualBg.Position   = Vector2.new(cx - w * 0.5, cy - 4)
                syncVisualBg.Size       = Vector2.new(w, h)
                syncVisualBg.Visible    = true
                syncVisualText.Position = Vector2.new(cx, cy)
                syncVisualText.Visible  = true
            else
                syncVisualText.Visible = false
                syncVisualBg.Visible   = false
            end
        end)
    end

    return {
        -- mode starters - mutually exclusive (calling one auto-stops any
        startVoid       = function() startMode("void") end,
        startVoidspam   = function() startMode("voidspam") end,
        startSky        = function() startMode("sky") end,
        startSpin       = function() startMode("spin") end,
        startVelocity   = function() startMode("velocity") end,
        startRaknet     = function()
            if not ensureRaknetHook() then return false end
            startMode("raknet")
            return true
        end,
        startInvisible  = function()
            _invisBase = nil  -- fresh cluster center every enable
            startMode("invisible")
        end,
        stop            = stopAll,
        isRaknetAvailable = function() return findRaknet() ~= nil end,
        isActive        = function() return active end,
        getMode         = function() return mode end,
        setRange        = function(minV, maxV)
            VOID_MIN = math.max(100, tonumber(minV) or VOID_MIN)
            VOID_MAX = math.max(VOID_MIN + 1, tonumber(maxV) or VOID_MAX)
        end,
        -- Invisible-mode jitter radius (studs) around the cluster
        setInvisibleRadius = function(n)
            INVIS_RADIUS = math.clamp(tonumber(n) or 25, 0, 500)
        end,
        getInvisibleRadius = function() return INVIS_RADIUS end,
        -- Now interpreted as "End at % of anim" - the percentage
        setShotSyncMs   = function(n)
            SHOT_SYNC_MS = math.clamp(tonumber(n) or 90, 0, 100)
            getgenv()._F_DESYNC_SHOT_SYNC_MS = SHOT_SYNC_MS
        end,
        -- Delay between MouseButton1 click and when the void spoof
        setShotDelayMs  = function(n)
            local v = math.clamp(tonumber(n) or 40, 0, 100)
            getgenv()._F_DESYNC_SHOT_DELAY_MS = v
        end,
        getShotDelayMs  = function()
            return getgenv()._F_DESYNC_SHOT_DELAY_MS or 0
        end,
        -- Sync window visualizer: shows a "VULNERABLE" banner at the
        setSyncVisualEnabled = function(v)
            syncVisualEnabled = v == true
            if syncVisualEnabled then syncVisualCreate() else syncVisualRemove() end
        end,
        getSyncVisualEnabled = function() return syncVisualEnabled end,
        setSpinSpeed    = function(n)
            SPIN_STEP = math.clamp(tonumber(n) or 47, 1, 360)
        end,
        setVelocityMag  = function(n)
            VEL_MAGNITUDE = math.max(1, tonumber(n) or 16384)
        end,
        setSkyHeight    = function(n)
            SKY_HEIGHT = math.clamp(tonumber(n) or 5000, 50, 100000)
        end,
        -- called by external TP code (_uprightTp etc) so our captured
        notifyTeleport  = function(newCF)
            if typeof(newCF) == "CFrame" then
                realCF = newCF
            else
                local c = lplr.Character
                local hrp = c and c:FindFirstChild("HumanoidRootPart")
                if hrp then realCF = hrp.CFrame end
            end
        end,
    }
end)()

--  SERVER POSITION TRACKER (RakNet)
F.serverPos = (function()
    local function findRaknet()
        local r = rawget(getgenv(), "raknet")
        if r then return r end
        local ok, val = pcall(function() return raknet end)
        if ok and val then return val end
        return nil
    end

    -- Is some hook currently suppressing outbound 0x1B physics packets?
    local function isBlocking()
        local d = getgenv()._F_DESYNC_STATE
        if d and d.active and (d.mode == "raknet" or d.mode == "invisible") then
            return true
        end
        if getgenv()._F_LAGSWITCH_BLOCKING then return true end
        return false
    end

    local function ensureHook()
        if getgenv()._F_SERVERPOS_INSTALLED then return true end
        local r = findRaknet()
        if not r or not r.add_send_hook then return false end
        getgenv()._F_SERVERPOS_INSTALLED = true
        getgenv()._F_SERVERPOS_FN = function(packet)
            -- observer only: never returns false, never blocks
            if packet.PacketId == 0x1B and not isBlocking() then
                local ch  = lplr.Character
                local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
                if hrp then getgenv()._F_SERVERPOS_CF = hrp.CFrame end
            end
        end
        pcall(function() r.add_send_hook(getgenv()._F_SERVERPOS_FN) end)
        return true
    end

    return {
        -- install the observer hook; returns false if no raknet API
        start       = function() return ensureHook() end,
        isAvailable = function() return findRaknet() ~= nil end,
        -- last position the server received; nil until a 0x1B is seen.
        getCFrame   = function() return getgenv()._F_SERVERPOS_CF end,
    }
end)()

--  PULSE LAGSWITCH

--  WHITELIST  (global, all-features-aware)
F.whitelist = (function()
    getgenv()._F_WHITELIST = getgenv()._F_WHITELIST or {}
    local store = getgenv()._F_WHITELIST  -- map: actualName -> true
    -- Rebuild lowercase index from store (in case getgenv survived
    local lower = {}
    for n in pairs(store) do lower[n:lower()] = n end

    local function add(name)
        if type(name) ~= "string" or name == "" then return false end
        local k = name:lower()
        if lower[k] then return false end  -- already in
        store[name] = true
        lower[k] = name
        return true
    end

    local function remove(name)
        if type(name) ~= "string" then return false end
        local k = name:lower()
        local actual = lower[k]
        if not actual then return false end
        store[actual] = nil
        lower[k] = nil
        return true
    end

    local function contains(plr)
        if not plr then return false end
        if type(plr) == "string" then
            return lower[plr:lower()] ~= nil
        end
        if typeof(plr) == "Instance" and plr:IsA("Player") then
            if lower[plr.Name:lower()] then return true end
            local dn = plr.DisplayName
            if dn and dn ~= "" and lower[dn:lower()] then return true end
        end
        return false
    end

    local function list()
        local out = {}
        for n in pairs(store) do table.insert(out, n) end
        table.sort(out, function(a, b) return a:lower() < b:lower() end)
        return out
    end

    local function clear()
        for k in pairs(store) do store[k] = nil end
        for k in pairs(lower) do lower[k] = nil end
    end

    return {
        add      = add,
        remove   = remove,
        contains = contains,
        list     = list,
        clear    = clear,
    }
end)()

-- bulk teardown (call this when your GUI closes)
F.disableAll = function()
    stopFly(); stopCframeSpeed(); stopWalkspeed(); stopJumpPower(); stopForceJump()
    stopClickTp(); stopNoclip(); stopFullbright(); stopFreecam()
    stopZoom(); stopSpin(); stopFlip(); stopTilt(); stopIce()
    if F.desync     then F.desync.stop()     end
    if F.antiFling  then F.antiFling.stop()  end
    if F.forceChat  then (F.forceChat.fullStop or F.forceChat.stop)() end
    if F.stickyEmote then F.stickyEmote.stop() end
    if F.prompts then
        if F.prompts.instantActivation then F.prompts.instantActivation.stop() end
        if F.prompts.unlimitedRange    then F.prompts.unlimitedRange.stop()    end
        if F.prompts.throughWalls      then F.prompts.throughWalls.stop()      end
        if F.prompts.autoFire          then F.prompts.autoFire.stop()          end
    end
    AimbotSettings.Enabled=false; CamLockSettings.Enabled=false; TrigSettings.Enabled=false
    RageSettings.SilentForce=false; RageSettings.AutoShoot=false
    RageSettings.FaceTarget=false; RageSettings.Orbit=false
    RageSettings.CamSnap=false; RageSettings.SpeedPanic=false
    EspSettings.Enabled=false; stopEspRender()
end

return F

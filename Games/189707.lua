-- ============================================================
--  witherhook // Games/189707.lua   (Natural Disaster Survival)
--  Loads the shared shell (main.lua) then adds NDS-specific
--  features: No fall damage + Blue Hammer break tools.
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end   -- backend failed to load

local Window    = ctx.window
local notify    = api.notify
local regToggle = api.regToggle
local regSlider = api.regSlider

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local lplr       = Players.LocalPlayer

-- ============================================================
--  NO FALL DAMAGE
--  FallDamageScript is a SERVER script, so we can't disable it and
--  restoring health client-side loses the race (the server kills us
--  authoritatively). The one lever we DO have: our character is
--  network-owned, so the velocity the server reads is whatever we
--  replicate. Cap our downward speed -> the server only ever sees a
--  gentle landing -> little/no fall damage. Re-hooks on respawn.
-- ============================================================
local noFall   = false
local FALL_CAP = 50   -- max downward studs/sec while the toggle is on
do
    local conn
    local function watch(char)
        char:WaitForChild("HumanoidRootPart")
        if conn then conn:Disconnect() end
        conn = RunService.Heartbeat:Connect(function()
            if not noFall then return end
            local c = lplr.Character
            local hrp = c and c:FindFirstChild("HumanoidRootPart")
            if not hrp then return end
            local v = hrp.AssemblyLinearVelocity
            if v.Y < -FALL_CAP then
                hrp.AssemblyLinearVelocity = Vector3.new(v.X, -FALL_CAP, v.Z)
            end
        end)
    end
    if lplr.Character then watch(lplr.Character) end
    lplr.CharacterAdded:Connect(watch)   -- survive respawns
end

-- ============================================================
--  BLUE HAMMER  (client-side noclip-by-demolition)
--  Fires the tool's BreakPart remote. The break only renders on our
--  own client, and since we own our character's collision, removing a
--  part lets US walk through it without affecting anyone else.
--  Requires the Blue Hammer equipped (ToolEvent lives under it).
-- ============================================================
local mouse = lplr:GetMouse()

local function hammerEvent()
    local c = lplr.Character
    local tool = c and c:FindFirstChild("BlueHammer")
    return tool and tool:FindFirstChild("ToolEvent")
end
local function needHammer()
    notify("Equip the Blue Hammer first", 2, "alert")
end
local function breakPart(part)
    if not (part and part:IsA("BasePart")) then return false end
    local ev = hammerEvent(); if not ev then return false end
    pcall(function() ev:FireServer("BreakPart", part) end)
    return true
end

-- ---- break under cursor (manual) ----
local function breakUnderCursor()
    if not hammerEvent() then needHammer(); return end
    local t = mouse and mouse.Target
    if not t then notify("Aim at a part", 2, "alert"); return end
    breakPart(t)
end

-- ---- auto break (continuous, under cursor) ----
local autoBreak = false
local autoLast  = 0
RunService.Heartbeat:Connect(function()
    if not autoBreak then return end
    if tick() - autoLast < 0.05 then return end   -- light throttle so we don't flood the remote
    if not hammerEvent() then return end
    local t = mouse and mouse.Target
    if t then autoLast = tick(); breakPart(t) end
end)

-- ---- break parts within X studs of me (tunnel) ----
local breakRadius = 20
local function breakAround()
    local c = lplr.Character
    local hrp = c and c:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    if not hammerEvent() then needHammer(); return end
    local hits = workspace:GetPartBoundsInRadius(hrp.Position, breakRadius)
    local n = 0
    for _, p in ipairs(hits) do
        if p ~= hrp and p.Parent and not p:IsDescendantOf(c) then
            if breakPart(p) then n = n + 1 end
        end
    end
    notify("Broke " .. n .. " parts around you", 2, "information")
end

-- ============================================================
--  UI
-- ============================================================
local NDS = Window:NewTab("Natural Disaster")

NDS:NewSection("Survival")
regToggle(NDS, "NDS_NoFallDamage", "No fall damage", false, function(v) noFall = v end)
regSlider(NDS, "NDS_FallCap", "Max fall speed", " st/s", { min = 5, max = 120, default = FALL_CAP },
    function(v) FALL_CAP = v end)

NDS:NewSection("Blue Hammer")
NDS:NewKeybind("Break under cursor", Enum.KeyCode.G, breakUnderCursor)
regToggle(NDS, "NDS_AutoBreak", "Auto break (under cursor)", false, function(v) autoBreak = v end)
NDS:NewButton("Break around me", breakAround)
regSlider(NDS, "NDS_BreakRadius", "Break radius", " studs", { min = 4, max = 100, default = breakRadius },
    function(v) breakRadius = v end)

-- shared tabs (Movement/World/Misc/Settings/Config)
api.buildShared()

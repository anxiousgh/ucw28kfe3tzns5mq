-- ============================================================
--  witherhook // Games/189707.lua   (Natural Disaster Survival)
--  Loads the shared shell (main.lua) then adds NDS-specific
--  features. Currently: No fall damage (survives respawns).
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end   -- backend failed to load

local Window    = ctx.window
local notify    = api.notify
local regToggle = api.regToggle

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local lplr       = Players.LocalPlayer

-- ============================================================
--  NO FALL DAMAGE
--  Polling on Heartbeat + airborne-state detection proved unreliable
--  (a one-frame fall kill slips through, and disaster launches don't
--  always read as Freefall). New approach:
--    * HealthChanged: the instant our health drops, snap it back to
--      full -- catches even an instant-kill before the next frame.
--    * Heartbeat backstop: top health off + keep the Dead state
--      disabled so we can't die even if a drop is missed.
--  Re-hooks on respawn so it survives death.
-- ============================================================
local noFall = false
do
    local hum, hbConn, hcConn

    local function topUp()
        if noFall and hum and hum.Parent and hum.Health < hum.MaxHealth then
            hum.Health = hum.MaxHealth
        end
    end

    local function watch(char)
        hum = char:WaitForChild("Humanoid")
        if hbConn then hbConn:Disconnect() end
        if hcConn then hcConn:Disconnect() end

        -- instant restore the moment any damage lands
        hcConn = hum.HealthChanged:Connect(function() topUp() end)

        hbConn = RunService.Heartbeat:Connect(function()
            if not hum or hum.Parent == nil then return end
            -- death immunity: off while ON, restored while OFF; re-applied every
            -- frame so it sticks even if the game flips it back on respawn.
            pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, not noFall) end)
            topUp()
        end)
    end

    if lplr.Character then watch(lplr.Character) end
    lplr.CharacterAdded:Connect(watch)   -- survive respawns
end

local NDS = Window:NewTab("Natural Disaster")
NDS:NewSection("Survival")
regToggle(NDS, "NDS_NoFallDamage", "No fall damage", false, function(v) noFall = v end)

-- shared tabs (Movement/World/Misc/Settings/Config)
api.buildShared()

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
--  Core mechanic (per the reference): disable the Humanoid's Dead
--  state so a fall (or anything) can't kill us. Re-applied every
--  frame because the game re-enables it on respawn, and we also
--  restore any health a fall/landing takes (short grace window for
--  damage the game applies a frame or two after touchdown) so it's
--  truly "no fall damage", not just "no death". Re-hooks on respawn.
-- ============================================================
local noFall = false
do
    local hum, conn
    local groundedHealth = nil
    local wasAirborne    = false
    local landGraceUntil = 0
    local GRACE = 0.5   -- seconds after landing we keep restoring

    local function watch(char)
        hum = char:WaitForChild("Humanoid")
        groundedHealth = hum.Health
        wasAirborne    = false
        landGraceUntil = 0
        if conn then conn:Disconnect() end
        conn = RunService.Heartbeat:Connect(function()
            if not hum or hum.Parent == nil then return end
            -- death immunity: disabled while ON, restored while OFF. Re-applied
            -- every frame so it sticks even if the game flips it back.
            pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, not noFall) end)
            -- while disabled, keep the baseline tracking current health
            if not noFall then
                if hum.Health > 0 then groundedHealth = hum.Health end
                wasAirborne = false
                return
            end
            local st = hum:GetState()
            local airborne = st == Enum.HumanoidStateType.Freefall
                          or st == Enum.HumanoidStateType.Jumping
            if airborne then
                wasAirborne = true   -- freeze the baseline at the pre-fall health
            else
                if wasAirborne then
                    landGraceUntil = tick() + GRACE
                    wasAirborne = false
                end
                if tick() < landGraceUntil then
                    -- just landed: undo the fall/landing damage
                    if groundedHealth and groundedHealth > 0 and hum.Health < groundedHealth then
                        hum.Health = groundedHealth
                    end
                else
                    if hum.Health > 0 then groundedHealth = hum.Health end   -- accept normal changes
                end
            end
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

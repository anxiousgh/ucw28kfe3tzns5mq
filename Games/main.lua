-- ============================================================
--  witherhook // Games/main.lua
--  Shared feature set loaded for EVERY game: Movement + Misc.
--  Wired to the decay backend (functions.lua -> F).
-- ============================================================
local ctx     = ({ ... })[1]
local library = ctx.library
local Window  = ctx.window
local Notif   = ctx.notif

local function notify(text, dur, kind)
    if Notif then pcall(function() Notif:Notify(text, dur or 4, kind or "information") end) end
end

-- ---------- backend ----------
local hook
do
    local ok, res = pcall(function() return ctx.load("functions.lua")() end)
    if not ok or type(res) ~= "table" then
        notify("witherhook: backend failed to load (see console)", 6, "error")
        warn("[witherhook/main] functions.lua failed: " .. tostring(res))
        return
    end
    hook = res
end

-- ============================================================
--  MOVEMENT
-- ============================================================
local Movement = Window:NewTab("Movement")

Movement:NewSection("Movement")

Movement:NewToggle("Fly", false, function(v)
    if v then hook.fly.start() else hook.fly.stop() end
end)
Movement:NewSlider("Fly speed", "", false, "/",
    { min = 5, max = 3000, default = hook.fly.getSpeed() or 60 },
    function(v) hook.fly.setSpeed(v) end)

Movement:NewToggle("Walkspeed", false, function(v)
    if v then hook.walkspeed.start() else hook.walkspeed.stop() end
end)
Movement:NewSlider("Walkspeed value", "", false, "/",
    { min = 8, max = 1000, default = hook.walkspeed.getValue() or 50 },
    function(v) hook.walkspeed.setValue(v) end)

Movement:NewToggle("Jump power", false, function(v)
    if v then hook.jumpPower.start() else hook.jumpPower.stop() end
end)
Movement:NewSlider("Jump power value", "", false, "/",
    { min = 0, max = 2000, default = hook.jumpPower.getValue() or 50 },
    function(v) hook.jumpPower.setValue(v) end)

Movement:NewToggle("CFrame speed", false, function(v)
    if v then hook.cframeSpeed.start(hook.cframeSpeed.getMultiplier()) else hook.cframeSpeed.stop() end
end)
Movement:NewSlider("CFrame speed multiplier", "x", false, "/",
    { min = 1, max = 100, default = hook.cframeSpeed.getMultiplier() or 2 },
    function(v) hook.cframeSpeed.setMultiplier(v) end)

-- forceJump, renamed per request
Movement:NewToggle("Allow jump", false, function(v)
    if v then hook.forceJump.start() else hook.forceJump.stop() end
end)

-- ---------- CSGO HVH movement ----------
Movement:NewSection("CSGO HVH movement")
Movement:NewToggle("HVH enabled", false, function(v)
    if v then hook.hvhMovement.start() else hook.hvhMovement.stop() end
end)
Movement:NewSlider("Jiggle amount min", " deg", false, "/",
    { min = 0, max = 180, default = 15 }, function(v) hook.hvhMovement.setJiggleAmountMin(v) end)
Movement:NewSlider("Jiggle amount max", " deg", false, "/",
    { min = 0, max = 180, default = 35 }, function(v) hook.hvhMovement.setJiggleAmountMax(v) end)
-- Xsx slider is integer-only, so HVH frequency is whole Hz here
Movement:NewSlider("Jiggle freq min", " Hz", false, "/",
    { min = 1, max = 30, default = 1 }, function(v) hook.hvhMovement.setJiggleFreqMin(v) end)
Movement:NewSlider("Jiggle freq max", " Hz", false, "/",
    { min = 1, max = 30, default = 3 }, function(v) hook.hvhMovement.setJiggleFreqMax(v) end)

-- ---------- Extras ----------
Movement:NewSection("Extras")
Movement:NewToggle("Spin", false, function(v)
    if v then hook.spin.start() else hook.spin.stop() end
end)
Movement:NewSlider("Spin speed", "", false, "/",
    { min = 1, max = 1000, default = 50 }, function(v) hook.spin.setSpeed(v) end)

-- Upside down / Tilt are mutually exclusive (don't compound orientation spoofs)
local flipT, tiltT
flipT = Movement:NewToggle("Upside down", false, function(v)
    if v then
        if tiltT then tiltT:Set(false) end
        hook.flip.start()
    else
        hook.flip.stop()
    end
end)
tiltT = Movement:NewToggle("Tilt sideways", false, function(v)
    if v then
        if flipT then flipT:Set(false) end
        hook.tilt.start()
    else
        hook.tilt.stop()
    end
end)

Movement:NewToggle("Ice slide", false, function(v)
    if v then hook.ice.start() else hook.ice.stop() end
end)
-- friction 0.50-0.99 shown as 50-99 (slider is integer-only)
Movement:NewSlider("Slide friction", "%", false, "/",
    { min = 50, max = 99, default = 98 }, function(v) hook.ice.setSlide(v / 100) end)

-- ---------- Desync ----------
Movement:NewSection("Desync")

local desyncMode = "Void"
local desyncOn   = false
local desyncMin, desyncMax = 5000, 20000
local desyncEnableT

local MODE_START = {
    Void     = function() hook.desync.startVoid()     return true end,
    Sky      = function() hook.desync.startSky()      return true end,
    Spin     = function() hook.desync.startSpin()     return true end,
    Velocity = function() hook.desync.startVelocity() return true end,
    Raknet   = function()
        local ok = hook.desync.startRaknet()
        if not ok then notify("Raknet desync unavailable: executor doesn't expose `raknet`", 5, "error") end
        return ok
    end,
}

Movement:NewDropdown("Desync mode", "Void",
    { "Void", "Sky", "Spin", "Velocity", "Raknet" }, false,
    function(v)
        desyncMode = v
        if desyncOn then
            hook.desync.stop()
            local starter = MODE_START[v]
            if not starter or not starter() then
                if desyncEnableT then desyncEnableT:Set(false) end
            end
        end
    end)

desyncEnableT = Movement:NewToggle("Enable desync", false, function(v)
    desyncOn = v
    if v then
        local starter = MODE_START[desyncMode]
        if not starter or not starter() then
            if desyncEnableT then desyncEnableT:Set(false) end
        end
    else
        hook.desync.stop()
    end
end)

Movement:NewSlider("Void min distance", "", false, "/",
    { min = 500, max = 100000, default = 5000 },
    function(v) desyncMin = v; hook.desync.setRange(desyncMin, desyncMax) end)
Movement:NewSlider("Void max distance", "", false, "/",
    { min = 500, max = 100000, default = 20000 },
    function(v) desyncMax = v; hook.desync.setRange(desyncMin, desyncMax) end)
Movement:NewSlider("Spin speed (deg/frame)", "", false, "/",
    { min = 1, max = 360, default = 47 }, function(v) hook.desync.setSpinSpeed(v) end)
Movement:NewSlider("Velocity magnitude", "", false, "/",
    { min = 100, max = 100000, default = 16384 }, function(v) hook.desync.setVelocityMag(v) end)
Movement:NewSlider("Sky height", "", false, "/",
    { min = 50, max = 100000, default = 5000 }, function(v) hook.desync.setSkyHeight(v) end)

-- ============================================================
--  MISC
-- ============================================================
local Misc = Window:NewTab("Misc")

Misc:NewSection("Anti-fling")
Misc:NewToggle("Anti-fling", false, function(v)
    if v then hook.antiFling.start() else hook.antiFling.stop() end
end)
Misc:NewSlider("Velocity cap", " stud/sec", false, "/",
    { min = 100, max = 50000, default = 5000 }, function(v) hook.antiFling.setCap(v) end)

Misc:NewSection("Enable chat")
Misc:NewToggle("Re-enable chat", false, function(v)
    if v then hook.forceChat.start() else hook.forceChat.stop() end
end)

Misc:NewSection("Proximity prompts")
Misc:NewToggle("Instant activation", false, function(v)
    if v then hook.prompts.instantActivation.start() else hook.prompts.instantActivation.stop() end
end)
Misc:NewToggle("Unlimited range", false, function(v)
    if v then hook.prompts.unlimitedRange.start() else hook.prompts.unlimitedRange.stop() end
end)
Misc:NewToggle("Through walls", false, function(v)
    if v then hook.prompts.throughWalls.start() else hook.prompts.throughWalls.stop() end
end)
Misc:NewToggle("Auto-fire", false, function(v)
    if v then hook.prompts.autoFire.start() else hook.prompts.autoFire.stop() end
end)

notify("witherhook ready", 3, "success")

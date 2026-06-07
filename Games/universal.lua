-- ============================================================
--  witherhook // Games/universal.lua
--  Fallback for games NOT in the games list. Loads the shared
--  shell (main.lua) then adds the universal combat tabs.
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end   -- backend failed to load

local Window = ctx.window
local hook   = api.hook
local notify = api.notify
local regToggle, regSlider, regDropdown = api.regToggle, api.regSlider, api.regDropdown

local cam  = hook.camLock
local trig = hook.triggerbot
local cs   = cam.settings
local ts   = trig.settings

-- ============================================================
--  AIMLOCK  (camera lock)
-- ============================================================
local Aim = Window:NewTab("Aimlock")

-- ---------- Target lock (shared by camlock + triggerbot) ----------
-- One key locks onto the single target under your crosshair; press again to
-- unlock. While locked, BOTH camlock and triggerbot focus only on that target.
Aim:NewSection("Target lock")
Aim:NewKeybind("Lock / unlock target", Enum.KeyCode.E, function()
    local wasLocked = cam.getLocked() ~= nil
    local locked, plr = cam.lockToggle()
    if locked and plr then
        notify("Locked onto " .. plr.Name, 2, "success")
    elseif wasLocked then
        notify("Target unlocked", 2, "information")
    else
        notify("No target under your crosshair", 2, "alert")
    end
end)
Aim:NewLabel("While a target is locked, camlock + triggerbot use only that target.", "left")

Aim:NewSection("Camera lock")

regToggle(Aim, "CamEnabled", "Enabled", cs.Enabled or false, function(v) cam.setEnabled(v) end)
    :AddKeybind(Enum.KeyCode.C, "Camera Lock Toggle")
regToggle(Aim, "CamTeamCheck",   "Team check",        cs.TeamCheck or false,   function(v) cam.setTeamCheck(v) end)
regToggle(Aim, "CamSticky",      "Sticky target",     cs.Sticky or false,      function(v) cam.setSticky(v) end)
regToggle(Aim, "CamClosestPart", "Closest bodypart",  cs.ClosestPart or false, function(v) cam.setClosestPart(v) end)
regToggle(Aim, "CamToolCheck",   "Tool check",        cs.ToolCheck or false,   function(v) cam.setToolCheck(v) end)
regToggle(Aim, "CamOnlyVisible", "Only while visible", cs.OnlyVisible or false, function(v) cam.setOnlyVisible(v) end)
regToggle(Aim, "CamOnlyFirstPerson", "Only in 1st Person", cs.OnlyFirstPerson or false, function(v) cam.setOnlyFirstPerson(v) end)

regDropdown(Aim, "CamHitPart", "Hit part", cs.TargetPart or "Head",
    { "Head", "HumanoidRootPart", "UpperTorso", "Random" }, false, function(v) cam.setHitPart(v) end)
-- Mouse = move the mouse toward the target (works in 3rd person, needs an
-- executor with mousemoverel); Camera = steer the camera toward the target
regDropdown(Aim, "CamMode", "Mode", cs.Mode or "Mouse",
    { "Mouse", "Camera" }, false, function(v) cam.setMode(v) end)

regSlider(Aim, "CamFov", "FOV radius", "", { min = 1, max = 2000, default = cs.FOVRadius or 200 },
    function(v) cam.setFov(v) end)
-- smoothing 0.00-0.99 shown as 0-99 (integer slider)
regSlider(Aim, "CamSmoothing", "Smoothing", "%", { min = 0, max = 99, default = math.floor((cs.Smoothing or 0.25) * 100) },
    function(v) cam.setSmoothing(v / 100) end)

regToggle(Aim, "CamShowFov",    "Show FOV",   cs.ShowFOV or false,     function(v) cam.setShowFov(v) end)
regToggle(Aim, "CamPrediction", "Prediction", cs.Prediction or false,  function(v) cam.setPrediction(v) end)
-- prediction amount 0.00-2.00 shown as 0-200
regSlider(Aim, "CamPredictionAmt", "Prediction amount", "", { min = 0, max = 200, default = math.floor((cs.PredictionAmount or 0.165) * 100) },
    function(v) cam.setPredictionAmount(v / 100) end)

-- ============================================================
--  TRIGGERBOT
-- ============================================================
local Trig = Window:NewTab("Triggerbot")
Trig:NewSection("Triggerbot")

regToggle(Trig, "TrigEnabled", "Enabled", ts.Enabled or false, function(v) trig.setEnabled(v) end)
    :AddKeybind(Enum.KeyCode.Y, "Triggerbot Toggle")
regToggle(Trig, "TrigTeamCheck", "Team check", ts.TeamCheck or false, function(v) trig.setTeamCheck(v) end)
regToggle(Trig, "TrigToolCheck", "Tool check", ts.ToolCheck or false, function(v) trig.setToolCheck(v) end)

regDropdown(Trig, "TrigHitPart", "Hit part", ts.TargetPart or "All", {
    "All",
    "HumanoidRootPart", "Head",
    "UpperTorso", "LowerTorso",
    "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot",
    "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg",
    "Random",
}, false, function(v) trig.setHitPart(v) end)

regSlider(Trig, "TrigFov", "FOV radius", "", { min = 1, max = 500, default = ts.FOVRadius or 20 },
    function(v) trig.setFov(v) end)
regSlider(Trig, "TrigDelay", "Click delay", " ms", { min = 0, max = 2000, default = ts.ClickDelay or 0 },
    function(v) trig.setDelay(v) end)

regToggle(Trig, "TrigShowFov",    "Show FOV",    ts.ShowFOV or false,    function(v) trig.setShowFov(v) end)
regToggle(Trig, "TrigShowTarget", "Show target", ts.ShowTarget or false, function(v) trig.setShowTarget(v) end)

-- ============================================================
--  CHECKS  (visible check)
-- ============================================================
local Checks = Window:NewTab("Checks")
Checks:NewSection("Visible check")

-- master: gates visibility on every aim feature at once
regToggle(Checks, "VisibleCheckMaster", "Enable visible check", false, function(v)
    cam.setVisibleCheck(v)
    trig.setVisibleCheck(v)
    if hook.aimbot and hook.aimbot.setVisibleCheck then hook.aimbot.setVisibleCheck(v) end
end)
regToggle(Checks, "StrictVisCheck", "Strict (block see-through walls)", false, function(v)
    hook.utils.setStrictVisibleCheck(v)
end)
regDropdown(Checks, "VisOrigin", "Origin", "Camera", { "Camera", "Head", "Tool" }, false, function(v)
    hook.utils.setVisibleOrigin(v)
end)

-- shared tabs (Movement/Misc/Settings/Config) go BELOW the combat tabs
api.buildShared()

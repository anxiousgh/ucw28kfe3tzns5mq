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

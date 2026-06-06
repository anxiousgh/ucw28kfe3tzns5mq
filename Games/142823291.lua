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

local UIS = game:GetService("UserInputService")

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
Main:NewButton("Pickup gun now (H)", tryPickup)
regToggle(Main, "MM2_AutoPickup", "Auto pickup gun", false, function(v)
    if v then mm2.autoPickupGun.start() else mm2.autoPickupGun.stop() end
end)

-- ---------- Invisible (desync invisible mode) ----------
Main:NewSection("Invisible")
regToggle(Main, "MM2_Invisible", "Invisible", false, function(v)
    if v then hook.desync.startInvisible() else hook.desync.stop() end
end):AddKeybind(Enum.KeyCode.N, "MM2 Invisible")
regSlider(Main, "MM2_InvisibleRadius", "Invisible jitter radius", "", { min = 0, max = 500, default = 25 }, function(v)
    hook.desync.setInvisibleRadius(v)
end)

-- ---------- Murderer ----------
Main:NewSection("Murderer")
regToggle(Main, "MM2_TriggerMurderer", "Hover-fire on Murderer", false, function(v)
    if v then mm2.triggerMurderer.start() else mm2.triggerMurderer.stop() end
end)

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
Main:NewButton("Shoot murderer (K)", tryShoot)

-- one-shot action keybinds: H = pickup gun, K = shoot murderer
UIS.InputBegan:Connect(function(input, gp)
    if gp or (library and library.Unloaded) then return end
    if UIS:GetFocusedTextBox() then return end
    if input.KeyCode == Enum.KeyCode.H then tryPickup()
    elseif input.KeyCode == Enum.KeyCode.K then tryShoot() end
end)

-- shared tabs (Movement/Desync/Visuals/World/Misc/Settings/Config) below
api.buildShared()

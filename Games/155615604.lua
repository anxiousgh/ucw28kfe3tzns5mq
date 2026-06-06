-- ============================================================
--  witherhook // Games/155615604.lua   (Prison Life)
--  Loads the shared shell (main.lua) then adds the Prison Life
--  tabs: Killaura, Gun Mods, Give Guns. Wired to hook.games.prisonLife.
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end

local Window = ctx.window
local hook   = api.hook
local notify = api.notify
local regToggle, regSlider, regDropdown = api.regToggle, api.regSlider, api.regDropdown

local pl = hook.games and hook.games.prisonLife
if not pl then
    notify("Prison Life module unavailable", 5, "error")
    return
end

-- ============================================================
--  KILLAURA
-- ============================================================
local Aura = Window:NewTab("Killaura")
Aura:NewSection("Kill aura")
regToggle(Aura, "PL_KillAura", "Kill aura", false, function(v)
    if v then pl.killAura.start() else pl.killAura.stop() end
end):AddKeybind(Enum.KeyCode.F, "Killaura Toggle")
Aura:NewLabel("Auto-shoots the nearest visible enemy. Range/fire-rate are read from the equipped gun.", "left")

-- ============================================================
--  GUN MODS
-- ============================================================
local Mods = Window:NewTab("Gun Mods")

Mods:NewSection("Firing")
regToggle(Mods, "PL_NoSpread", "No spread", false, function(v)
    if v then pl.noSpread.start() else pl.noSpread.stop() end
end)
regToggle(Mods, "PL_AutoFire", "Auto fire (hold to shoot)", false, function(v)
    if v then pl.autoFire.start() else pl.autoFire.stop() end
end)
regToggle(Mods, "PL_FastFire", "Fast fire", false, function(v)
    if v then pl.fastFire.start() else pl.fastFire.stop() end
end)
-- fire interval 0.01-1.00s shown as 1-100 (slider is integer-only; lower = faster)
regSlider(Mods, "PL_FastFireRate", "Fast fire interval", "", { min = 1, max = 100, default = 5 }, function(v)
    pl.fastFire.setRate(v / 100)
end)
regToggle(Mods, "PL_AutoReload", "Auto reload", false, function(v)
    if v then pl.autoReload.start() else pl.autoReload.stop() end
end)

Mods:NewSection("Hit feedback")
regToggle(Mods, "PL_HitMarker", "Hit marker", false, function(v) pl.hitMarker.setMarker(v) end)
regToggle(Mods, "PL_HitNumber", "Hit number", false, function(v) pl.hitMarker.setNumber(v) end)
regToggle(Mods, "PL_HitSound",  "Hit sound",  false, function(v) pl.hitSound.setEnabled(v) end)

Mods:NewSection("Tracer")
regToggle(Mods, "PL_Tracer",      "Bullet tracer", false, function(v) pl.tracer.setEnabled(v) end)
regToggle(Mods, "PL_TracerTrail", "Tracer trail",  false, function(v) pl.tracer.setTrail(v) end)
-- lifetime 0.05-3.00s shown as 5-300; thickness 0.01-2.00 shown as 1-200
regSlider(Mods, "PL_TracerLifetime", "Tracer lifetime", "", { min = 5, max = 300, default = 20 }, function(v)
    pl.tracer.setLifetime(v / 100)
end)
regSlider(Mods, "PL_TracerThick", "Tracer thickness", "", { min = 1, max = 200, default = 12 }, function(v)
    pl.tracer.setThickness(v / 100)
end)

-- ============================================================
--  GIVE GUNS
-- ============================================================
local Give = Window:NewTab("Give Guns")
Give:NewSection("Gun givers")

Give:NewButton("Grab all guns", function()
    pl.guns.grabAll()
    notify("Grabbed all guns", 2, "success")
end)

local gunSel = nil
local gunDrop = Give:NewDropdown("Gun", "—", pl.guns.list(), false, function(v) gunSel = v end)

Give:NewButton("Grab selected", function()
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

-- shared tabs (Movement/Misc/Settings/Config) go BELOW the Prison Life tabs
api.buildShared()

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
Aim:NewLabel("Auto-shoots the nearest visible enemy. Range/fire-rate are read from the equipped gun.", "left")

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

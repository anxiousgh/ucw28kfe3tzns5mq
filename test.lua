-- ============================================================
--  witherhook // test.lua
--  Exercises every component + method of the UI library and
--  reports pass/fail. Run standalone:
--    loadstring(game:HttpGet("https://raw.githubusercontent.com/anxiousgh/ucw28kfe3tzns5mq/main/test.lua"))()
-- ============================================================

-- SHA-pin so the executor/CDN cache can't hand us a stale library.lua.
local OWNER, REPO, BRANCH = "anxiousgh", "ucw28kfe3tzns5mq", "main"
local BASE
do
    local okSha, body = pcall(game.HttpGet, game,
        ("https://api.github.com/repos/%s/%s/commits/%s"):format(OWNER, REPO, BRANCH))
    local sha = okSha and type(body) == "string" and body:match('"sha"%s*:%s*"(%x+)"')
    BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, sha or BRANCH)
    print("[witherhook test] base: " .. BASE)
end
local library = loadstring(game:HttpGet(BASE .. "library.lua"))()

-- ---------- pass/fail harness ----------
local PASS, FAIL = 0, 0
local FAILS = {}
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        PASS = PASS + 1
        print("[PASS] " .. name)
    else
        FAIL = FAIL + 1
        table.insert(FAILS, name .. " -> " .. tostring(err))
        warn("[FAIL] " .. name .. " -> " .. tostring(err))
    end
end

-- ============================================================
--  MAIN / WATERMARK / NOTIFICATIONS / INTRO
-- ============================================================
check("library.title set", function() library.title = "witherhook test" end)
check("library.rank set",  function() library.rank = "tester" end)
check("library.version read", function() assert(library.version ~= nil) end)
check("library.fps read",     function() local _ = library.fps end)

local Wm, FpsWm
check("library:Watermark", function()
    Wm = library:Watermark("witherhook test | v" .. tostring(library.version) .. " | " .. library:GetUsername())
end)
check("Wm:AddWatermark", function() FpsWm = Wm:AddWatermark("fps: " .. tostring(library.fps)) end)
check("Wm:Text",         function() Wm:Text("witherhook test (watermark ok)") end)

-- live fps in the sub-watermark
if FpsWm then
    coroutine.wrap(function()
        while task.wait(0.75) do
            pcall(function() FpsWm:Text("fps: " .. tostring(library.fps)) end)
        end
    end)()
end

local Notif
check("library:InitNotifications", function() Notif = library:InitNotifications() end)
check("Notify information", function() Notif:Notify("information notification", 4, "information") end)
check("Notify notification",function() Notif:Notify("plain notification", 4, "notification") end)
check("Notify alert",       function() Notif:Notify("alert notification", 4, "alert") end)
check("Notify error",       function() Notif:Notify("error notification", 4, "error") end)
check("Notify success",     function() Notif:Notify("success notification", 4, "success") end)
check("Notify w/ callback",  function()
    local n = Notif:Notify("callback notification", 4, function() print("[test] notif callback fired") end)
    if n and n.Text then n:Text("callback notification (updated)") end
end)

check("library:Introduction", function() library:Introduction() end)
task.wait(1)

local Window
check("library:Init", function() Window = library:Init() end)

-- ============================================================
--  TAB 1 — every component, with live callbacks
-- ============================================================
local Tab1 = Window:NewTab("Components")
check("Tab:NewTab", function() assert(Tab1) end)

check("NewSection", function() Tab1:NewSection("Components") end)

local Label
check("NewLabel", function()
    Label = Tab1:NewLabel("label (left)", "left")
end)

local Button
check("NewButton", function()
    Button = Tab1:NewButton("Button — click me", function()
        Notif:Notify("Button clicked", 3, "success")
    end)
end)
check("Button:AddButton (sub)", function()
    Button:AddButton("Sub A", function() Notif:Notify("Sub A clicked", 2, "information") end)
end)

local Toggle
check("NewToggle", function()
    Toggle = Tab1:NewToggle("Toggle", false, function(v)
        Notif:Notify("Toggle = " .. tostring(v), 2, v and "success" or "alert")
    end)
end)
check("Toggle:AddKeybind (was the crash)", function()
    Toggle:AddKeybind(Enum.KeyCode.K)
end)

local Keybind
check("NewKeybind", function()
    Keybind = Tab1:NewKeybind("Keybind", Enum.KeyCode.RightAlt, function(key)
        Notif:Notify("Keybind fired: " .. tostring(key), 2, "information")
    end)
end)

local TboxS, TboxM, TboxL
check("NewTextbox small", function()
    TboxS = Tab1:NewTextbox("Textbox [small]", "", "type here", "all", "small", true, false, function(v)
        Notif:Notify("small box: " .. tostring(v), 2, "information")
    end)
end)
check("NewTextbox medium", function()
    TboxM = Tab1:NewTextbox("Textbox [medium]", "", "type here", "all", "medium", true, false, function() end)
end)
check("NewTextbox large", function()
    TboxL = Tab1:NewTextbox("Textbox [large]", "", "type here", "all", "large", true, false, function() end)
end)

local Selector
check("NewSelector", function()
    Selector = Tab1:NewSelector("Selector (always-open)", "one", { "one", "two", "three" }, function(v)
        Notif:Notify("selector: " .. tostring(v), 2, "information")
    end)
end)

local DropS, DropM
check("NewDropdown single", function()
    DropS = Tab1:NewDropdown("Dropdown (single)", "alpha", { "alpha", "beta", "gamma" }, false, function(v)
        Notif:Notify("dropdown single: " .. tostring(v), 2, "information")
    end)
end)
check("NewDropdown multi", function()
    DropM = Tab1:NewDropdown("Dropdown (multi)", nil, { "red", "green", "blue", "white" }, true, function(arr)
        Notif:Notify("dropdown multi: " .. table.concat(arr, ", "), 2, "information")
    end)
end)

local Slider
check("NewSlider", function()
    Slider = Tab1:NewSlider("Slider", "", true, "/", { min = 1, max = 100, default = 20 }, function(v)
        -- silent: too noisy for notifications while dragging
        print("[test] slider:", v)
    end)
end)

-- ============================================================
--  TAB 2 — instance-method sweep (run on a button)
-- ============================================================
local Tab2 = Window:NewTab("Methods")
Tab2:NewSection("Per-component methods")
Tab2:NewLabel("Press the button to run every instance method.", "left")

local function methodSweep()
    -- Label
    check("Label:Text",  function() Label:Text("label (text changed)") end)
    check("Label:Align", function() Label:Align("right") end)
    check("Label:Hide",  function() Label:Hide() end)
    check("Label:Show",  function() Label:Show() end)
    -- Button
    check("Button:Text", function() Button:Text("Button (renamed)") end)
    check("Button:Fire", function() Button:Fire() end)
    -- Toggle
    check("Toggle:Set(true)",  function() Toggle:Set(true) end)
    check("Toggle:Change",     function() Toggle:Change() end)
    check("Toggle:Text",       function() Toggle:Text("Toggle (renamed)") end)
    check("Toggle:SetFunction",function() Toggle:SetFunction(function(v) print("[test] toggle fn", v) end) end)
    -- Keybind
    check("Keybind:Text",       function() Keybind:Text("Keybind (renamed)") end)
    check("Keybind:SetKey",     function() Keybind:SetKey(Enum.KeyCode.L) end)
    check("Keybind:SetFunction",function() Keybind:SetFunction(function(k) print("[test] keybind fn", k) end) end)
    check("Keybind:Fire",       function() Keybind:Fire() end)
    -- Textbox
    check("Textbox:Place",      function() TboxS:Place("new placeholder") end)
    check("Textbox:Input",      function() TboxS:Input("typed value") end)
    check("Textbox:SetFunction",function() TboxS:SetFunction(function(v) print("[test] textbox fn", v) end) end)
    check("Textbox:Fire",       function() TboxS:Fire() end)
    check("Textbox:Text",       function() TboxS:Text("Textbox (renamed)") end)
    -- Selector
    check("Selector:AddOption",   function() Selector:AddOption("four") end)
    check("Selector:Text",        function() Selector:Text("Selector (renamed)") end)
    check("Selector:SetFunction", function() Selector:SetFunction(function(v) print("[test] selector fn", v) end) end)
    check("Selector:RemoveOption",function() Selector:RemoveOption("four") end)
    -- Dropdown (single)
    check("Dropdown:AddOption",  function() DropS:AddOption("delta") end)
    check("Dropdown:Set",        function() DropS:Set("beta") end)
    check("Dropdown:GetValue",   function() assert(DropS:GetValue() == "beta") end)
    check("Dropdown:Open",       function() DropS:Open() end)
    check("Dropdown:Close",      function() DropS:Close() end)
    check("Dropdown:Text",       function() DropS:Text("Dropdown single (renamed)") end)
    -- Dropdown (multi)
    check("Dropdown multi:Set(array)", function() DropM:Set({ "red", "blue" }) end)
    check("Dropdown multi:GetValue",   function() assert(#DropM:GetValue() == 2) end)
    -- Slider
    check("Slider:Value",       function() Slider:Value(75) end)
    check("Slider:Text",        function() Slider:Text("Slider (renamed)") end)
    check("Slider:SetFunction", function() Slider:SetFunction(function(v) print("[test] slider fn", v) end) end)
    -- Watermark
    check("Wm:Hide", function() Wm:Hide() end)
    check("Wm:Show", function() Wm:Show() end)
end

Tab2:NewButton("Run per-component method sweep", function()
    methodSweep()
    Notif:Notify(("Methods: %d passed, %d failed"):format(PASS, FAIL), 5, FAIL == 0 and "success" or "error")
end)

-- ============================================================
--  TAB 3 — library/misc methods
-- ============================================================
local Tab3 = Window:NewTab("Library API")
Tab3:NewSection("Info getters (results -> notifications)")

local function show(name, value)
    Notif:Notify(name .. ": " .. tostring(value), 4, "information")
    print("[test] " .. name .. " = " .. tostring(value))
end

Tab3:NewButton("GetUsername / UserId", function()
    check("GetUsername", function() show("Username", library:GetUsername()) end)
    check("GetUserId",   function() show("UserId", library:GetUserId()) end)
end)
Tab3:NewButton("GetPlaceId / JobId", function()
    check("GetPlaceId", function() show("PlaceId", library:GetPlaceId()) end)
    check("GetJobId",   function() show("JobId", library:GetJobId()) end)
end)
Tab3:NewButton("Date / Time getters", function()
    check("GetDay",   function() show("Day",   library:GetDay("word")) end)
    check("GetMonth", function() show("Month", library:GetMonth("word")) end)
    check("GetYear",  function() show("Year",  library:GetYear("full")) end)
    check("GetWeek",  function() show("Week",  library:GetWeek("day")) end)
    check("GetTime",  function() show("Time",  library:GetTime("full")) end)
end)
Tab3:NewButton("CheckIfLoaded / Copy", function()
    check("CheckIfLoaded", function() show("Loaded", library:CheckIfLoaded()) end)
    check("Copy",          function() library:Copy("witherhook test clipboard"); Notif:Notify("Copied test string", 2, "success") end)
end)

-- ============================================================
--  TAB 4 — visibility + teardown
-- ============================================================
local Tab4 = Window:NewTab("Window")
Tab4:NewSection("Tab + window controls")
Tab4:NewButton("Hide this tab 2s then show", function()
    check("Tab:Hide", function() Tab4:Hide() end)
    task.wait(2)
    check("Tab:Show", function() Tab4:Show() end)
end)
Tab4:NewButton("Open Components tab", function()
    check("Tab:Open", function() Tab1:Open() end)
end)
Tab4:NewButton("Rename this tab", function()
    check("Tab:Text", function() Tab4:Text("Window*") end)
end)
Tab4:NewSection("Teardown")
Tab4:NewButton("UNLOAD (library:Remove)", function()
    check("library:Remove", function() library:Remove() end)
end)

-- ============================================================
--  AUTO self-test summary (component construction only)
-- ============================================================
task.wait(0.5)
Notif:Notify(("Build self-test: %d passed, %d failed"):format(PASS, FAIL), 6, FAIL == 0 and "success" or "error")
if FAIL > 0 then
    warn("================ witherhook test: FAILURES ================")
    for _, f in ipairs(FAILS) do warn("  " .. f) end
end
print(("[witherhook test] build phase: %d passed / %d failed"):format(PASS, FAIL))
print("[witherhook test] Use the 'Methods' tab button to sweep instance methods.")

-- ============================================================
--  witherhook // loader.lua
--  Boots the (self-hosted) Xsx UI library, creates the window,
--  detects the current game and dispatches to a Games/ module.
--
--  Public repo: fetched with plain game:HttpGet, no key needed.
--  Load with:
--    loadstring(game:HttpGet("https://raw.githubusercontent.com/anxiousgh/ucw28kfe3tzns5mq/main/loader.lua"))()
-- ============================================================

-- ---------- config ----------
local OWNER  = "anxiousgh"
local REPO   = "ucw28kfe3tzns5mq"
local BRANCH = "main"

local BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)

-- ---------- raw fetch ----------
local function fetch(path)
    return game:HttpGet(BASE .. path)
end

local function load(path)
    local fn, err = loadstring(fetch(path))
    if not fn then
        error(("[witherhook] %s failed to compile: %s"):format(path, tostring(err)), 0)
    end
    return fn
end

-- ---------- load the UI library ----------
local library = load("library.lua")()

-- ---------- branding ----------
library.rank  = "user"
library.title = "witherhook"

-- ---------- watermark ----------
local Wm    = library:Watermark("witherhook | v" .. library.version .. " | " .. library:GetUsername())
local FpsWm = Wm:AddWatermark("fps: " .. library.fps)
coroutine.wrap(function()
    while wait(0.75) do
        FpsWm:Text("fps: " .. library.fps)
    end
end)()

-- ---------- notifications + intro ----------
local Notif = library:InitNotifications()
Notif:Notify("witherhook loading...", 4, "information")

library:Introduction()
wait(1)
local Window = library:Init()

-- ---------- game dispatch ----------
-- Try to load a module named after the current PlaceId; fall back to
-- the universal shell if there's no game-specific module.
local gameKey = tostring(library:GetPlaceId())

local ctx = {
    library = library,
    window  = Window,
    notif   = Notif,
    fetch   = fetch,
    load    = load,
    base    = BASE,
    gameKey = gameKey,
}

local ok = pcall(function()
    load("Games/" .. gameKey .. ".lua")(ctx)
end)

if not ok then
    -- no per-game module: load the universal shell
    load("Games/universal.lua")(ctx)
end

Notif:Notify("witherhook loaded", 4, "success")

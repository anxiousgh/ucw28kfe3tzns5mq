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

-- raw.githubusercontent AND most executor HttpGet caches ignore query
-- strings, so pin the URL to the latest commit SHA: a unique path the
-- cache can't stale. Falls back to the branch if the API call fails.
local BASE
do
    local okSha, body = pcall(game.HttpGet, game,
        ("https://api.github.com/repos/%s/%s/commits/%s"):format(OWNER, REPO, BRANCH))
    local sha = okSha and type(body) == "string" and body:match('"sha"%s*:%s*"(%x+)"')
    if sha then
        BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, sha)
        print("[witherhook] pinned to commit " .. sha:sub(1, 12))
    else
        BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)
        warn("[witherhook] commit pin failed - using branch (may be cached)")
    end
end

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

-- A fetched body counts as "missing" if it's empty or GitHub's 404 text.
-- (Some executors return "" / "404: Not Found" instead of erroring on 404,
--  and loadstring("") is a valid no-op chunk -- which silently swallowed the
--  fallback before.)
local function bodyIsMissing(body)
    if type(body) ~= "string" then return true end
    if #(body:gsub("%s+", "")) == 0 then return true end
    if body:find("404: Not Found", 1, true) then return true end
    return false
end

-- Run a per-game module. Returns true ONLY if it really existed and ran.
local function tryGameModule(key)
    local okFetch, body = pcall(game.HttpGet, game, BASE .. "Games/" .. key .. ".lua")
    if not okFetch or bodyIsMissing(body) then
        return false
    end
    local fn, compileErr = loadstring(body)
    if not fn then
        warn("[witherhook] Games/" .. key .. ".lua compile error: " .. tostring(compileErr))
        return false
    end
    local okRun, runErr = pcall(fn, ctx)
    if not okRun then
        warn("[witherhook] Games/" .. key .. ".lua runtime error: " .. tostring(runErr))
        return false
    end
    print("[witherhook] loaded per-game module: Games/" .. key .. ".lua")
    return true
end

if not tryGameModule(gameKey) then
    -- default shell -- surfaced loudly if it ever breaks, instead of an empty UI
    local okU, errU = pcall(function() load("Games/universal.lua")(ctx) end)
    if okU then
        print("[witherhook] loaded universal shell (no module for placeId " .. gameKey .. ")")
    else
        warn("[witherhook] universal shell failed: " .. tostring(errU))
        Notif:Notify("witherhook: UI failed to load (see console)", 6, "error")
        return
    end
end

Notif:Notify("witherhook loaded", 4, "success")

-- ============================================================
--  witherhook // loader.lua
--  Boots the (self-hosted) Xsx UI library, creates the window,
--  detects the current game and dispatches to a Games/ module.
--
--  Public repo: fetched with plain game:HttpGet, no key needed.
--  Load with:
--    loadstring(game:HttpGet("https://raw.githubusercontent.com/anxiousgh/ucw28kfe3tzns5mq/main/loader.lua"))()
-- ============================================================

-- ---------- single-instance guard ----------
-- Don't let witherhook run twice in the same session -- a second execution
-- would stack duplicate GUIs, hooks and loops (and can crash/lag the game).
-- Re-execution is allowed again once the previous instance is unloaded.
if getgenv then
    local g = getgenv()
    local prev = g.WITHERHOOK
    if prev and prev.lib and not prev.lib.Unloaded then
        pcall(function() prev.notif:Notify("witherhook is already loaded", 4, "alert") end)
        warn("[witherhook] already loaded - ignoring duplicate execution")
        return
    end
    g.WITHERHOOK = { lib = false, notif = false }
end

-- ---------- config ----------
local OWNER  = "anxiousgh"
local REPO   = "ucw28kfe3tzns5mq"
local BRANCH = "main"

-- raw.githubusercontent AND most executor HttpGet caches ignore query
-- strings, so pin the URL to the latest commit SHA: a unique path the
-- cache can't stale. Falls back to the branch if the API call fails.
local BASE
local pinned = false   -- true => fetched from the exact latest commit (definitely up to date)
do
    local okSha, body = pcall(game.HttpGet, game,
        ("https://api.github.com/repos/%s/%s/commits/%s"):format(OWNER, REPO, BRANCH))
    local sha = okSha and type(body) == "string" and body:match('"sha"%s*:%s*"(%x+)"')
    if sha then
        BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, sha)
        pinned = true
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

-- ---------- version + current game ----------
local whVersion = "?"
do
    local okV, vbody = pcall(fetch, "version.txt")
    if okV and type(vbody) == "string" then
        local v = vbody:gsub("%s+", "")
        if #v > 0 then whVersion = v end
    end
end

local placeId  = tostring(library:GetPlaceId())
local gameName = "Game " .. placeId
pcall(function()
    local info = game:GetService("MarketplaceService"):GetProductInfo(tonumber(placeId))
    if info and info.Name then gameName = info.Name end
end)

-- ---------- branding ----------
library.rank  = "user"
library.title = "witherhook"

-- ---------- watermark ----------
-- ping comes from the engine's Data Ping stat (same source the old decay.lua
-- watermark used), guarded since Stats isn't always reachable.
local function getPing()
    local ping = 0
    pcall(function()
        ping = math.floor(game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue())
    end)
    return ping
end
local Wm    = library:Watermark("witherhook v" .. whVersion .. " | " .. gameName .. " | " .. library:GetUsername())
local FpsWm = Wm:AddWatermark("fps: " .. library.fps .. " | ping: " .. getPing() .. " ms")
coroutine.wrap(function()
    while wait(0.75) do
        FpsWm:Text("fps: " .. library.fps .. " | ping: " .. getPing() .. " ms")
    end
end)()

-- ---------- notifications + intro ----------
local Notif = library:InitNotifications()
-- register this instance so a later execution can detect we're already running
if getgenv then
    local g = getgenv()
    if g.WITHERHOOK then g.WITHERHOOK.lib, g.WITHERHOOK.notif = library, Notif end
end
Notif:Notify("witherhook loading...", 4, "information")

library:Introduction()
wait(1)
local Window = library:Init()

-- ---------- game dispatch ----------
-- Try to load a module named after the current PlaceId; fall back to
-- the universal shell if there's no game-specific module.
local gameKey = placeId

local ctx = {
    library  = library,
    window   = Window,
    notif    = Notif,
    fetch    = fetch,
    load     = load,
    base     = BASE,
    gameKey  = gameKey,
    version  = whVersion,
    gameName = gameName,
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

-- Optional override: set getgenv().LOAD_UNIVERSAL = "true" in your loadstring
-- to force the universal shell even on a supported game.
local function isTruthy(v)
    if v == true then return true end
    if type(v) == "string" then
        local s = v:lower()
        return s == "true" or s == "1" or s == "yes" or s == "on"
    end
    return false
end
local forceUniversal = false
pcall(function() forceUniversal = isTruthy(getgenv and getgenv().LOAD_UNIVERSAL) end)

local loadedGameModule = (not forceUniversal) and tryGameModule(gameKey)

if not loadedGameModule then
    -- default shell -- surfaced loudly if it ever breaks, instead of an empty UI
    local okU, errU = pcall(function() load("Games/universal.lua")(ctx) end)
    if okU then
        if forceUniversal then
            print("[witherhook] LOAD_UNIVERSAL set - forced universal shell")
        else
            print("[witherhook] loaded universal shell (no module for placeId " .. gameKey .. ")")
        end
    else
        warn("[witherhook] universal shell failed: " .. tostring(errU))
        Notif:Notify("witherhook: UI failed to load (see console)", 6, "error")
        return
    end
end

-- update status: SHA-pin succeeded => running the exact latest commit
if pinned then
    Notif:Notify("witherhook v" .. whVersion .. " loaded (up to date)", 4, "success")
else
    Notif:Notify("witherhook v" .. whVersion .. " loaded - couldn't verify latest (cached?)", 6, "alert")
end

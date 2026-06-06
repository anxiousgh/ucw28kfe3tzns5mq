-- ============================================================
--  witherhook // loader.lua
--  Boots the (self-hosted) Xsx UI library, creates the window,
--  detects the current game and dispatches to a Games/ module.
--
--  Repo is PRIVATE, so we fetch via the executor's request() with
--  an Authorization header instead of plain game:HttpGet.
-- ============================================================

-- ---------- config ----------
local OWNER  = "anxiousgh"
local REPO   = "ucw28kfe3tzns5mq"
local BRANCH = "main"
-- Fine-grained / classic PAT with read access to this private repo.
-- Paste it here before running. Keep it secret.
local TOKEN  = "ghp_REPLACE_ME"

local BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)

-- ---------- private raw fetch ----------
-- Executors expose one of these; pick whichever exists.
local httpRequest = (syn and syn.request)
    or (http and http.request)
    or http_request
    or request

local function fetch(path)
    if not httpRequest then
        error("[witherhook] no request() function available in this executor", 0)
    end
    local res = httpRequest({
        Url = BASE .. path,
        Method = "GET",
        Headers = {
            Authorization = "token " .. TOKEN,
            ["User-Agent"] = "witherhook",
        },
    })
    if not res or res.StatusCode ~= 200 then
        error(("[witherhook] fetch failed for %s (status %s)")
            :format(path, res and tostring(res.StatusCode) or "nil"), 0)
    end
    return res.Body
end

local function load(path)
    local src = fetch(path)
    local fn, err = loadstring(src)
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
local placeId  = tostring(library:GetPlaceId())
local gameKey  = placeId

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

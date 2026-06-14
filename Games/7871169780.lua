-- ============================================================
--  witherhook // Games/7871169780.lua   (Blockerman's Minesweeper)
--  Loads the shared shell (main.lua) then adds the BMS tabs:
--  Autoplay, Autoflag, Mouse mover. Backend ported from decay.lua.
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end

local Window = ctx.window
local hook   = api.hook
local notify = api.notify
local regToggle, regSlider, regDropdown = api.regToggle, api.regSlider, api.regDropdown
local regColor, regDecimal = api.regColor, api.regDecimal

-- ============================================================
--  BMS BACKEND  (ported from decay functions.lua; F.games -> hook.games).
--  Registers hook.games.bms + hook.games.bmsBullets.
-- ============================================================
do
local lplr       = hook.util.lplr or game:GetService("Players").LocalPlayer
local RunService = game:GetService("RunService")
hook.games = hook.games or {}

hook.games.bmsBullets = (function()
    local active = false
    local conn, charConn, pollThread
    local killCount = 0

    local function destroyIfBullet(d)
        if not active or not d then return end
        if d.Name == "Bullet-Part" then
            pcall(function() d:Destroy() end)
            killCount = killCount + 1
        end
    end

    local function sweepWorkspace()
        for _, d in ipairs(workspace:GetDescendants()) do
            if not active then return end
            if d.Name == "Bullet-Part" then
                pcall(function() d:Destroy() end)
                killCount = killCount + 1
            end
        end
    end

    -- DescendantAdded sometimes silently drops on respawn / round
    -- transitions on Potassium. The poll loop is the backup that
    -- guarantees bullets get destroyed even if the event listener
    -- never fires.
    local function startPoll()
        if pollThread then pcall(task.cancel, pollThread) end
        pollThread = task.spawn(function()
            while active do
                sweepWorkspace()
                task.wait(0.05)
            end
        end)
    end

    -- Re-attach the event listener on every character respawn since
    -- some games re-parent workspace contents after the character
    -- streams in.
    local function attachListener()
        if conn then conn:Disconnect() end
        conn = workspace.DescendantAdded:Connect(destroyIfBullet)
    end

    return {
        start = function()
            if active then return end
            active = true
            killCount = 0
            attachListener()
            if charConn then charConn:Disconnect() end
            charConn = game:GetService("Players").LocalPlayer.CharacterAdded:Connect(function()
                task.wait(0.2)
                if active then attachListener(); sweepWorkspace() end
            end)
            startPoll()
            sweepWorkspace()
            print("[BMS bullets] enabled - polling every 50ms + DescendantAdded listener")
        end,
        stop = function()
            active = false
            if conn       then conn:Disconnect();     conn       = nil end
            if charConn   then charConn:Disconnect(); charConn   = nil end
            if pollThread then pcall(task.cancel, pollThread); pollThread = nil end
            print(("[BMS bullets] disabled - %d bullets destroyed"):format(killCount))
        end,
        isActive = function() return active end,
        getKills = function() return killCount end,
    }
end)()

hook.games.bms = (function()
    local RS = game:GetService("ReplicatedStorage")

    local function getPlaceFlag()
        local ev = RS:FindFirstChild("Events")
        local fe = ev and ev:FindFirstChild("FlagEvents")
        return fe and fe:FindFirstChild("PlaceFlag")
    end

    -- Cached parts-folder reference. The folder rarely (never?)
    -- changes during a game, so paying a workspace.FindFirstChild
    -- traversal on EVERY tick was pure overhead. We re-resolve only
    -- if the cached ref's Parent is gone.
    local _partsRef = nil
    local function getParts()
        if _partsRef and _partsRef.Parent then return _partsRef end
        local f = workspace:FindFirstChild("Flag")
        _partsRef = f and f:FindFirstChild("Parts")
        return _partsRef
    end

    -- Token capture. Resolve the remote ref once (try immediate, fall
    -- back to deferred WaitForChild) and have the hook do nothing but
    -- a single ref compare against the cached ref.
    local function resolveRefSync()
        local ev = RS:FindFirstChild("Events")
        local fe = ev and ev:FindFirstChild("FlagEvents")
        local pf = fe and fe:FindFirstChild("PlaceFlag")
        if pf then
            getgenv()._BMS_PLACEFLAG_REF = pf
            print("[BMS] resolved PlaceFlag ref:", pf:GetFullName())
            return true
        end
        return false
    end
    if not getgenv()._BMS_PLACEFLAG_REF then
        if not resolveRefSync() then
            task.defer(function()
                local ev = RS:WaitForChild("Events", 30)
                local fe = ev and ev:WaitForChild("FlagEvents", 30)
                local pf = fe and fe:WaitForChild("PlaceFlag", 30)
                if pf then
                    getgenv()._BMS_PLACEFLAG_REF = pf
                    print("[BMS] resolved PlaceFlag ref (deferred):", pf:GetFullName())
                else
                    warn("[BMS] failed to resolve PlaceFlag - Events folder never appeared")
                end
            end)
        end
    end
    if not getgenv()._BMS_HOOK_INSTALLED and hookmetamethod then
        getgenv()._BMS_HOOK_INSTALLED = true
        local _old
        _old = hookmetamethod(game, "__namecall", function(self, ...)
            if self == getgenv()._BMS_PLACEFLAG_REF then
                local _, tok = ...
                if typeof(tok) == "string" and #tok > 8 and getgenv()._BMS_TOKEN ~= tok then
                    getgenv()._BMS_TOKEN = tok
                    print("[BMS] captured token:", tok)
                end
            end
            return _old(self, ...)
        end)
        print("[BMS] __namecall hook installed (hookmetamethod available)")
    elseif not hookmetamethod then
        warn("[BMS] hookmetamethod not available on this executor - use manual token input")
    end

    -- Public helper for manual token entry (UI exposes a textbox).
    local function setManualToken(s)
        s = tostring(s or "")
        if #s > 8 then
            getgenv()._BMS_TOKEN = s
            print("[BMS] manual token set:", s)
            return true
        end
        return false
    end

    -- ============================================================
    -- Auto-capture the flag token from the GC.
    -- ============================================================
    -- The BMS LocalScript that owns PlaceFlag also owns the per-
    -- session token string - both are upvalues of the same closure.
    -- Walk every function in getgc(true), look for one that:
    --   * holds getgenv()._BMS_PLACEFLAG_REF as an upvalue
    --   * AND has some other long token-shaped string upvalue
    -- The first such string is the token.
    --
    -- Most executors expose getgc + debug.getupvalue (Synapse, Krnl,
    -- Fluxus, Solara, AWP, Potassium). Bail cleanly when they don't.
    --
    -- Re-runs harmlessly: if we already have a token cached we just
    -- return it, no scan.
    local function autoCaptureToken()
        local existing = getgenv()._BMS_TOKEN
        if existing then return existing end
        if not getgc or not debug or not debug.getupvalue then
            return nil
        end
        local pf = getgenv()._BMS_PLACEFLAG_REF
        if not pf then return nil end
        local ok, gc = pcall(function() return getgc(true) end)
        if not ok or type(gc) ~= "table" then return nil end
        for _, v in next, gc do
            if type(v) == "function" then
                local hasPF, foundStr = false, nil
                local i = 1
                while true do
                    local got, name, value = pcall(debug.getupvalue, v, i)
                    if not got or not name then break end
                    if value == pf then hasPF = true end
                    if not foundStr and type(value) == "string"
                       and #value >= 16 and #value <= 256
                       and value:match("^[%w%-%_%+%/%=]+$") then
                        foundStr = value
                    end
                    if hasPF and foundStr then break end
                    i = i + 1
                end
                if hasPF and foundStr then
                    getgenv()._BMS_TOKEN = foundStr
                    print("[BMS] auto-captured token from GC:", foundStr)
                    return foundStr
                end
            end
        end
        return nil
    end

    -- Fire one auto-capture attempt now (PlaceFlag is resolved at
    -- this point) and a retry loop in case the LocalScript that
    -- creates the token hasn't run yet. Retries every 2s for up to
    -- 30s, exits as soon as we get a token.
    task.spawn(function()
        local tries = 0
        while not getgenv()._BMS_TOKEN and tries < 15 do
            autoCaptureToken()
            if getgenv()._BMS_TOKEN then return end
            tries = tries + 1
            task.wait(2)
        end
        if not getgenv()._BMS_TOKEN then
            warn("[BMS] auto-capture gave up; place one flag manually OR enter the token via the UI.")
        end
    end)

    -- ---- per-tile helpers ----
    local function tileState(tile)
        for _, ch in ipairs(tile:GetChildren()) do
            if ch:IsA("Model")        then return "flagged"  end
            if ch.Name == "NumberGui" then return "revealed" end
        end
        return "covered"
    end

    -- Per-tile state cache. The state-build loop runs O(N) every
    -- autoplay/ESP/deduce tick - with thousands of tiles in infinite
    -- mode each tick spent thousands of GetChildren scans. We
    -- invalidate a tile's cached state via DescendantAdded /
    -- DescendantRemoving on the parts folder: when a direct child of
    -- a tile (Model = flag, NumberGui = reveal) is added or removed,
    -- only that tile's cache entry is dropped. Loops then use
    -- tileStateCached() which is a table lookup for the unchanged
    -- 99% of tiles.
    local _stateCache  = {}
    -- _numberCache MUST be declared above the parts-folder listener
    -- block below, because the DescendantAdded / ChildAdded callbacks
    -- index it. The OG declaration sat further down which captured
    -- it as a nil global -> ':7263: attempt to index nil with Instance'
    -- spammed every reveal.
    local _numberCache = {}
    local function tileStateCached(t)
        local s = _stateCache[t]
        if s then return s end
        s = tileState(t)
        _stateCache[t] = s
        return s
    end
    do
        local parts = getParts()
        if parts then
            parts.DescendantAdded:Connect(function(d)
                local p = d.Parent
                if p and p.Parent == parts then
                    _stateCache[p]  = nil
                    _numberCache[p] = nil
                end
            end)
            parts.DescendantRemoving:Connect(function(d)
                local p = d.Parent
                if p and p.Parent == parts then
                    _stateCache[p]  = nil
                    _numberCache[p] = nil
                end
            end)
            -- direct tile add/remove also clears (tile won't be in the
            -- cache yet for adds, but for removes we want it gone)
            parts.ChildAdded:Connect(function(t)
                _stateCache[t]  = nil
                _numberCache[t] = nil
            end)
            parts.ChildRemoved:Connect(function(t)
                _stateCache[t]  = nil
                _numberCache[t] = nil
            end)
        end
    end

    local function tileNumber(tile)
        local g = tile:FindFirstChild("NumberGui")
        if not g then return nil end
        for _, d in ipairs(g:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local n = tonumber(d.Text)
                if n then return n end
            end
        end
    end

    -- Cache for tileNumber. A tile's number doesn't change after the
    -- reveal that placed it, so once we compute it we can keep it
    -- forever. Cleared per-tile when the NumberGui is removed
    -- (handled by the same listeners as _stateCache). The actual
    -- `local _numberCache = {}` declaration lives above so the
    -- listener closures can see it as an upvalue.
    local function tileNumberCached(tile)
        local n = _numberCache[tile]
        if n ~= nil then return n end
        n = tileNumber(tile)
        _numberCache[tile] = n or false  -- nil means "no NumberGui"; false caches that fact
        return n
    end

    -- ---- neighbor caches ----
    --   neighbors[]         - 8-direction (includes diagonals).
    --                         Used by the DEDUCTION solver since
    --                         minesweeper numbers count diagonal mines.
    --   cardinalNeighbors[] - 4-direction (N/S/E/W only).
    --                         Used by the AUTO-PLAY pathfinder so the
    --                         character never cuts diagonally across
    --                         an unknown tile's corner and falls in.
    local neighbors         = {}
    local cardinalNeighbors = {}
    -- INCREMENTAL neighbor graph with a spatial grid hash. The
    -- old implementation did a full O(N^2) rebuild every time a
    -- tile was added or removed. In infinite mode every reveal
    -- spawns new tiles -> full rescan of every existing tile -
    -- with ~1000 tiles that's a million distance checks per
    -- reveal. Pure lag spike.
    --
    -- New scheme: bucket tiles into grid cells of cellSize =
    -- tileSize, so any neighbor lookup only touches a 3x3 cell
    -- window (~9 candidates). Tile add/remove is O(neighbour
    -- count) ~ O(1) instead of O(N). One ensureNeighbors() call
    -- diffs against the known-tile set and applies just the
    -- delta - effectively free when nothing changed.
    local knownTiles  = {}   -- set of tiles whose neighbour list is built
    -- Spatial grid: NESTED tables grid[cx][cz] = {tile, ...}. Old
    -- version concatenated "cx,cz" -> string on every cell lookup
    -- which allocated a fresh string per access (~18/tile add). At
    -- infinite-mode reveal rates that's a lot of GC churn.
    local spatialGrid = {}
    local tileCellX   = {}   -- tile -> integer cellX (for removal)
    local tileCellZ   = {}   -- tile -> integer cellZ
    -- Ordered tile list, maintained incrementally. Used in place of
    -- parts:GetChildren() which alloc'd a fresh N-element table on
    -- every autoplay / ESP tick.
    local tileList    = {}
    local tileIndex   = {}   -- tile -> 1-based index in tileList
    local tileSize    = nil  -- derived from first tile seen
    local diagR2, cardR2

    local function _listAdd(t)
        table.insert(tileList, t)
        tileIndex[t] = #tileList
    end
    local function _listRemove(t)
        local i = tileIndex[t]; if not i then return end
        local n = #tileList
        if i ~= n then
            local last = tileList[n]
            tileList[i] = last
            tileIndex[last] = i
        end
        tileList[n] = nil
        tileIndex[t] = nil
    end

    local function _gridAdd(t)
        local cx = math.floor(t.Position.X / tileSize)
        local cz = math.floor(t.Position.Z / tileSize)
        local row = spatialGrid[cx]
        if not row then row = {}; spatialGrid[cx] = row end
        local cell = row[cz]
        if not cell then cell = {}; row[cz] = cell end
        table.insert(cell, t)
        tileCellX[t] = cx
        tileCellZ[t] = cz
    end
    local function _gridRemove(t)
        local cx, cz = tileCellX[t], tileCellZ[t]
        if not cx then return end
        local row = spatialGrid[cx]
        local cell = row and row[cz]
        if cell then
            for i, x in ipairs(cell) do
                if x == t then table.remove(cell, i); break end
            end
        end
        tileCellX[t] = nil
        tileCellZ[t] = nil
    end
    -- iterate tiles in the 3x3 cell window around `t` (excluding `t`)
    local function _nearby(t, fn)
        local cx = math.floor(t.Position.X / tileSize)
        local cz = math.floor(t.Position.Z / tileSize)
        for dx = -1, 1 do
            local row = spatialGrid[cx + dx]
            if row then
                for dz = -1, 1 do
                    local cell = row[cz + dz]
                    if cell then
                        for _, o in ipairs(cell) do
                            if o ~= t then fn(o) end
                        end
                    end
                end
            end
        end
    end
    -- build neighbour lists for tile `t` (uses current grid which
    -- already has `t` inserted; _nearby filters self out)
    local function _buildOne(t)
        local list8, list4 = {}, {}
        local px, pz = t.Position.X, t.Position.Z
        _nearby(t, function(o)
            local dx = o.Position.X - px
            local dz = o.Position.Z - pz
            local d2 = dx*dx + dz*dz
            if d2 < diagR2 then table.insert(list8, o) end
            if d2 < cardR2 then table.insert(list4, o) end
        end)
        neighbors[t]         = list8
        cardinalNeighbors[t] = list4
    end
    -- after `t` is added: also insert `t` into the neighbour lists
    -- of every existing nearby tile (within range)
    local function _injectIntoExisting(t)
        local px, pz = t.Position.X, t.Position.Z
        _nearby(t, function(o)
            local dx = o.Position.X - px
            local dz = o.Position.Z - pz
            local d2 = dx*dx + dz*dz
            local n8 = neighbors[o]
            if d2 < diagR2 and n8 then table.insert(n8, t) end
            local n4 = cardinalNeighbors[o]
            if d2 < cardR2 and n4 then table.insert(n4, t) end
        end)
    end
    -- strip `t` from every nearby tile's neighbour lists
    local function _evictFromExisting(t)
        _nearby(t, function(o)
            local n8 = neighbors[o]
            if n8 then
                for i, x in ipairs(n8) do
                    if x == t then table.remove(n8, i); break end
                end
            end
            local n4 = cardinalNeighbors[o]
            if n4 then
                for i, x in ipairs(n4) do
                    if x == t then table.remove(n4, i); break end
                end
            end
        end)
    end

    local function ensureNeighbors(allParts)
        if not tileSize and allParts[1] then
            tileSize = math.max(allParts[1].Size.X, allParts[1].Size.Z)
            diagR2 = (tileSize * 1.6) ^ 2
            cardR2 = (tileSize * 1.1) ^ 2
        end
        if not tileSize then return end

        -- Pass 1: incoming set + add new tiles.
        local incoming = {}
        for _, t in ipairs(allParts) do
            incoming[t] = true
            if not knownTiles[t] then
                _gridAdd(t)
                _buildOne(t)
                _injectIntoExisting(t)
                _listAdd(t)
                knownTiles[t] = true
            end
        end

        -- Pass 2: drop tiles that are gone. O(known) but skipped via
        -- `incoming` lookup for the steady-state add-only case.
        for t in pairs(knownTiles) do
            if not incoming[t] or not t.Parent then
                _evictFromExisting(t)
                _gridRemove(t)
                _listRemove(t)
                neighbors[t]         = nil
                cardinalNeighbors[t] = nil
                knownTiles[t]        = nil
            end
        end
    end

    -- Watch the live folder so add/remove events keep our grid in
    -- sync even between ensureNeighbors() calls. We use ChildAdded
    -- to insert eagerly (so the next deduce/ESP pass already sees
    -- the new tile in its neighbour map without paying a rebuild
    -- cost), and ChildRemoved to evict immediately.
    --
    -- Initial sync: ChildAdded only fires for FUTURE additions.
    -- Tiles already present when this script loaded would have
    -- been missed, leaving tileList empty (ESP shows nothing).
    -- We do one explicit GetChildren() pass at startup to seed
    -- everything, retrying every 0.5s until the parts folder is
    -- available (game may still be loading).
    local function _adoptTile(t)
        if not t:IsA("BasePart") then return end
        if not tileSize then
            tileSize = math.max(t.Size.X, t.Size.Z)
            diagR2 = (tileSize * 1.6) ^ 2
            cardR2 = (tileSize * 1.1) ^ 2
        end
        if not knownTiles[t] then
            _gridAdd(t)
            _buildOne(t)
            _injectIntoExisting(t)
            _listAdd(t)
            knownTiles[t] = true
        end
    end
    local function _releaseTile(t)
        if not knownTiles[t] then return end
        _evictFromExisting(t)
        _gridRemove(t)
        _listRemove(t)
        neighbors[t]         = nil
        cardinalNeighbors[t] = nil
        knownTiles[t]        = nil
    end
    do
        local _connected = false
        local function _connect(parts)
            if _connected then return end
            _connected = true
            parts.ChildAdded:Connect(_adoptTile)
            parts.ChildRemoved:Connect(_releaseTile)
            for _, t in ipairs(parts:GetChildren()) do
                _adoptTile(t)
            end
        end

        local parts = getParts()
        if parts then
            _connect(parts)
        else
            task.spawn(function()
                while not _connected do
                    local p = getParts()
                    if p then _connect(p); return end
                    task.wait(0.5)
                end
            end)
        end
    end

    -- ---- deduction (basic rules + subset reduction) ----
    --
    -- For each revealed number N we get a constraint:
    --   "exactly (N - knownMinesAround) mines exist in this set of
    --   unknown neighbors."
    --
    -- Basic rules:
    --   rule 1: remaining == |unknown|  -> all unknown are mines
    --   rule 2: remaining == 0          -> all unknown are safe
    --
    -- Subset reduction (this is what catches 1-2-1, 1-2-2-1, edge
    -- patterns and a lot of mid-game stuff the basic rules miss):
    --   if constraint A.set is a STRICT subset of constraint B.set,
    --   then B.set \ A.set contains exactly (B.remaining - A.remaining)
    --   mines. From which:
    --     if (B.rem - A.rem) == |B.set \ A.set|  -> all extras are mines
    --     if (B.rem - A.rem) == 0                -> all extras are safe
    --
    -- Both rules + subset reduction are re-applied to fixed point so
    -- newly-discovered mines/safes propagate into the next iteration.
    -- ============================================================
    --
    -- Module-level signature cache. autoplay, ESP, and the chain
    -- loop all call deduce(); without a shared cache they each pay
    -- the full constraint+subset+tank cost every tick (e.g. autoplay
    -- runs at ~10Hz so deduce was firing 10x/sec even when the board
    -- hadn't changed). After a 50/50 guess dies the autoplay loop
    -- spins on respawn frames, hammering this - that was the
    -- "freezes and crashes on 50/50" symptom.
    --
    -- Sig = covered*1e6 + revealed*1000 + flagged. Collisions are
    -- harmless because they only happen on equivalent boards.
    local _deduceLastSig    = nil
    local _deduceLastResult = nil

    -- _deduceImpl: the uncached computation. ESP calls this directly
    -- with a SUBSET of tiles (near-player culling) so its subset
    -- result doesn't thrash the autoplay-shared global cache.
    -- The cached wrapper `deduce` lives below.
    local function _deduceImpl(parts, state)
        local knownMines = {}
        local knownSafes = {}
        local tileProbs  = {}  -- [tile] = mine probability (only filled by tank solver for tiles in small components)

        local function buildConstraints()
            -- Rebuild the constraint list from the current known sets.
            -- Each constraint = { set = {tile=true,...}, list = {tile,...},
            --                     remaining = mines_left, count = #list }
            -- Skip constraints whose unknown set is empty.
            local out = {}
            for _, t in ipairs(parts) do
                if state[t] == "revealed" then
                    local n = tileNumberCached(t)
                    if n then
                        local nbrs = neighbors[t]
                        if nbrs then
                            local minesIn, set, list = 0, {}, {}
                            for _, nb in ipairs(nbrs) do
                                if knownMines[nb] then
                                    minesIn = minesIn + 1
                                elseif knownSafes[nb] then
                                    -- already safe = ignore from constraint
                                elseif state[nb] == "covered" or state[nb] == "flagged" then
                                    -- "flagged" stays in unknown set; we
                                    -- don't trust user flags.
                                    if not set[nb] then
                                        set[nb] = true
                                        table.insert(list, nb)
                                    end
                                end
                            end
                            if #list > 0 then
                                table.insert(out, {
                                    set = set, list = list,
                                    remaining = n - minesIn,
                                    count = #list,
                                })
                            end
                        end
                    end
                end
            end
            return out
        end

        local function basicPass(constraints)
            local changed = false
            for _, c in ipairs(constraints) do
                -- rule 1
                if c.remaining == c.count then
                    for _, u in ipairs(c.list) do
                        if not knownMines[u] then knownMines[u] = true; changed = true end
                    end
                end
                -- rule 2
                if c.remaining == 0 then
                    for _, u in ipairs(c.list) do
                        if not knownSafes[u] then knownSafes[u] = true; changed = true end
                    end
                end
            end
            return changed
        end

        -- Variable-index-based subsetPass. Old version was O(C^2) - for
        -- each constraint pair (A, B) it always tested subset relation.
        -- On 1000+ constraints (a 1.2k-tile board late game) that's a
        -- million-iteration spike every time deduce re-runs.
        --
        -- Key insight: A can only be a subset of B if A and B share at
        -- least one variable. So we build a variable -> constraint
        -- index, and for each A we only consider candidate Bs that
        -- share at least one of A's variables. Constraints in BMS are
        -- spatially LOCAL (each reveal touches 8 neighbours), so the
        -- candidate count per A is O(constraints_in_neighbourhood)
        -- which is bounded by a small constant - net effective work
        -- becomes O(C) not O(C^2).
        local function subsetPass(constraints)
            local changed = false
            if #constraints < 2 then return false end

            -- build var -> {constraint-index, ...} map
            local varToCs = {}
            for i, c in ipairs(constraints) do
                for u in pairs(c.set) do
                    local list = varToCs[u]
                    if not list then list = {}; varToCs[u] = list end
                    table.insert(list, i)
                end
            end

            for i = 1, #constraints do
                local A = constraints[i]
                -- collect candidate Bs: any constraint sharing >=1 var
                local candidates = {}
                for u in pairs(A.set) do
                    for _, j in ipairs(varToCs[u] or {}) do
                        if j ~= i then candidates[j] = true end
                    end
                end
                for j in pairs(candidates) do
                    local B = constraints[j]
                    if A.count < B.count then
                        local subset = true
                        for u in pairs(A.set) do
                            if not B.set[u] then subset = false; break end
                        end
                        if subset then
                            local extras = {}
                            for u in pairs(B.set) do
                                if not A.set[u] then table.insert(extras, u) end
                            end
                            local extraMines = B.remaining - A.remaining
                            if extraMines == #extras and extraMines > 0 then
                                for _, u in ipairs(extras) do
                                    if not knownMines[u] then
                                        knownMines[u] = true; changed = true
                                    end
                                end
                            elseif extraMines == 0 then
                                for _, u in ipairs(extras) do
                                    if not knownSafes[u] then
                                        knownSafes[u] = true; changed = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
            return changed
        end

        -- ---- TANK SOLVER (brute-force enumeration) ----
        --
        -- After pattern rules converge, split the remaining constraints
        -- into connected components (constraints linked by shared
        -- unknowns). For each component small enough to brute-force,
        -- enumerate all 2^N mine/safe assignments, keep the valid ones
        -- (satisfy every constraint exactly), then mark any unknown
        -- that's a mine in EVERY valid assignment (definite mine) or
        -- safe in every valid assignment (definite safe).
        --
        -- This catches every named pattern (1>2<1 pinch, T-pattern,
        -- T1-T5 tricks, corner combinations, etc) because they're all
        -- special cases of global constraint satisfaction.
        --
        -- Cap each component at MAX_TANK unknowns (2^N enumerations).
        -- 14 = ~16k iters per component = milliseconds; 18 = ~260k =
        -- borderline. 14 is a safe default. MAX_TANK_TOTAL is a per-
        -- deduce-call budget across ALL components combined - prevents
        -- a board with 10 connected 14-tile blobs from spinning for
        -- ~160k * 10 iters in one tick.
        local MAX_TANK = 14
        local MAX_TANK_TOTAL = 50000
        local function tankPass(cs)
            if #cs == 0 then return false end
            -- union-find groups constraints that share any unknown
            local parent_uf = {}
            local function find(x)
                while parent_uf[x] ~= x do x = parent_uf[x] end
                return x
            end
            local function union(a, b)
                a = find(a); b = find(b)
                if a ~= b then parent_uf[a] = b end
            end
            local allUnk = {}  -- ordered list of all unknown tiles across cs
            local seenU = {}
            for _, c in ipairs(cs) do
                for u in pairs(c.set) do
                    if not seenU[u] then
                        seenU[u] = true
                        parent_uf[u] = u
                        table.insert(allUnk, u)
                    end
                end
            end
            for _, c in ipairs(cs) do
                local prev
                for u in pairs(c.set) do
                    if prev then union(prev, u) end
                    prev = u
                end
            end
            -- group unknowns + constraints by root
            local groupUnk, groupCons = {}, {}
            for _, u in ipairs(allUnk) do
                local r = find(u)
                groupUnk[r] = groupUnk[r] or {}
                table.insert(groupUnk[r], u)
            end
            for _, c in ipairs(cs) do
                local anyU; for u in pairs(c.set) do anyU = u; break end
                if anyU then
                    local r = find(anyU)
                    groupCons[r] = groupCons[r] or {}
                    table.insert(groupCons[r], c)
                end
            end
            local changed = false
            local totalBudget = MAX_TANK_TOTAL
            for root, unknowns in pairs(groupUnk) do
                local n = #unknowns
                if n > 0 and n <= MAX_TANK then
                    local twoN_check = 1
                    for _ = 1, n do twoN_check = twoN_check * 2 end
                    if twoN_check > totalBudget then
                        -- skip this component if it'd blow the per-tick budget
                        -- (still useful: smaller components after still run)
                    else
                    totalBudget = totalBudget - twoN_check
                    local gcs = groupCons[root] or {}
                    -- precompute: idx[tile] = position in unknowns
                    -- cIdx[ci] = list of unknown indices for constraint ci
                    local idx = {}
                    for i = 1, n do idx[unknowns[i]] = i end
                    local cIdx = {}
                    local cRem = {}
                    for ci, c in ipairs(gcs) do
                        local list = {}
                        for u in pairs(c.set) do
                            list[#list + 1] = idx[u]
                        end
                        cIdx[ci] = list
                        cRem[ci] = c.remaining
                    end
                    local mineYes, mineNo = {}, {}
                    for i = 1, n do mineYes[i] = 0; mineNo[i] = 0 end
                    local totalValid = 0
                    local twoN = 1
                    for _ = 1, n do twoN = twoN * 2 end
                    -- assignment vector is 0/1 ints so we can sum directly
                    local assign = table.create and table.create(n, 0) or {}
                    if #assign < n then for i = 1, n do assign[i] = 0 end end
                    for mask = 0, twoN - 1 do
                        local m = mask
                        for i = 1, n do
                            local bit = m % 2
                            assign[i] = bit
                            m = (m - bit) * 0.5
                        end
                        -- check all constraints; early-out on failure
                        local valid = true
                        for ci = 1, #gcs do
                            local list = cIdx[ci]
                            local mc = 0
                            for k = 1, #list do mc = mc + assign[list[k]] end
                            if mc ~= cRem[ci] then valid = false; break end
                        end
                        if valid then
                            totalValid = totalValid + 1
                            for i = 1, n do
                                if assign[i] == 1 then mineYes[i] = mineYes[i] + 1
                                else                   mineNo[i]  = mineNo[i]  + 1 end
                            end
                        end
                    end
                    if totalValid > 0 then
                        for i = 1, n do
                            local u = unknowns[i]
                            if mineYes[i] == totalValid and not knownMines[u] then
                                knownMines[u] = true; changed = true
                            elseif mineNo[i] == totalValid and not knownSafes[u] then
                                knownSafes[u] = true; changed = true
                            else
                                -- partial: record mine probability for
                                -- 50/50 ESP + auto-play guessing
                                tileProbs[u] = mineYes[i] / totalValid
                            end
                        end
                    end
                    end  -- close totalBudget check
                end
            end
            return changed
        end

        -- iterate basic + subset + tank to fixed point.
        for _ = 1, 12 do
            local cs = buildConstraints()
            local c1 = basicPass(cs)
            local c2 = subsetPass(cs)
            local c3 = tankPass(cs)
            if not c1 and not c2 and not c3 then break end
        end

        -- false flags: user flagged it but our deduction says safe
        local falseFlags = {}
        for _, t in ipairs(parts) do
            if state[t] == "flagged" and not knownMines[t] and knownSafes[t] then
                falseFlags[t] = true
            end
        end
        -- prune probs for tiles we now know definitively
        for t in pairs(tileProbs) do
            if knownMines[t] or knownSafes[t] then tileProbs[t] = nil end
        end
        -- Pure 50/50 pairs: constraints with exactly 2 unknowns and 1
        -- mine. Auto-play in guess mode flags one + walks the other in
        -- the same tick (both are equally likely, the choice is
        -- arbitrary; the walked tile reveals safely 50% of the time,
        -- and the flagged tile is correctly marked the other 50%).
        local fiftyPairs = {}
        do
            local seen = {}
            for _, c in ipairs(buildConstraints()) do
                if c.count == 2 and c.remaining == 1 then
                    -- dedupe by sorted-pair key
                    local a, b = c.list[1], c.list[2]
                    local key = (tostring(a) < tostring(b))
                        and (tostring(a) .. "|" .. tostring(b))
                        or  (tostring(b) .. "|" .. tostring(a))
                    if not seen[key] then
                        seen[key] = true
                        table.insert(fiftyPairs, { a, b })
                    end
                end
            end
        end
        return knownMines, knownSafes, falseFlags, tileProbs, fiftyPairs
    end

    -- Cached wrapper. autoplay + chain use this so a steady-state
    -- (no reveal between ticks) returns instantly. ESP intentionally
    -- bypasses by calling _deduceImpl directly with a culled subset.
    local function deduce(parts, state)
        local cov, rev, flg = 0, 0, 0
        for _, t in ipairs(parts) do
            local s = state[t]
            if s == "covered"  then cov = cov + 1
            elseif s == "revealed" then rev = rev + 1
            elseif s == "flagged"  then flg = flg + 1 end
        end
        local sig = cov * 1e6 + rev * 1000 + flg
        if sig == _deduceLastSig and _deduceLastResult then
            local r = _deduceLastResult
            return r[1], r[2], r[3], r[4], r[5]
        end
        local m, s, ff, pr, fp = _deduceImpl(parts, state)
        _deduceLastSig    = sig
        _deduceLastResult = { m, s, ff, pr, fp }
        return m, s, ff, pr, fp
    end

    -- Spatial query: all known tiles within `radius` studs of
    -- `origin`. Uses the spatial grid so the cost is ~O(K) where K
    -- is the count of tiles inside the radius, not O(N) total.
    -- Used by ESP to limit per-tick work to a window around the
    -- player (currently a ~30-tile-wide square, configurable via
    -- espScanRadius). Autowalk still operates on the full tileList.
    local function _nearbyTiles(origin, radius)
        local out = {}
        if not tileSize then return out end
        local r  = math.ceil(radius / tileSize)
        local cx = math.floor(origin.X / tileSize)
        local cz = math.floor(origin.Z / tileSize)
        local r2 = radius * radius
        for dx = -r, r do
            local row = spatialGrid[cx + dx]
            if row then
                for dz = -r, r do
                    local cell = row[cz + dz]
                    if cell then
                        for _, t in ipairs(cell) do
                            local ex = t.Position.X - origin.X
                            local ez = t.Position.Z - origin.Z
                            if ex*ex + ez*ez < r2 then
                                table.insert(out, t)
                            end
                        end
                    end
                end
            end
        end
        return out
    end

    -- ---- range filter ----
    local function inRange(tile, originPos, rangeSq)
        local dx = tile.Position.X - originPos.X
        local dy = tile.Position.Y - originPos.Y
        local dz = tile.Position.Z - originPos.Z
        return (dx*dx + dy*dy + dz*dz) < rangeSq
    end

    local function myPos()
        local c = lplr.Character
        local hrp = c and c:FindFirstChild("HumanoidRootPart")
        return hrp and hrp.Position or Vector3.zero
    end

    -- ---- ESP (SurfaceGui-based, no per-scene cap) ----
    --
    -- Highlight instances have a soft cap (~31 active before they
    -- silently stop rendering). Late-game with 80+ flagged tiles
    -- caused ESP to vanish. Switching to a SurfaceGui parented to
    -- each tile (Top face) - it's just a colored Frame + UIStroke,
    -- no engine cap, no scene-wide cost.
    local surfaces = {}  -- [tile] = SurfaceGui (cached)
    local espActive = false
    local espRange = 80
    local espShowSafes = false
    local espShowWarnings = true
    local espThread

    -- Near-player scan radius for ESP. Default 30-tile-wide window
    -- (15 tiles * tileSize each side). In infinite mode the board
    -- can hold thousands of tiles - iterating them all every tick
    -- was the dominant cost even with caches. Limiting to a window
    -- around the player makes ESP O(window) instead of O(board).
    local espScanRadius = 60  -- studs; recomputed once tileSize is known
    local _espLastSeen  = nil -- last tick's `seen` set (visible surfaces)

    local function ensureSurface(tile)
        local sg = surfaces[tile]
        if sg and sg.Parent then return sg end
        sg = Instance.new("SurfaceGui")
        sg.Name              = "_BMS_ESP"
        sg.Face              = Enum.NormalId.Top
        sg.AlwaysOnTop       = true
        sg.LightInfluence    = 0
        sg.SizingMode        = Enum.SurfaceGuiSizingMode.PixelsPerStud
        sg.PixelsPerStud     = 50
        sg.Adornee           = tile
        sg.Parent            = tile

        local frame = Instance.new("Frame")
        frame.Name                   = "Fill"
        frame.Size                   = UDim2.fromScale(1, 1)
        frame.BackgroundTransparency = 0.4
        frame.BorderSizePixel        = 0
        frame.Parent                 = sg

        local stroke = Instance.new("UIStroke")
        stroke.Thickness    = 3
        stroke.Transparency = 0
        stroke.Parent       = frame

        surfaces[tile] = sg
        return sg
    end

    local function setColor(tile, color)
        local sg = ensureSurface(tile)
        local fr = sg:FindFirstChild("Fill")
        if fr then
            fr.BackgroundColor3 = color
            local st = fr:FindFirstChildOfClass("UIStroke")
            if st then st.Color = color end
        end
        sg.Enabled = true
    end

    local function clearAllHl()
        for _, sg in pairs(surfaces) do if sg then sg.Enabled = false end end
    end

    -- All ESP colors are user-settable via hook.games.bms.esp.set*Color
    local MINE_COLOR  = Color3.fromRGB(255, 40,  40)
    local SAFE_COLOR  = Color3.fromRGB(40,  220, 80)
    local WARN_COLOR  = Color3.fromRGB(255, 0,   200)  -- magenta: doesn't clash with heatmap green->yellow->red
    local FIFTY_COLOR = Color3.fromRGB(60,  140, 255)
    local espShowFifties = true
    local espHeatmap     = false  -- color every covered tile by mine probability

    -- gradient 0% -> 50% -> 100% maps to green -> yellow -> red
    local function probToColor(p)
        if p <= 0.5 then
            local t = p / 0.5  -- 0..1
            return Color3.new(t, 1, 0)  -- green (0,1,0) -> yellow (1,1,0)
        else
            local t = (p - 0.5) / 0.5  -- 0..1
            return Color3.new(1, 1 - t, 0)  -- yellow (1,1,0) -> red (1,0,0)
        end
    end

    -- Per-tick cache so we only re-deduce when state actually changed.
    -- Cheap signature: count of covered/revealed/flagged. If counts
    -- match the prior tick the constraints are the same -> reuse the
    -- prior mines/safes/falseFlags result and just re-render. This is
    -- the dominant late-game lag fix: skip the O(C^2 * iters) deduce
    -- on every tick when nothing changed.
    local _lastSig, _lastResult = nil, nil

    local function espTick()
        local parts = getParts()
        if not parts then clearAllHl(); return end
        ensureNeighbors(tileList)
        -- ESP only scans tiles near the player. The global neighbour
        -- graph (tileList) stays maintained for autowalk; ESP just
        -- pulls a window via the spatial grid.
        local origin0 = myPos()
        local scanR   = espScanRadius
        if tileSize then scanR = math.max(scanR, 15 * tileSize) end
        local all = _nearbyTiles(origin0, scanR)
        local state = {}
        local cov, rev, flg = 0, 0, 0
        for _, t in ipairs(all) do
            local s = tileStateCached(t)
            state[t] = s
            if     s == "covered"  then cov = cov + 1
            elseif s == "revealed" then rev = rev + 1
            elseif s == "flagged"  then flg = flg + 1 end
        end
        local sig = cov * 1e6 + rev * 1000 + flg
        local mines, safes, falseFlags
        local probs
        if _lastSig == sig and _lastResult then
            mines, safes, falseFlags, probs = _lastResult[1], _lastResult[2], _lastResult[3], _lastResult[4]
        else
            -- _deduceImpl: skip the global cache so ESP's culled
            -- subset doesn't thrash the autoplay-shared cache.
            -- ESP keeps its own outer sig cache (_lastSig / _lastResult).
            local ok, m, s2, ff, pr = pcall(_deduceImpl, all, state)
            if not ok then
                warn("[BMS] deduce error:", m)
                mines, safes, falseFlags, probs = {}, {}, {}, {}
            else
                mines, safes, falseFlags, probs = m, s2, ff, pr or {}
            end
            _lastSig    = sig
            _lastResult = { mines, safes, falseFlags, probs }
        end
        -- prune dead surfaces: tiles destroyed between ticks leave
        -- orphan SurfaceGui entries in the table. Iterating thousands
        -- of those per tick would stall ESP late game.
        for tile, sg in pairs(surfaces) do
            if not tile.Parent or not sg.Parent then
                pcall(function() sg:Destroy() end)
                surfaces[tile] = nil
            end
        end
        -- only highlight within range of player
        local origin  = myPos()
        local rangeSq = espRange * espRange
        local seen = {}
        for t in pairs(mines) do
            if inRange(t, origin, rangeSq) then
                seen[t] = true
                setColor(t, MINE_COLOR)
            end
        end
        if espShowSafes then
            for t in pairs(safes) do
                if inRange(t, origin, rangeSq) then
                    seen[t] = true
                    setColor(t, SAFE_COLOR)
                end
            end
        end
        if espShowWarnings then
            for t in pairs(falseFlags) do
                if inRange(t, origin, rangeSq) then
                    seen[t] = true
                    setColor(t, WARN_COLOR)
                end
            end
        end
        -- 50/50 tiles: probability in [0.4, 0.6]. Tank solver only fills
        -- probs for tiles in small connected components (<=14 unknowns).
        if espShowFifties and probs then
            for t, p in pairs(probs) do
                if p >= 0.4 and p <= 0.6 and inRange(t, origin, rangeSq) then
                    -- don't overpaint if already marked (mine/safe/warn win)
                    if not seen[t] then
                        seen[t] = true
                        setColor(t, FIFTY_COLOR)
                    end
                end
            end
        end
        -- Heatmap: paint every uncertain covered tile by its mine prob
        -- (0% green -> 50% yellow -> 100% red). Tank solver only knows
        -- prob for tiles in small (<=14 unknowns) connected components;
        -- larger components don't get heatmapped. Definitely-mine and
        -- definitely-safe tiles are NOT in probs (deduce prunes them)
        -- so they keep their solid red/green from above.
        if espHeatmap and probs then
            for t, p in pairs(probs) do
                if not seen[t] and inRange(t, origin, rangeSq) then
                    seen[t] = true
                    setColor(t, probToColor(p))
                end
            end
        end
        -- Hide surfaces that were visible last tick but aren't now.
        -- Iterating ALL surfaces (could be 5000+ in infinite mode)
        -- just to flip Enabled=false was a steady CPU cost; tracking
        -- the previous-tick visible set scales with the scan window.
        if _espLastSeen then
            for tile in pairs(_espLastSeen) do
                if not seen[tile] then
                    local sg = surfaces[tile]
                    if sg then sg.Enabled = false end
                end
            end
        end
        _espLastSeen = seen
    end

    local function espStart()
        if espActive then return end
        espActive = true
        if espThread then pcall(task.cancel, espThread) end
        espThread = task.spawn(function()
            while espActive do
                pcall(espTick)
                task.wait(0.1)  -- 10 Hz - smoother than the old 2 Hz
            end
        end)
    end

    local function espStop()
        espActive = false
        if espThread then pcall(task.cancel, espThread); espThread = nil end
        clearAllHl()
    end

    -- ---- legit auto-flag (queued, one at a time) ----
    local flagActive    = false
    local flagDelayMin  = 0.6
    local flagDelayMax  = 1.4
    local flagMissChance = 0   -- 0..100 percent
    local flagRange     = 60
    local flagThread
    -- module-scope so the setters can RESET it. Setting a new delay
    -- value now takes effect immediately instead of waiting for the
    -- OLD cooldown to elapse first.
    local lastFlagAt = 0

    local function flagDelayRoll()
        if flagDelayMin >= flagDelayMax then return flagDelayMin end
        return flagDelayMin + math.random() * (flagDelayMax - flagDelayMin)
    end
    local function flagMissRoll()
        return flagMissChance > 0 and (math.random() * 100 < flagMissChance)
    end
    -- aim-cone filter: only flag tiles within a half-angle from camera
    -- forward. Used by both legit auto-flag and auto-play's flag step.
    local flagAimCone     = false
    local flagAimHalfDeg  = 30
    -- (chain-flag logic removed in v1.13.2 - pick always uses player pos)

    local function inAimCone(tile)
        if not flagAimCone then return true end
        local cam = workspace.CurrentCamera
        if not cam then return true end
        local toTile = tile.Position - cam.CFrame.Position
        if toTile.Magnitude < 0.01 then return true end
        local dot = cam.CFrame.LookVector:Dot(toTile.Unit)
        return dot >= math.cos(math.rad(flagAimHalfDeg))
    end

    -- ============================================================
    -- VISUALIZERS - scan-radius cylinder + aim-cone wedge
    -- ============================================================
    -- Both are independently toggleable + colorable. They share a
    -- single Heartbeat thread that's only spun up while at least one
    -- viz is enabled; toggling all of them off lets the thread exit.
    local scanVizOn        = false
    local scanVizColor     = Color3.fromRGB(0, 200, 255)
    local aimConeVizOn     = false
    local aimConeVizColor  = Color3.fromRGB(255, 150, 0)

    local _scanVizPart, _aimConePart, _aimConeAdorn
    local _vizThread

    -- Clean up any stale viz parts from a previous script run.
    for _, p in ipairs(workspace:GetChildren()) do
        if p.Name == "_BMS_ScanViz" or p.Name == "_BMS_AimConeViz" then
            pcall(function() p:Destroy() end)
        end
    end

    local function _killScanViz()
        if _scanVizPart then
            pcall(function() _scanVizPart:Destroy() end)
            _scanVizPart = nil
        end
    end
    local function _killAimViz()
        if _aimConePart then
            pcall(function() _aimConePart:Destroy() end)
            _aimConePart  = nil
            _aimConeAdorn = nil
        end
    end

    local function _ensureScanViz()
        if _scanVizPart and _scanVizPart.Parent then return end
        local p = Instance.new("Part")
        p.Name         = "_BMS_ScanViz"
        p.Anchored     = true
        p.CanCollide   = false
        p.CanQuery     = false
        p.CanTouch     = false
        p.CastShadow   = false
        p.Material     = Enum.Material.ForceField
        p.Color        = scanVizColor
        p.Transparency = 0.7
        p.Shape        = Enum.PartType.Cylinder
        p.Parent       = workspace
        _scanVizPart   = p
    end

    local function _ensureAimViz()
        if _aimConePart and _aimConePart.Parent then return end
        local p = Instance.new("Part")
        p.Name         = "_BMS_AimConeViz"
        p.Anchored     = true
        p.CanCollide   = false
        p.CanQuery     = false
        p.CanTouch     = false
        p.Transparency = 1
        p.Size         = Vector3.new(0.1, 0.1, 0.1)
        p.Parent       = workspace
        local adorn = Instance.new("ConeHandleAdornment")
        adorn.Adornee      = p
        adorn.AlwaysOnTop  = true
        adorn.ZIndex       = 1
        adorn.Color3       = aimConeVizColor
        adorn.Transparency = 0.55
        adorn.Parent       = p
        _aimConePart  = p
        _aimConeAdorn = adorn
    end

    local function _vizUpdate()
        -- Scan radius: only render while ESP is on (the scan radius
        -- IS the ESP scan window). Disable visual without nuking
        -- toggle state if ESP turned itself off.
        if scanVizOn and espActive then
            _ensureScanViz()
            local r = espScanRadius
            if tileSize then r = math.max(r, 15 * tileSize) end
            local pos = myPos()
            -- Cylinder PartType's long axis is X. Rotate 90deg around
            -- Z so the flat circular faces are top/bottom. Diameter on
            -- the Y/Z axes = 2*r.
            _scanVizPart.Color  = scanVizColor
            _scanVizPart.Size   = Vector3.new(0.2, r * 2, r * 2)
            _scanVizPart.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z)
                * CFrame.Angles(0, 0, math.rad(90))
        else
            _killScanViz()
        end

        -- Aim cone: only render while the aim-cone filter is actually
        -- active (otherwise it's misleading - the cone wouldn't be
        -- doing anything).
        if aimConeVizOn and flagAimCone then
            _ensureAimViz()
            local cam = workspace.CurrentCamera
            if cam then
                local len     = 50
                local halfRad = math.rad(flagAimHalfDeg)
                _aimConeAdorn.Color3 = aimConeVizColor
                _aimConeAdorn.Height = len
                _aimConeAdorn.Radius = math.tan(halfRad) * len
                -- Orient adornee so its +Y axis points along the
                -- camera's look vector (ConeHandleAdornment draws
                -- along the adornee's +Y).
                local look = cam.CFrame.LookVector
                local right = look:Cross(Vector3.new(0, 1, 0))
                if right.Magnitude < 0.001 then right = Vector3.new(1, 0, 0) end
                _aimConePart.CFrame = CFrame.fromMatrix(
                    cam.CFrame.Position, right.Unit, look
                )
            end
        else
            _killAimViz()
        end
    end

    local function _vizStart()
        if _vizThread then return end
        _vizThread = task.spawn(function()
            while scanVizOn or aimConeVizOn do
                pcall(_vizUpdate)
                RunService.Heartbeat:Wait()
            end
            _vizThread = nil
            _killScanViz()
            _killAimViz()
        end)
    end

    local function setScanRadiusViz(v)
        scanVizOn = v == true
        if scanVizOn then _vizStart() else _killScanViz() end
    end
    local function setScanRadiusColor(c)
        if typeof(c) == "Color3" then
            scanVizColor = c
            if _scanVizPart then _scanVizPart.Color = c end
        end
    end
    local function setAimConeViz(v)
        aimConeVizOn = v == true
        if aimConeVizOn then _vizStart() else _killAimViz() end
    end
    local function setAimConeColor(c)
        if typeof(c) == "Color3" then
            aimConeVizColor = c
            if _aimConeAdorn then _aimConeAdorn.Color3 = c end
        end
    end

    -- ---- screenshare stealth ----
    -- Visual hardening for the legit auto-flag thread and the auto-
    -- play flag step. None of this changes the underlying deduction;
    -- it only makes the bot's fires look like a person to anyone
    -- watching the screenshare:
    --   * OS-level cursor follows tiles before flags are placed
    --   * randomised reaction-time pause before each fire
    --   * optional 'hover, second-guess, skip' fakeouts so flag
    --     timing isn't perfectly uniform
    --
    -- We use the executor-provided mousemoveabs / mouse_moveabs
    -- syscall (which moves the actual OS cursor) so the viewer on
    -- the other side of the screenshare actually sees the pointer
    -- travel. VirtualInputManager:SendMouseMoveEvent would move only
    -- the in-game mouse - invisible to a spectator - so we don't
    -- use it. If the executor exposes no cursor API, cursor sim is
    -- a no-op and reaction-time / hesitation still apply.
    local _stealthMoveCursor = (function()
        local g = (getgenv and getgenv()) or _G
        return rawget(g, "mousemoveabs") or rawget(g, "mouse_moveabs")
            or rawget(_G, "mousemoveabs") or rawget(_G, "mouse_moveabs")
    end)()

    -- All stealth state consolidated into one table to stay under
    -- Luau's 200 locals-per-function limit. The BMS IIFE was hitting
    -- it after the magnet + triggerbot were added; bundling these
    -- 30+ values into one local got us back under.
    --
    -- Field roles:
    --   cursorOn          - master toggle for cursor sim
    --   reactMs / Jitter  - reaction-time pause before each fire (ms)
    --   hesitatePct       - 0-100% chance to hover-and-skip a fire
    --   onScreenOnly      - filter flag candidates to viewport rect
    --   minSecBetween     - hard rate cap (seconds between fires)
    --   lastFireAt        - tick() of last fire, used by rate cap
    --   cursorSpeed       - px/sec, base sweep speed
    --   offsetMin/Max     - radial over/undershoot range (px)
    --   curveAmount       - 0..1, Bezier perpendicular magnitude
    --   speedVariance     - 0..1, per-sweep speed multiplier range
    --   magnetOn / Range  - only fire on tiles near cursor (px)
    --   triggerbotOn/Range- auto-fire when cursor is over a mine
    --   triggerThread     - bg thread driving the triggerbot
    --   rmbHeld           - RMB-pan gate; set by UIS listeners
    --   target            - current cursor tracker target tile
    --   trackerThread     - bg thread driving the cursor sweep
    --   lastTrackerTick   - dt source for the tracker
    --   writeX/Y          - tracked cursor pos (not polled)
    --   offX/Y            - per-target landing offset, rolled fresh
    --   sweep*            - Bezier sweep bake (start/control/dur/t)
    local _st = {
        cursorOn        = false,
        reactMs         = 350,
        reactJitter     = 250,
        hesitatePct     = 0,
        onScreenOnly    = false,
        minSecBetween   = 0,
        lastFireAt      = 0,
        cursorSpeed     = 600,
        offsetMin       = 5,
        offsetMax       = 15,
        curveAmount     = 0.35,
        speedVariance   = 0.45,
        magnetOn        = false,
        magnetRange     = 80,
        magnetThread    = nil,
        triggerbotOn    = false,
        triggerRange    = 12,
        triggerThread   = nil,
        rmbHeld         = false,
        target          = nil,
        trackerThread   = nil,
        lastTrackerTick = 0,
        writeX          = nil,
        writeY          = nil,
        offX            = 0,
        offY            = 0,
        sweepActive     = false,
        sweepStartX     = 0,
        sweepStartY     = 0,
        sweepC1X        = 0,
        sweepC1Y        = 0,
        sweepC2X        = 0,
        sweepC2Y        = 0,
        sweepStartTime  = 0,
        sweepDuration   = 0,
    }
    do
        local UIS = game:GetService("UserInputService")
        UIS.InputBegan:Connect(function(input, gp)
            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                _st.rmbHeld = true
            end
        end)
        UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                _st.rmbHeld = false
            end
        end)
    end

    -- Read the user's cursor position in viewport coords. Used by
    -- the magnet filter (find tiles near cursor) and the
    -- triggerbot loop (fire when cursor is over a deduced mine).
    -- GetMouseLocation is fine for reading; only the write side
    -- (mousemoveabs) suffers the GUI-inset disagreement.
    local function _cursorViewportXY()
        local UIS = game:GetService("UserInputService")
        local m   = UIS:GetMouseLocation()
        return m.X, m.Y
    end

    -- Continuous cursor tracker. Replaces the old sweep-on-demand
    -- model where preFlagSequence called _smoothMoveCursor[ToTile]
    -- once and then left the cursor frozen until the next fire. That
    -- produced a 'stutter' on screenshare: cursor sweeps to tile A,
    -- sits still while the player walks (tile A is sliding on
    -- screen), next sequence sweeps from old cursor pos to tile A's
    -- NEW position, repeat.
    --
    -- New model: a single background thread owns the cursor. It
    -- consults _st.target every frame:
    --   * no target          -> do nothing, cursor sits wherever
    --   * RMB held           -> do nothing (don't fight camera pan)
    --   * target off-screen  -> do nothing, cursor sits wherever
    --   * target on-screen   -> move cursor toward target's CURRENT
    --                           viewport position with a constant-
    --                           speed approach that eases out for
    --                           the last 30px, then locks on. Once
    --                           locked, dist stays ~0 each frame
    --                           and the cursor moves only when the
    --                           tile does (i.e. as the player walks).
    -- preFlagSequence just calls _setCursorTarget(tile) + waits for
    -- the cursor to be within ~5px of the target. After firing, the
    -- target stays set so the cursor keeps tracking that tile until
    -- the bot picks a NEW one - exactly what 'stay on the tile until
    -- it moves away' asks for.
    -- (target/tracker/cursor/sweep state lives in _st declared above)

    local function _beginSweep()
        _st.sweepActive = false
        if not _st.target then return end
        local cam = workspace.CurrentCamera
        if not cam then return end
        local sp, on = cam:WorldToViewportPoint(_st.target.Position)
        if not on then return end

        -- Source position: prefer our tracked _st.writeX/_st.writeY if
        -- we have one, else resync from the OS cursor.
        local sx, sy
        if _st.writeX then
            sx, sy = _st.writeX, _st.writeY
        else
            local UIS = game:GetService("UserInputService")
            local m   = UIS:GetMouseLocation()
            sx, sy   = m.X, m.Y
            _st.writeX, _st.writeY = sx, sy
        end

        local ex = sp.X + _st.offX
        local ey = sp.Y + _st.offY
        local dx, dy = ex - sx, ey - sy
        local dist   = math.sqrt(dx * dx + dy * dy)
        if dist < 4 then return end   -- already close; let lock-on handle it

        -- Per-sweep speed multiplier in [1 - v, 1 + v]. Inverted
        -- into the duration so higher multiplier = faster sweep.
        local v = math.clamp(_st.speedVariance, 0, 1)
        local mult = 1 + (math.random() * 2 - 1) * v
        mult = math.max(0.25, mult)
        local rawDur = dist / math.max(50, _st.cursorSpeed)
        _st.sweepDuration  = math.clamp(rawDur / mult, 0.10, 2.0)
        _st.sweepStartTime = tick()
        _st.sweepStartX, _st.sweepStartY = sx, sy

        -- Bezier control points 1/3 and 2/3 along the line, each
        -- pushed perpendicular by a random distance scaled by the
        -- user's curve amount. Independent magnitudes give natural
        -- S-curves rather than always-symmetric bows.
        local invDist = 1 / dist
        local perpX, perpY = -dy * invDist, dx * invDist
        local curve = math.clamp(_st.curveAmount, 0, 2)
        local m1 = (math.random() - 0.5) * dist * 0.4 * curve
        local m2 = (math.random() - 0.5) * dist * 0.4 * curve
        _st.sweepC1X = sx + dx * 0.33 + perpX * m1
        _st.sweepC1Y = sy + dy * 0.33 + perpY * m1
        _st.sweepC2X = sx + dx * 0.67 + perpX * m2
        _st.sweepC2Y = sy + dy * 0.67 + perpY * m2
        _st.sweepActive = true
    end

    local function _setCursorTarget(tile)
        _st.target = tile
        -- resync source pos so the sweep starts from wherever the
        -- cursor actually is
        _st.writeX, _st.writeY = nil, nil
        -- roll a fresh radial landing offset
        local lo = math.max(0, _st.offsetMin)
        local hi = math.max(lo, _st.offsetMax)
        local d  = lo + math.random() * (hi - lo)
        local a  = math.random() * math.pi * 2
        _st.offX = math.cos(a) * d
        _st.offY = math.sin(a) * d
        -- bake the Bezier sweep
        _beginSweep()
    end

    local function _clearCursorTarget()
        _st.target = nil
        _st.writeX, _st.writeY = nil, nil
        _st.sweepActive = false
    end

    local function _trackerStep(dt)
        if not _stealthMoveCursor then return end
        if _st.rmbHeld then
            _st.writeX, _st.writeY = nil, nil
            _st.sweepActive = false
            return
        end
        local target = _st.target
        if not target then return end
        local cam = workspace.CurrentCamera
        if not cam then return end
        local sp, on = cam:WorldToViewportPoint(target.Position)
        if not on then return end

        local aimX = sp.X + _st.offX
        local aimY = sp.Y + _st.offY

        -- Phase 1: Bezier sweep. Active until elapsed >= duration.
        -- Position along the Bezier uses smoothstep on raw t for
        -- ease-in-out (slow start, accelerate through middle, slow
        -- end) instead of constant velocity. End-point is read each
        -- frame from the tile's CURRENT screen pos so if the player
        -- is walking the curve smoothly re-aims toward where the
        -- tile ended up.
        if _st.sweepActive then
            local elapsed = tick() - _st.sweepStartTime
            local rawT    = elapsed / _st.sweepDuration
            if rawT >= 1 then
                _st.sweepActive = false
                -- fall through into lock-on phase below
            else
                local te  = rawT * rawT * (3 - 2 * rawT)  -- smoothstep
                local omt = 1 - te
                local b0  = omt * omt * omt
                local b1  = 3 * omt * omt * te
                local b2  = 3 * omt * te * te
                local b3  = te * te * te
                local px = b0 * _st.sweepStartX + b1 * _st.sweepC1X
                         + b2 * _st.sweepC2X     + b3 * aimX
                local py = b0 * _st.sweepStartY + b1 * _st.sweepC1Y
                         + b2 * _st.sweepC2Y     + b3 * aimY
                pcall(_stealthMoveCursor, math.floor(px), math.floor(py))
                _st.writeX, _st.writeY = px, py
                return
            end
        end

        -- Phase 2: lock-on / passive follow. Used after the sweep
        -- completes and for correction sweeps (small offset shrink
        -- before fire). Constant speed with ease-out within 30px
        -- so the cursor doesn't overshoot the lock point.
        if not _st.writeX then
            local UIS = game:GetService("UserInputService")
            local m   = UIS:GetMouseLocation()
            _st.writeX, _st.writeY = m.X, m.Y
        end
        local dx, dy = aimX - _st.writeX, aimY - _st.writeY
        local dist   = math.sqrt(dx * dx + dy * dy)
        if dist < 1 then return end
        local easeFactor = math.min(1, dist / 30)
        local frameMove  = _st.cursorSpeed * easeFactor * dt
        local alpha      = math.min(1, frameMove / dist)
        local nx = _st.writeX + dx * alpha
        local ny = _st.writeY + dy * alpha
        pcall(_stealthMoveCursor, math.floor(nx), math.floor(ny))
        _st.writeX, _st.writeY = nx, ny
    end

    local function _stopTracker()
        -- Loop exits on its own when _st.cursorOn flips false.
        _st.target = nil
    end

    local function _startTracker()
        if _st.trackerThread then return end
        if not (_st.cursorOn and _stealthMoveCursor) then return end
        _st.lastTrackerTick = tick()
        _st.trackerThread = task.spawn(function()
            while _st.cursorOn do
                local now = tick()
                local dt  = math.max(0.001, math.min(0.1, now - _st.lastTrackerTick))
                _st.lastTrackerTick = now
                _trackerStep(dt)
                task.wait()
            end
            _st.trackerThread = nil
            _st.target = nil
        end)
    end

    -- Wait for the cursor to arrive on tile (or near enough). Used
    -- by preFlagSequence after setting the target, so the FireServer
    -- call only happens once the cursor is actually on the tile -
    -- otherwise a viewer would see the flag appear before the
    -- cursor reaches it. Compares against _st.writeX/_st.writeY (our own
    -- tracked cursor pos) instead of GetMouseLocation, same reason
    -- as _trackerStep: the two APIs disagree about GUI inset.
    local function _waitForCursorOnTile(tile, timeoutSec)
        local cam = workspace.CurrentCamera
        if not cam then return end
        local deadline = tick() + (timeoutSec or 1.5)
        while tick() < deadline do
            if _st.rmbHeld then return false end
            local sp, on = cam:WorldToViewportPoint(tile.Position)
            if not on then return false end
            if _st.writeX then
                -- compare against the off-centre landing point, not
                -- the tile centre, so the wait completes when the
                -- cursor reaches WHERE WE'RE AIMING.
                local dx = (sp.X + _st.offX) - _st.writeX
                local dy = (sp.Y + _st.offY) - _st.writeY
                if dx * dx + dy * dy < 36 then return true end  -- within 6px
            end
            task.wait()
        end
        return false
    end

    -- Returns true if the tile is allowed by the on-screen-only
    -- filter (or the filter is off, in which case every tile is
    -- allowed). Used by both legitFlag and auto-play to prune flag
    -- candidates BEFORE the closest-tile selection, so we never
    -- pick an off-screen tile and then try to flag it.
    local function isTileOnScreen(tile)
        if not _st.onScreenOnly then return true end
        if not tile then return false end
        local cam = workspace.CurrentCamera
        if not cam then return true end
        local sp, on = cam:WorldToViewportPoint(tile.Position)
        if not on then return false end
        local v = cam.ViewportSize
        -- small inset (16 px) so tiles half-clipped at the edge of
        -- the screen still don't qualify - a real player wouldn't
        -- flag a tile whose icon is half off-screen
        return sp.X >= 16 and sp.X <= (v.X - 16)
           and sp.Y >= 16 and sp.Y <= (v.Y - 16)
    end

    local function _reactionDelay()
        local lo = math.max(0, (_st.reactMs - _st.reactJitter) / 1000)
        local hi = math.max(lo, (_st.reactMs + _st.reactJitter) / 1000)
        return lo + math.random() * (hi - lo)
    end

    -- preFlagSequence: caller should call this RIGHT before firing
    -- the PlaceFlag remote. Returns true if a hesitation rolled and
    -- the caller should skip this fire (re-deduce next tick); returns
    -- false if the caller should go ahead and fire normally.
    --
    -- Sequence (v3 - hesitate BEFORE moving):
    --   1. wait out the rate cap if we fired too recently
    --   2. reaction delay (humans don't snap-react)
    --   3. hesitation roll - decided BEFORE we touch the cursor.
    --      If we're going to skip, just wait a beat in place and
    --      return - never move the cursor for a tile we won't
    --      flag. (The old order moved-then-hesitated, which made
    --      the cursor sweep to a tile and then nothing happen -
    --      a dead giveaway on screenshare.)
    --   4. cursor sweep to the tile (committed to firing now)
    --   5. return false; caller fires the remote.
    local function preFlagSequence(tile, opts)
        if not tile then return false end
        opts = opts or {}
        -- bypass: caller wants the entire stealth layer skipped -
        -- no rate cap, no reaction-time wait, no hesitation roll,
        -- no cursor sweep. Used by auto-play, whose own walk-step
        -- needs the autoplay tick to return promptly so the
        -- character keeps moving. Auto-play also has its own
        -- separate flagDelayMin/Max cooldown and miss-roll, so
        -- it doesn't need the stealth pacing on top.
        if opts.bypass then
            if _st.rmbHeld then return true end
            return false
        end
        -- RMB gate: while the player is panning camera with RMB-hold,
        -- skip the fire entirely. Old behaviour was to skip just the
        -- cursor sweep but still fire, which made flags pop onto
        -- tiles the cursor wasn't even near - the exact giveaway
        -- the cursor sim is supposed to prevent.
        if _st.rmbHeld then return true end
        -- Cursor sim OFF -> fire immediately: no rate cap, reaction delay,
        -- hesitation or cursor sweep. This keeps the auto-flag fast by default;
        -- the human pacing below only kicks in once cursor sim is enabled.
        if not _st.cursorOn then
            _st.lastFireAt = tick()
            return false
        end
        if _st.minSecBetween > 0 then
            local elapsed = tick() - _st.lastFireAt
            if elapsed < _st.minSecBetween then
                task.wait(_st.minSecBetween - elapsed)
            end
        end
        task.wait(_reactionDelay())
        if _st.rmbHeld then return true end  -- re-check after the wait
        -- Hesitate FIRST. No cursor commitment until we've decided
        -- we're actually going to flag this tile.
        if _st.hesitatePct > 0
           and math.random(1, 100) <= _st.hesitatePct then
            task.wait(0.20 + math.random() * 0.40)  -- 0.2-0.6s pause
            return true   -- caller: skip this fire
        end
        -- Committed. Three-phase cursor sequence:
        --   1. Sweep cursor to the over/under-shoot landing offset.
        --   2. Pause 50-150ms so the overshoot is visible.
        --   3. Correct: shrink offset to ~30% (so a small adjustment
        --      pulls cursor closer to centre) and wait again. This
        --      mimics a human click sequence - rough approach, fine
        --      correction, click - instead of a single dead-on
        --      landing.
        -- Only runs when stealth cursor sim is on; otherwise the
        -- caller fires immediately with no cursor movement.
        if _st.cursorOn and _stealthMoveCursor then
            _setCursorTarget(tile)
            local arrived = _waitForCursorOnTile(tile, 1.5)
            if _st.rmbHeld then return true end
            if arrived and (_st.offsetMax > 0 or _st.offsetMin > 0) then
                -- visible-pause + correction
                task.wait(0.05 + math.random() * 0.10)
                if _st.rmbHeld then return true end
                _st.offX = _st.offX * 0.3
                _st.offY = _st.offY * 0.3
                _waitForCursorOnTile(tile, 0.5)
                if _st.rmbHeld then return true end
            end
            -- Release cursor right before the caller fires. Tracker
            -- stops driving it; cursor stays where it landed. Next
            -- preFlagSequence sets a new target and the cycle repeats.
            _clearCursorTarget()
        end
        _st.lastFireAt = tick()
        return false
    end

    local function legitFlagStart()
        if flagActive then return end
        flagActive = true
        if flagThread then pcall(task.cancel, flagThread) end
        flagThread = task.spawn(function()
            while flagActive do
                -- Playstyle applies to the standalone auto-flag too,
                -- not just auto-play:
                --   'logical' -> longer 'studying the board' beat
                --                between fires + a wider idle pause
                --                so flags don't snap-chain like a bot.
                --   'legit'   -> existing flagDelayRoll() / 0.25s idle.
                local token = getgenv()._BMS_TOKEN
                local remote = getPlaceFlag()
                if not token or not remote then
                    task.wait(0.5); continue
                end
                local parts = getParts()
                if not parts then task.wait(0.5); continue end
                ensureNeighbors(tileList)
                local all = tileList
                local state = {}
                for _, t in ipairs(all) do state[t] = tileStateCached(t) end
                local mines = deduce(all, state)
                -- pick the closest unflagged deduced mine within range
                local origin  = myPos()
                local rangeSq = flagRange * flagRange
                -- Pick the unflagged deduced mine closest to the PLAYER
                -- (within range + aim cone). Simple + predictable - no
                -- last-flagged chaining.
                local best, bestD2 = nil, math.huge
                for t in pairs(mines) do
                    if state[t] ~= "flagged"
                       and inAimCone(t)
                       and isTileOnScreen(t) then
                        local dx = t.Position.X - origin.X
                        local dy = t.Position.Y - origin.Y
                        local dz = t.Position.Z - origin.Z
                        local d2 = dx*dx + dy*dy + dz*dz
                        if d2 < rangeSq and d2 < bestD2 then
                            best, bestD2 = t, d2
                        end
                    end
                end
                if best then
                    if playstyleMode == "logical" then
                        -- logical: flag, then a long 'reading the board' beat
                        if not flagMissRoll() then
                            local skip = preFlagSequence(best)
                            if not skip then
                                pcall(function() remote:FireServer(best, token, true) end)
                            end
                        end
                        lastFlagAt = tick()
                        task.wait(0.8 + math.random() * 0.8)
                    else
                        -- legit: the delay is the MINIMUM gap BETWEEN flags. Wait
                        -- only the remainder of the gap since the last flag - so a
                        -- freshly uncovered bomb is flagged the moment the spacing
                        -- allows, instead of every detection eating a full delay.
                        local gap   = flagDelayRoll()
                        local since = tick() - lastFlagAt
                        if since < gap then task.wait(gap - since) end
                        if not flagActive then break end
                        if not flagMissRoll() then
                            local skip = preFlagSequence(best)
                            if not skip then
                                pcall(function() remote:FireServer(best, token, true) end)
                            end
                        end
                        lastFlagAt = tick()
                    end
                else
                    if playstyleMode == "logical" then
                        task.wait(0.4 + math.random() * 0.5)  -- 0.4-0.9s
                    else
                        task.wait(0.05)  -- idle: poll fast so new bombs get caught promptly
                    end
                end
            end
        end)
    end

    local function legitFlagStop()
        flagActive = false
        if flagThread then pcall(task.cancel, flagThread); flagThread = nil end
        -- Release the cursor: tracker would otherwise keep the cursor
        -- pinned to whichever tile was last targeted, even after the
        -- flag thread is gone.
        _clearCursorTarget()
    end

    -- ---- flag magnet ----
    -- Standalone: works without legitFlag and without cursor sim.
    -- When the user's cursor is within _st.magnetRange px of a
    -- deduced unflagged mine, runs its OWN quick smooth-sweep
    -- (ease-out over ~6 frames, re-targets each frame so a moving
    -- tile is still hit) and fires PlaceFlag. If the executor
    -- doesn't expose mousemoveabs, falls back to firing without
    -- moving the cursor.
    local function _stopMagnet() end
    local function _startMagnet()
        if _st.magnetThread then return end
        _st.magnetThread = task.spawn(function()
            local lastDeduce = 0
            local mineCache  = nil
            local lastFireAt = 0
            while _st.magnetOn do
                if _st.rmbHeld or tick() - lastFireAt < 0.3 then
                    task.wait(); continue
                end
                local now = tick()
                if now - lastDeduce >= 0.15 then
                    lastDeduce = now
                    local parts = getParts()
                    if parts then
                        ensureNeighbors(tileList)
                        local all   = tileList
                        local state = {}
                        for _, t in ipairs(all) do state[t] = tileStateCached(t) end
                        mineCache = deduce(all, state)
                    end
                end
                local token  = getgenv()._BMS_TOKEN
                local remote = getPlaceFlag()
                local cam    = workspace.CurrentCamera
                if cam and token and remote and mineCache then
                    local cmx, cmy = _cursorViewportXY()
                    local mr2 = _st.magnetRange * _st.magnetRange
                    local best, bestD2 = nil, math.huge
                    for t in pairs(mineCache) do
                        if tileStateCached(t) ~= "flagged" then
                            local sp, on = cam:WorldToViewportPoint(t.Position)
                            if on then
                                local dx = sp.X - cmx
                                local dy = sp.Y - cmy
                                local d2 = dx*dx + dy*dy
                                if d2 <= mr2 and d2 < bestD2 then
                                    best, bestD2 = t, d2
                                end
                            end
                        end
                    end
                    if best then
                        if _stealthMoveCursor then
                            local sx, sy = cmx, cmy
                            local steps = 6
                            for i = 1, steps do
                                if _st.rmbHeld or not _st.magnetOn then break end
                                local sp = cam:WorldToViewportPoint(best.Position)
                                local te = 1 - (1 - i / steps) ^ 2
                                local nx = sx + (sp.X - sx) * te
                                local ny = sy + (sp.Y - sy) * te
                                pcall(_stealthMoveCursor,
                                    math.floor(nx), math.floor(ny))
                                task.wait()
                            end
                        end
                        if not _st.rmbHeld and _st.magnetOn then
                            pcall(function()
                                remote:FireServer(best, token, true)
                            end)
                            lastFireAt = tick()
                        end
                    end
                end
                task.wait()
            end
            _st.magnetThread = nil
        end)
    end

    -- ---- triggerbot ----
    -- Independent of legitFlag: fires PlaceFlag the instant the
    -- user's cursor is within _st.triggerRange px of a deduced
    -- unflagged mine. No cursor sweep, no reaction delay - the
    -- user moves the cursor manually, bot just pulls the trigger.
    -- Deduce cache refreshes every ~150ms to keep CPU in check;
    -- cursor-vs-tile distance check runs every frame.
    local function _stopTriggerbot()
        -- thread exits on its own when the flag goes false
    end

    local function _startTriggerbot()
        if _st.triggerThread then return end
        _st.triggerThread = task.spawn(function()
            local lastDeduce = 0
            local mineCache  = nil
            while _st.triggerbotOn do
                if _st.rmbHeld then
                    task.wait(); continue
                end
                local now = tick()
                if now - lastDeduce >= 0.15 then
                    lastDeduce = now
                    local parts = getParts()
                    if parts then
                        ensureNeighbors(tileList)
                        local all   = tileList
                        local state = {}
                        for _, t in ipairs(all) do state[t] = tileStateCached(t) end
                        mineCache = deduce(all, state)
                    end
                end
                local token  = getgenv()._BMS_TOKEN
                local remote = getPlaceFlag()
                local cam    = workspace.CurrentCamera
                if cam and token and remote and mineCache then
                    local cmx, cmy = _cursorViewportXY()
                    local tr2 = _st.triggerRange * _st.triggerRange
                    for t in pairs(mineCache) do
                        if tileStateCached(t) ~= "flagged" then
                            local sp, on = cam:WorldToViewportPoint(t.Position)
                            if on then
                                local dx = sp.X - cmx
                                local dy = sp.Y - cmy
                                if dx * dx + dy * dy <= tr2 then
                                    pcall(function()
                                        remote:FireServer(t, token, true)
                                    end)
                                    -- short debounce so we don't
                                    -- re-fire on the same tile before
                                    -- the server marks it flagged
                                    task.wait(0.25)
                                    break
                                end
                            end
                        end
                    end
                end
                task.wait()
            end
            _st.triggerThread = nil
        end)
    end

    -- ---- auto-play (walk to safes + flag mines, never step on unknowns) ----
    --
    -- Loop:
    --   1. Deduce mines + safes.
    --   2. If there's an unflagged deduced mine within range, flag it
    --      (one at a time, respecting flagDelay).
    --   3. Otherwise pick the nearest deduced-safe tile that is REACHABLE
    --      via revealed/flagged tiles only (BFS through walkable
    --      neighbors), walk to its closest walkable neighbor, then step
    --      onto the safe tile.
    --   4. If neither flag nor walk has work, idle briefly.
    --
    -- Pathfinding is restricted: only tiles whose state is "revealed"
    -- or "flagged" AND not a deduced mine count as walkable. So we
    -- never accidentally step onto a covered/unknown tile en route.
    local autoActive = false
    local autoThread
    local autoStepDelay = 0.4   -- per-tile MoveTo cap
    local autoGuess     = false -- when stuck, walk to a 50/50 tile

    -- ---- walk feel ----
    -- walkSmoothness: how loose the per-tile reach radius is.
    --   0.0 = strict (~0.6 stud reach) - lands on every tile centre
    --   0.6 = mild  (~1.2 stud)        - small corner smoothing
    --   1.5 = loose (~2.1 stud)        - aggressive glide-through
    -- Larger values = the next MoveTo fires while character is still
    -- well in-motion, so the path looks rounded instead of stepwise.
    local walkSmoothness = 0.6
    -- walkLegit: when true, add small random lateral offsets to each
    -- tile's walk target so the bot doesn't hit every centre dead-on.
    -- Mimics human imprecision; less robotic-looking.
    local walkLegit       = true
    local walkLegitJitter = 0.6  -- max ±studs of XZ offset per step

    -- ---- playstyle + win/loss actions ----
    -- playstyleMode:
    --   'legit'    = current behaviour, no extra pacing
    --   'logical'  = small random delay after each flag fire so newly
    --                exposed bombs / numbers get acted on with a
    --                human-looking pause rather than an instant snap
    -- winAction / failAction: what the bot does once the board ends.
    --   'staying still', 'walking randomly', 'jumping in a circle',
    --   'jumping off map'.
    --
    -- gameOverState tracks the LAST detected end-state so the main
    -- autoplay loop can short-circuit while the action is running.
    -- A periodic detector thread scans tile colours every second:
    --   any tile R~1, G~0, B~0       -> loss (the bomb that killed you)
    --   any tile R~0, G~0.99, B~0    -> win  (all bombs revealed green)
    -- When detection transitions back to nil (new round started -
    -- tiles repainted), the action stops and autoplay resumes.
    local playstyleMode  = "legit"
    local winAction      = "staying still"
    local failAction     = "staying still"
    local respawnAction  = "stay still"   -- stay still | walk randomly | sit down
    local gameOverState  = nil
    local actionThread   = nil
    local detectorThread = nil
    local respawnActionThread, _respawnCharConn
    local _RED   = function(c) return c.R > 0.95 and c.G < 0.05 and c.B < 0.05 end
    local _GREEN = function(c) return c.R < 0.05 and c.G > 0.95 and c.B < 0.05 end

    -- ---- stats (persists across reloads) ----
    -- Incremented by the detector on every win/loss TRANSITION (not
    -- every tick the colours are set). Saved to a json file so the
    -- counts survive a script reload.
    local STATS_FILE = "decay_bms_stats.json"
    local stats      = { wins = 0, losses = 0 }
    do
        if isfile and isfile(STATS_FILE) then
            local ok, data = pcall(function()
                return game:GetService("HttpService"):JSONDecode(readfile(STATS_FILE))
            end)
            if ok and type(data) == "table" then
                stats.wins   = tonumber(data.wins)   or 0
                stats.losses = tonumber(data.losses) or 0
            end
        end
    end
    local function saveStats()
        pcall(function()
            writefile(STATS_FILE, game:GetService("HttpService"):JSONEncode(stats))
        end)
    end

    local statsGuiOn = false
    local _statsGui, _statsWinLbl, _statsLossLbl
    local function ensureStatsGui()
        if _statsGui and _statsGui.Parent then return _statsGui end
        local sg = Instance.new("ScreenGui")
        sg.Name           = "_decay_bms_stats"
        sg.IgnoreGuiInset = true
        sg.ResetOnSpawn   = false
        sg.DisplayOrder   = 1000
        sg.Parent         = (gethui and gethui()) or game:GetService("CoreGui")

        local frame = Instance.new("Frame")
        frame.Active                = true   -- decay: receive drag input
        frame.Size                  = UDim2.fromOffset(170, 72)
        frame.Position              = UDim2.fromOffset(10, 80)
        frame.BackgroundColor3      = Color3.fromRGB(20, 20, 22)
        frame.BackgroundTransparency = 0.25
        frame.BorderSizePixel       = 0
        frame.Parent                = sg
        local r = Instance.new("UICorner")
        r.CornerRadius = UDim.new(0, 6); r.Parent = frame
        local stroke = Instance.new("UIStroke")
        stroke.Thickness = 1
        stroke.Color     = Color3.fromRGB(60, 60, 70)
        stroke.Parent    = frame

        local title = Instance.new("TextLabel")
        title.BackgroundTransparency = 1
        title.Size      = UDim2.new(1, 0, 0, 20)
        title.Position  = UDim2.fromOffset(0, 4)
        title.Text      = "BMS Stats   (drag)"
        title.TextColor3 = Color3.fromRGB(200, 200, 210)
        title.Font      = Enum.Font.SourceSansBold
        title.TextSize  = 14
        title.Parent    = frame

        -- decay: draggable. Mouse/Touch down anywhere on the frame
        -- starts a drag; we listen to UIS.InputChanged for the move
        -- deltas + input.Changed for the up edge. Drag is anchored
        -- to the initial mouse-frame offset so the cursor stays at
        -- the grab point throughout the drag.
        do
            local UIS = game:GetService("UserInputService")
            local dragging, dragStart, startPos
            frame.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1
                   or input.UserInputType == Enum.UserInputType.Touch then
                    dragging  = true
                    dragStart = input.Position
                    startPos  = frame.Position
                    input.Changed:Connect(function()
                        if input.UserInputState == Enum.UserInputState.End then
                            dragging = false
                        end
                    end)
                end
            end)
            UIS.InputChanged:Connect(function(input)
                if dragging
                   and (input.UserInputType == Enum.UserInputType.MouseMovement
                        or input.UserInputType == Enum.UserInputType.Touch) then
                    local d = input.Position - dragStart
                    frame.Position = UDim2.new(
                        startPos.X.Scale, startPos.X.Offset + d.X,
                        startPos.Y.Scale, startPos.Y.Offset + d.Y)
                end
            end)
        end

        _statsWinLbl = Instance.new("TextLabel")
        _statsWinLbl.BackgroundTransparency = 1
        _statsWinLbl.Size      = UDim2.new(1, -10, 0, 18)
        _statsWinLbl.Position  = UDim2.fromOffset(8, 25)
        _statsWinLbl.Text      = "Wins:  0"
        _statsWinLbl.TextColor3 = Color3.fromRGB(0, 220, 80)
        _statsWinLbl.Font      = Enum.Font.SourceSans
        _statsWinLbl.TextSize  = 15
        _statsWinLbl.TextXAlignment = Enum.TextXAlignment.Left
        _statsWinLbl.Parent    = frame

        _statsLossLbl = Instance.new("TextLabel")
        _statsLossLbl.BackgroundTransparency = 1
        _statsLossLbl.Size      = UDim2.new(1, -10, 0, 18)
        _statsLossLbl.Position  = UDim2.fromOffset(8, 45)
        _statsLossLbl.Text      = "Losses: 0"
        _statsLossLbl.TextColor3 = Color3.fromRGB(220, 60, 60)
        _statsLossLbl.Font      = Enum.Font.SourceSans
        _statsLossLbl.TextSize  = 15
        _statsLossLbl.TextXAlignment = Enum.TextXAlignment.Left
        _statsLossLbl.Parent    = frame

        _statsGui = sg
        return sg
    end
    local function updateStatsGui()
        if not statsGuiOn or not _statsGui then return end
        if _statsWinLbl  then _statsWinLbl.Text  = "Wins:  " .. stats.wins   end
        if _statsLossLbl then _statsLossLbl.Text = "Losses: " .. stats.losses end
    end
    local function setStatsGui(v)
        statsGuiOn = v == true
        if statsGuiOn then
            ensureStatsGui(); updateStatsGui()
        else
            if _statsGui then pcall(function() _statsGui:Destroy() end) end
            _statsGui, _statsWinLbl, _statsLossLbl = nil, nil, nil
        end
    end
    local function resetStats()
        stats.wins   = 0
        stats.losses = 0
        saveStats(); updateStatsGui()
    end

    -- ---- path preview ----
    -- Glowing neon segments between consecutive tiles on the path the
    -- bot is about to walk. Parts are pooled (reused across ticks) so
    -- we don't churn Instance.new every iteration.
    local pathPreview      = false
    local pathPreviewColor = Color3.fromRGB(0, 200, 255)
    local pathSegments     = {}
    local function ensurePathSeg(i)
        local p = pathSegments[i]
        if p and p.Parent then return p end
        p = Instance.new("Part")
        p.Anchored     = true
        p.CanCollide   = false
        p.CanTouch     = false
        p.CanQuery     = false
        p.CastShadow   = false
        p.Material     = Enum.Material.Neon
        p.Color        = pathPreviewColor
        p.Size         = Vector3.new(0.25, 0.25, 0.25)
        p.Name         = "_BMS_path_seg"
        p.Parent       = workspace
        pathSegments[i] = p
        return p
    end
    local function hidePathSegments(startIdx)
        for i = startIdx or 1, #pathSegments do
            local p = pathSegments[i]
            if p then p.Transparency = 1 end
        end
    end
    local function clearPathPreview()
        for _, p in ipairs(pathSegments) do
            if p and p.Parent then pcall(function() p:Destroy() end) end
        end
        pathSegments = {}
    end
    local function drawPathPreview(tiles)
        if not pathPreview or not tiles or #tiles < 2 then
            hidePathSegments(); return
        end
        for i = 1, #tiles - 1 do
            local ta, tb = tiles[i], tiles[i + 1]
            if not ta or not tb or not ta.Parent or not tb.Parent then break end
            -- Lift the line ABOVE the tile top face. Without this the
            -- segment center sits inside the tile and the neon part is
            -- occluded by the floor mesh - which is exactly the
            -- 'path not visible' symptom.
            local lift = Vector3.new(0, ta.Size.Y * 0.5 + 0.6, 0)
            local a    = ta.Position + lift
            local b    = tb.Position + lift
            local mid  = (a + b) * 0.5
            local diff = b - a
            local len  = diff.Magnitude
            if len < 0.05 then continue end
            local seg  = ensurePathSeg(i)
            seg.Color        = pathPreviewColor
            seg.Size         = Vector3.new(0.4, 0.4, len)
            seg.CFrame       = CFrame.new(mid, b)
            seg.Transparency = 0
        end
        hidePathSegments(#tiles)  -- hide trailing pool entries
    end
    -- target-switch debounce: once the auto-play picks a tile to walk
    -- to, don't switch to a different target for this many seconds even
    -- if a closer safe appears. Prevents jittery target-flipping
    -- between candidate safes when deductions reshuffle mid-walk.
    local autoTargetDebounce = 0.2
    local _lastWalkTarget    = nil
    local _lastWalkTargetAt  = 0

    local function findCurrentTile(allParts, originPos)
        -- Pick the tile closest to player HRP on XZ.
        local best, bestD2 = nil, math.huge
        for _, t in ipairs(allParts) do
            local dx = t.Position.X - originPos.X
            local dz = t.Position.Z - originPos.Z
            local d2 = dx*dx + dz*dz
            if d2 < bestD2 then best, bestD2 = t, d2 end
        end
        return best
    end

    -- 8-direction BFS with two safety nets:
    --   1. Diagonal moves require BOTH corner tiles to be walkable
    --      (no corner-cutting across unknown tiles into a bomb).
    --      Corner tiles = the two tiles cardinal-adjacent to BOTH the
    --      current tile AND the diagonal neighbor.
    --   2. Walkable = revealed OR flagged (but NOT a deduced mine and
    --      NOT a deduced false-flag). Flagged tiles are now permitted
    --      in the path so the bot can step over a correctly-flagged
    --      mine instead of taking the long way around.
    --
    -- The goal tile (final step) is always a covered deduced-safe, so
    -- the walkability filter only applies to intermediate steps.
    local function bfsPath(startTile, goalTile, state, knownMines, knownFalse)
        knownFalse = knownFalse or {}
        if startTile == goalTile then return {} end

        -- Used for stepping ONTO a tile - flagged is OK because the
        -- flag protects you.
        local function isWalkable(t)
            local s = state[t]
            if s == "flagged"  then return true end
            if s == "revealed" then return not knownMines[t] end
            return false
        end
        -- Used for diagonal CORNER tiles - stricter than isWalkable.
        -- For a diagonal move A->D, the character physically grazes
        -- the corner tiles between them. We require corners to be
        -- FULLY REVEALED (not just flagged) to allow the diagonal.
        local function isCornerSafe(t)
            return state[t] == "revealed" and not knownMines[t]
        end

        -- diagonal-corner check: returns {cornerA, cornerB} (or {}) by
        -- intersecting the cardinal-neighbor lists of cur and nb.
        local function diagonalCorners(cur, nb)
            local cardCur = cardinalNeighbors[cur]
            local cardNb  = cardinalNeighbors[nb]
            if not cardCur or not cardNb then return {} end
            local set, out = {}, {}
            for _, n in ipairs(cardNb) do if n ~= cur then set[n] = true end end
            for _, n in ipairs(cardCur) do
                if n ~= nb and set[n] then table.insert(out, n) end
            end
            return out
        end

        -- Process one neighbor `nb` against current `cur`. Returns the
        -- finished path (table) if `nb == goalTile`, otherwise nil.
        local visited = { [startTile] = true }
        local parent  = {}
        local queue   = { startTile }
        local head    = 1
        local function tryStep(cur, nb)
            if visited[nb] then return nil end
            -- corner-cut prevention: diagonal move requires BOTH
            -- corner tiles to be revealed-safe. Cardinal = 0 corners
            -- -> always pass. Board-edge diagonal with <2 corners
            -- -> refuse (one corner doesn't exist as a tile).
            local dxN = nb.Position.X - cur.Position.X
            local dzN = nb.Position.Z - cur.Position.Z
            local tsz = math.max(cur.Size.X, cur.Size.Z)
            local isDiagMove =
                (math.abs(dxN) > tsz * 0.5) and (math.abs(dzN) > tsz * 0.5)
            if isDiagMove then
                local corners = diagonalCorners(cur, nb)
                if #corners < 2 then return nil end
                if not (isCornerSafe(corners[1]) and isCornerSafe(corners[2])) then
                    return nil
                end
            end
            visited[nb] = true
            parent[nb]  = cur
            if nb == goalTile then
                local path = {}
                local x = goalTile
                while x and x ~= startTile do
                    table.insert(path, 1, x)
                    x = parent[x]
                end
                return path
            end
            if isWalkable(nb) then
                table.insert(queue, nb)
            end
            return nil
        end

        while head <= #queue do
            local cur = queue[head]; head = head + 1
            -- CARDINAL FIRST. Visiting cardinals before diagonals
            -- biases BFS tie-breaks toward cardinal-heavy routes,
            -- which are inherently safer (no corner grazing).
            local card = cardinalNeighbors[cur]
            if card then
                for _, nb in ipairs(card) do
                    local done = tryStep(cur, nb)
                    if done then return done end
                end
            end
            -- DIAGONALS SECOND (= 8-neighbors minus cardinals).
            -- tryStep's diagonalCorners check already enforces that
            -- BOTH corner tiles between cur and nb are revealed-safe
            -- before allowing the diagonal step, so corner-cutting
            -- across covered tiles is refused.
            local all8 = neighbors[cur]
            if all8 then
                local cardSet = {}
                if card then for _, n in ipairs(card) do cardSet[n] = true end end
                for _, nb in ipairs(all8) do
                    if not cardSet[nb] then
                        local done = tryStep(cur, nb)
                        if done then return done end
                    end
                end
            end
        end
        return nil
    end

    -- Pure MoveTo walk. No CFrame snap.
    local function walkTo(tile)
        local c = lplr.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        local hrp = c and c:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp then return false end

        -- Legit jitter: small random XZ offset so the bot doesn't
        -- hit every tile centre dead-on. Bounded so it stays well
        -- inside the tile. Helps the motion look human rather than
        -- locked to a grid.
        local jx, jz = 0, 0
        if walkLegit and walkLegitJitter > 0 then
            local maxOff = math.min(walkLegitJitter, tile.Size.X * 0.3)
            jx = (math.random() * 2 - 1) * maxOff
            jz = (math.random() * 2 - 1) * maxOff
        end
        local goalPos = tile.Position + Vector3.new(
            jx,
            hrp.Size.Y * 0.5 + tile.Size.Y * 0.5,
            jz
        )
        pcall(function() hum:MoveTo(goalPos) end)

        -- Reach radius scales with walkSmoothness. 0 -> ~0.6 stud
        -- (strict, lands on tile centre), 1.5 -> ~2.1 stud (loose,
        -- glides through). Exit walkTo as soon as we're within the
        -- radius, so the next MoveTo blends in without a full stop.
        local reachR  = 0.6 + walkSmoothness
        local reachR2 = reachR * reachR

        -- Generous deadline so the character actually arrives even
        -- on long steps; the old short timeout was making the bot
        -- cut corners across covered tiles.
        local deadline = tick() + math.max(autoStepDelay, 2.5)
        while autoActive do
            local dx = hrp.Position.X - goalPos.X
            local dz = hrp.Position.Z - goalPos.Z
            if (dx*dx + dz*dz) < reachR2 then return true end
            if tick() > deadline then return true end
            RunService.Heartbeat:Wait()
        end
        return true
    end

    -- Camera setup while auto-play is active:
    --   1. Switch Roblox's Computer movement mode to Follow so the
    --      camera tracks the character's facing direction.
    --   2. Every 1 second, briefly flip CameraType to Scriptable and
    --      write a CFrame with a slight downward pitch (so the user
    --      can see the board). Then flip back to Custom - the Roblox
    --      CameraScript picks up the new orientation as its starting
    --      state. The user can still mouse-look freely in between.
    local _camModeBefore = nil
    local _camTiltThread = nil
    local _camCharConn   = nil
    local _camTiltAngle  = math.rad(-60)  -- 60 degrees down (default)
    local _camTiltOn     = true  -- whether the periodic tilt is enabled
    -- Whether autoplay overrides the camera mode to Follow + spawns
    -- the periodic tilt thread. Default on to preserve the previous
    -- behaviour; the BMSAuto UI exposes a toggle so the user can
    -- keep their own camera settings during auto-play.
    local _followCamOn   = true

    -- Cleanup helper used by both _stopCamTilt and _setCamMode(false)
    -- to recover from a Scriptable camera left over by the tilt loop.
    local function _restoreCameraIfScriptable()
        local cam = workspace.CurrentCamera
        if cam and cam.CameraType == Enum.CameraType.Scriptable then
            pcall(function() cam.CameraType = Enum.CameraType.Custom end)
            local c   = lplr.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if hum then pcall(function() cam.CameraSubject = hum end) end
        end
    end

    -- Camera-MODE override only (UserGameSettings flip). Split from
    -- the tilt logic so the user can toggle them independently.
    local function _setCamMode(enable)
        local ok, ugs = pcall(function()
            return UserSettings():GetService("UserGameSettings")
        end)
        if not ok or not ugs then return end
        if enable then
            if _camModeBefore == nil then
                _camModeBefore = ugs.ComputerCameraMovementMode
            end
            pcall(function()
                ugs.ComputerCameraMovementMode = Enum.ComputerCameraMovementMode.Follow
            end)
        else
            if _camModeBefore ~= nil then
                pcall(function() ugs.ComputerCameraMovementMode = _camModeBefore end)
                _camModeBefore = nil
            end
        end
    end

    -- Tilt thread (re-applies the downward tilt every second) +
    -- CharacterAdded re-bind for recovery from a respawn that
    -- happens during a Scriptable flip. Runs as long as autoActive.
    -- The thread itself checks _camTiltOn each iteration so the
    -- tilt toggle can flip live without re-spawning the thread.
    local function _startCamTilt()
        if _camTiltThread then return end
        _camTiltThread = task.spawn(function()
            while autoActive do
                if _camTiltOn then
                    local cam = workspace.CurrentCamera
                    if cam then
                        local pos   = cam.CFrame.Position
                        local lookV = cam.CFrame.LookVector
                        local yaw   = math.atan2(-lookV.X, -lookV.Z)
                        pcall(function()
                            local prev = cam.CameraType
                            cam.CameraType = Enum.CameraType.Scriptable
                            cam.CFrame = CFrame.new(pos)
                                * CFrame.fromOrientation(_camTiltAngle, yaw, 0)
                            task.wait()
                            cam.CameraType = prev
                        end)
                    end
                end
                task.wait(1)
            end
            _camTiltThread = nil
        end)

        if _camCharConn then _camCharConn:Disconnect() end
        _camCharConn = lplr.CharacterAdded:Connect(function(c)
            if not autoActive then return end
            task.wait(0.3)  -- let the new character settle
            local cam = workspace.CurrentCamera
            local hum = c:FindFirstChildOfClass("Humanoid")
            if cam then
                pcall(function() cam.CameraType = Enum.CameraType.Custom end)
                if hum then pcall(function() cam.CameraSubject = hum end) end
            end
        end)
    end

    local function _stopCamTilt()
        if _camTiltThread then pcall(task.cancel, _camTiltThread); _camTiltThread = nil end
        if _camCharConn   then _camCharConn:Disconnect();          _camCharConn   = nil end
        _restoreCameraIfScriptable()
    end

    -- Backwards-compatible wrapper used by the existing autoPlayStart
    -- / autoPlayStop flow + the camera-mode toggle setter. enable=true
    -- engages whichever sub-features are currently toggled on;
    -- enable=false fully tears down so nothing is left dangling.
    local function setFollowCam(enable)
        if enable then
            if _followCamOn then _setCamMode(true) end
            if _camTiltOn   then _startCamTilt() end
        else
            _stopCamTilt()
            _setCamMode(false)
        end
    end

    -- ---- end-of-round detector + actions ----
    local function detectGameOver()
        local parts = getParts(); if not parts then return nil end
        for _, t in ipairs(parts:GetChildren()) do
            if t:IsA("BasePart") then
                local c = t.Color
                if _RED(c)   then return "loss" end
                if _GREEN(c) then return "win"  end
            end
        end
        return nil
    end

    local function stopAction()
        if actionThread then pcall(task.cancel, actionThread); actionThread = nil end
    end

    -- Pick a random walkable target around `hrp`. Raycasts up to 8
    -- random directions; returns the first one with > 5 studs of
    -- clear horizontal space. If a ray hits something with enough
    -- room behind us, walks to just before the hit (-2 studs buffer)
    -- so the bot doesn't body-press into invisible walls.
    -- Returns nil after 8 blocked attempts so the caller can just
    -- task.wait and retry next tick.
    local function safeRandomTarget(hrp)
        if not hrp then return nil end
        local rp = RaycastParams.new()
        rp.FilterDescendantsInstances = { lplr.Character }
        rp.FilterType = Enum.RaycastFilterType.Exclude
        for _ = 1, 8 do
            local angle = math.random() * math.pi * 2
            local dist  = 10 + math.random() * 10  -- 10-20 studs
            local dir   = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
            local hit   = workspace:Raycast(hrp.Position, dir, rp)
            if not hit then
                return hrp.Position + dir
            end
            local hd = (hit.Position - hrp.Position).Magnitude
            if hd > 5 then
                return hrp.Position + dir.Unit * (hd - 2)
            end
        end
        return nil
    end

    local function startAction(name)
        stopAction()
        -- 'random' rolls one of the four real actions at trigger time
        -- so the bot can't be fingerprinted by always doing the same
        -- thing on each end-of-round.
        if name == "random" then
            local choices = {
                "staying still",
                "walking randomly",
                "jumping in a circle",
                "jumping off map",
            }
            name = choices[math.random(1, #choices)]
            print("[BMS] random action resolved to:", name)
        end
        if name == "staying still" or not name then return end
        actionThread = task.spawn(function()
            local t0 = tick()
            local _circleCenter  -- anchored on first iteration of circle action
            while autoActive do
                local c = lplr.Character
                local hum = c and c:FindFirstChildOfClass("Humanoid")
                local hrp = c and c:FindFirstChild("HumanoidRootPart")
                if not hum or not hrp or hum.Health <= 0 then task.wait(0.5); continue end
                if name == "jumping in a circle" then
                    -- Velocity-based orbit around a fixed 2.5-stud
                    -- radius. The previous MoveTo-per-tick produced a
                    -- stutter (target moved ~1.3 studs/tick, character
                    -- arrived before the next target was issued, then
                    -- stopped). hum:Move applies a walking direction
                    -- continuously - the humanoid moves at full
                    -- walkspeed along the direction we give it each
                    -- frame.
                    --
                    -- direction = tangent (perpendicular to radius,
                    -- ccw) + small radial nudge to keep us on the
                    -- 2.5-stud orbit instead of spiralling out.
                    _circleCenter = _circleCenter or hrp.Position
                    local rel  = hrp.Position - _circleCenter
                    local rel2 = Vector3.new(rel.X, 0, rel.Z)
                    local d    = rel2.Magnitude
                    local tangent
                    if d > 0.01 then
                        -- 90deg ccw rotation about world up
                        tangent = Vector3.new(-rel2.Z, 0, rel2.X) / d
                    else
                        tangent = Vector3.new(1, 0, 0)
                    end
                    local radial = Vector3.zero
                    if     d > 2.7 then radial = -rel2 / d   -- pull inward
                    elseif d < 2.3 then radial =  rel2 / d   -- push outward
                    end
                    local moveDir = tangent + radial * 0.5
                    if moveDir.Magnitude > 0.01 then
                        moveDir = moveDir.Unit
                    end
                    pcall(function() hum:Move(moveDir, false) end)
                    -- Jump only when grounded. Dropped the state-check
                    -- (Jumping / Freefall) - it was too strict, the
                    -- humanoid spends a lot of in-between time NEITHER
                    -- jumping nor freefalling and the jump never fired.
                    if hum.FloorMaterial ~= Enum.Material.Air then
                        pcall(function() hum.Jump = true end)
                    end
                    task.wait(0.1)  -- 10 Hz update keeps Move applying
                elseif name == "jumping off map" then
                    -- Walk to the nearest POINT on the board's edge
                    -- (perpendicular projection onto the closest of
                    -- the 4 sides of the AABB), THEN step off into
                    -- the void perpendicular to that edge.
                    --
                    -- Old version walked to the nearest CORNER, which
                    -- could be a long detour if the player was sitting
                    -- in the middle of a side.
                    local edgePt, outwardDir
                    if #tileList > 0 then
                        local minX, maxX = math.huge, -math.huge
                        local minZ, maxZ = math.huge, -math.huge
                        for _, t in ipairs(tileList) do
                            local p = t.Position
                            if p.X < minX then minX = p.X end
                            if p.X > maxX then maxX = p.X end
                            if p.Z < minZ then minZ = p.Z end
                            if p.Z > maxZ then maxZ = p.Z end
                        end
                        local pos = hrp.Position
                        -- distances to each of the 4 edges
                        local dL, dR = pos.X - minX, maxX - pos.X
                        local dF, dB = pos.Z - minZ, maxZ - pos.Z
                        local best = math.min(dL, dR, dF, dB)
                        if best == dL then
                            edgePt = Vector3.new(minX, pos.Y, math.clamp(pos.Z, minZ, maxZ))
                            outwardDir = Vector3.new(-1, 0, 0)
                        elseif best == dR then
                            edgePt = Vector3.new(maxX, pos.Y, math.clamp(pos.Z, minZ, maxZ))
                            outwardDir = Vector3.new( 1, 0, 0)
                        elseif best == dF then
                            edgePt = Vector3.new(math.clamp(pos.X, minX, maxX), pos.Y, minZ)
                            outwardDir = Vector3.new( 0, 0, -1)
                        else
                            edgePt = Vector3.new(math.clamp(pos.X, minX, maxX), pos.Y, maxZ)
                            outwardDir = Vector3.new( 0, 0,  1)
                        end
                    end
                    if edgePt then
                        pcall(function() hum:MoveTo(edgePt) end)
                        local deadline = tick() + 8
                        while tick() < deadline and autoActive do
                            if (hrp.Position - edgePt).Magnitude < 4 then break end
                            task.wait(0.1)
                        end
                        if outwardDir then
                            -- Walk past the edge AND keep pumping jumps
                            -- while we're still grounded. Single-shot
                            -- jump fired ONCE at the start landed before
                            -- the character even reached the edge - by
                            -- the time it crossed the boundary it was
                            -- mid-stride, not airborne, so it just walked
                            -- off instead of launching. Looping the jump
                            -- (only when grounded) means every ground
                            -- contact on the way to the edge becomes a
                            -- fresh jump; once we're in the air the
                            -- gate stops us from flying.
                            pcall(function() hum:MoveTo(edgePt + outwardDir * 20) end)
                            local t0 = tick()
                            while autoActive and (tick() - t0) < 3 do
                                if hum.FloorMaterial ~= Enum.Material.Air then
                                    pcall(function() hum.Jump = true end)
                                end
                                task.wait(0.15)
                            end
                        end
                    else
                        -- no board found - fall straight down as a fallback
                        pcall(function() hrp.CFrame = CFrame.new(0, -500, 0) end)
                        task.wait(2)
                    end
                    break  -- one-shot
                elseif name == "walking randomly" then
                    local target = safeRandomTarget(hrp)
                    if target then
                        pcall(function() hum:MoveTo(target) end)
                    end
                    task.wait(0.8 + math.random() * 1.5)
                else
                    break
                end
            end
            actionThread = nil
        end)
    end

    -- ---- respawn action ----
    -- Fires after CharacterAdded (death + respawn). Runs the chosen
    -- behaviour until the character is teleported onto the tile
    -- field (= isOnTiles returns true), at which point the action
    -- stops and the normal autoplay loop takes over again.
    local function isOnTiles(hrp)
        if not hrp or #tileList == 0 then return false end
        local minX, maxX = math.huge, -math.huge
        local minZ, maxZ = math.huge, -math.huge
        local maxY = -math.huge
        for _, t in ipairs(tileList) do
            local p = t.Position
            if p.X < minX then minX = p.X end
            if p.X > maxX then maxX = p.X end
            if p.Z < minZ then minZ = p.Z end
            if p.Z > maxZ then maxZ = p.Z end
            if p.Y > maxY then maxY = p.Y end
        end
        local pos = hrp.Position
        return pos.X >= minX and pos.X <= maxX
           and pos.Z >= minZ and pos.Z <= maxZ
           and math.abs(pos.Y - maxY) < 15
    end

    local function findNearestSeat()
        local hrp = lplr.Character and lplr.Character:FindFirstChild("HumanoidRootPart")
        if not hrp then return nil end
        local best, bestD = nil, math.huge
        for _, inst in ipairs(workspace:GetDescendants()) do
            if inst:IsA("Seat") or inst:IsA("VehicleSeat") then
                local d = (inst.Position - hrp.Position).Magnitude
                if d < bestD then best, bestD = inst, d end
            end
        end
        return best
    end

    local function stopRespawnAction()
        if respawnActionThread then
            pcall(task.cancel, respawnActionThread)
            respawnActionThread = nil
        end
    end

    local function startRespawnAction()
        stopRespawnAction()
        local name = respawnAction
        if name == "random" then
            local choices = { "stay still", "walk randomly", "sit down" }
            name = choices[math.random(1, #choices)]
            print("[BMS] random respawn action resolved to:", name)
        end
        if name == "stay still" then return end
        respawnActionThread = task.spawn(function()
            while autoActive do
                local c   = lplr.Character
                local hum = c and c:FindFirstChildOfClass("Humanoid")
                local hrp = c and c:FindFirstChild("HumanoidRootPart")
                if not hum or not hrp or hum.Health <= 0 then
                    task.wait(0.4)
                    continue
                end
                -- exit as soon as we're back on the board
                if isOnTiles(hrp) then break end

                if name == "walk randomly" then
                    local target = safeRandomTarget(hrp)
                    if target then
                        pcall(function() hum:MoveTo(target) end)
                    end
                    task.wait(0.8 + math.random() * 1.5)
                elseif name == "sit down" then
                    local seat = findNearestSeat()
                    if seat then
                        pcall(function() hum:MoveTo(seat.Position) end)
                        -- wait until seated (Sit set by SeatPart touch)
                        local deadline = tick() + 8
                        while tick() < deadline and autoActive do
                            if hum.Sit then break end
                            if isOnTiles(hrp) then break end
                            task.wait(0.1)
                        end
                        -- stay seated, but bail out if we get teleported
                        while autoActive and hum.Sit and not isOnTiles(hrp) do
                            task.wait(0.5)
                        end
                    else
                        task.wait(1)
                    end
                else
                    break
                end
            end
            respawnActionThread = nil
        end)
    end

    local function autoPlayStart()
        if autoActive then return end
        autoActive = true
        gameOverState = nil
        -- respawn-action hook: fires the configured respawn behaviour
        -- after every CharacterAdded (death + respawn). The action
        -- stops itself once isOnTiles(hrp) becomes true, so the normal
        -- planner takes over the moment we're teleported back.
        if _respawnCharConn then _respawnCharConn:Disconnect() end
        _respawnCharConn = lplr.CharacterAdded:Connect(function()
            if not autoActive then return end
            task.wait(0.6)  -- let the spawn animation + char rig settle
            startRespawnAction()
        end)
        if detectorThread then pcall(task.cancel, detectorThread) end
        detectorThread = task.spawn(function()
            while autoActive do
                local state = detectGameOver()
                if state ~= gameOverState then
                    gameOverState = state
                    if state == "win" then
                        stats.wins = stats.wins + 1
                        saveStats(); updateStatsGui()
                        print(("[BMS] win detected (#%d); action: %s"):format(stats.wins, winAction))
                        startAction(winAction)
                    elseif state == "loss" then
                        stats.losses = stats.losses + 1
                        saveStats(); updateStatsGui()
                        print(("[BMS] loss detected (#%d); action: %s"):format(stats.losses, failAction))
                        startAction(failAction)
                    else
                        -- new round started (colours reset) - stop action
                        stopAction()
                    end
                end
                task.wait(1)
            end
            stopAction()
            detectorThread = nil
        end)
        setFollowCam(true)
        if autoThread then pcall(task.cancel, autoThread) end
        lastFlagAt = 0  -- reset cooldown so a fresh autoplay session starts immediately
        autoThread = task.spawn(function()
            while autoActive do
                -- Guard: skip the whole tick when the character is
                -- dead / mid-respawn. Otherwise findCurrentTile picks
                -- whatever tile is closest to (0,0,0) and the loop
                -- spins through deduce/BFS on every frame of the
                -- respawn animation - that compounded with the game's
                -- bomb-death scripts is what stalls hard after a
                -- 50/50 guess.
                local char = lplr.Character
                local hum  = char and char:FindFirstChildOfClass("Humanoid")
                if not hum or hum.Health <= 0 then
                    task.wait(0.4)
                    continue
                end

                -- Game-over short-circuit: detector thread tracks tile
                -- colours (red = loss / green = win); while gameOverState
                -- is set, the action thread (jumping/walking/staying) is
                -- running and the main planner should idle so it doesn't
                -- step on the action's MoveTos.
                if gameOverState then
                    task.wait(0.3)
                    continue
                end

                local parts = getParts()
                if not parts then task.wait(0.3); continue end
                -- Use the incrementally-maintained tileList instead of
                -- parts:GetChildren(). On infinite-mode boards with
                -- thousands of tiles, GetChildren() allocated a fresh
                -- N-element array every tick at 10Hz = significant GC.
                -- ensureNeighbors() reconciles any drift if events were
                -- missed; for steady state it short-circuits.
                ensureNeighbors(tileList)
                local all = tileList
                local state = {}
                for _, t in ipairs(all) do state[t] = tileStateCached(t) end
                local mines, safes, falseFlags, probs, fiftyPairs = deduce(all, state)
                falseFlags = falseFlags or {}
                probs      = probs or {}
                fiftyPairs = fiftyPairs or {}
                local origin  = myPos()
                -- (a) flag closest unflagged deduced mine if cooldown elapsed
                local token  = getgenv()._BMS_TOKEN
                local remote = getPlaceFlag()
                local now    = tick()
                if token and remote and (now - lastFlagAt) >= flagDelayMin then
                    -- Auto-play flagging is UNBOUNDED across the whole
                    -- map (no rangeSq check). Aim cone still applies if
                    -- it's enabled. Standalone Legit auto-flag still
                    -- respects its range slider.
                    --
                    -- Closest-bomb priority: ALWAYS prefer the closest
                    -- unflagged deduced mine to the player. Only fall
                    -- back to falseFlag corrections when there are no
                    -- mine candidates - otherwise the bot would
                    -- sometimes 'flag' the closest falseFlag (which
                    -- actually removes the flag) instead of arming
                    -- the closest real bomb.
                    local best, bestD2 = nil, math.huge
                    for t in pairs(mines) do
                        if state[t] ~= "flagged"
                           and inAimCone(t)
                           and isTileOnScreen(t) then
                            local dx = t.Position.X - origin.X
                            local dz = t.Position.Z - origin.Z
                            local d2 = dx*dx + dz*dz
                            if d2 < bestD2 then best, bestD2 = t, d2 end
                        end
                    end
                    if not best then
                        for t in pairs(falseFlags) do
                            if inAimCone(t) and isTileOnScreen(t) then
                                local dx = t.Position.X - origin.X
                                local dz = t.Position.Z - origin.Z
                                local d2 = dx*dx + dz*dz
                                if d2 < bestD2 then best, bestD2 = t, d2 end
                            end
                        end
                    end
                    if best then
                        if not flagMissRoll() then
                            -- Auto-play bypasses the whole stealth
                            -- layer (rate cap, reaction delay,
                            -- hesitation, cursor sweep). The walk-
                            -- step needs the autoplay tick to
                            -- return promptly so the character
                            -- keeps moving. Auto-play already has
                            -- its own flagDelayMin/Max cooldown
                            -- and flagMissRoll, so stealth pacing
                            -- on top would just be extra dead time
                            -- in every tick.
                            local skip = preFlagSequence(best, { bypass = true })
                            if not skip then
                                pcall(function() remote:FireServer(best, token, true) end)
                            end
                        end
                        lastFlagAt = now + flagDelayRoll() - flagDelayMin
                        -- logical playstyle takes a longer beat after
                        -- each flag fire so newly exposed bombs /
                        -- numbers read like a person studying the
                        -- board before reacting. legit keeps the
                        -- original 0.1s tick.
                        if playstyleMode == "logical" then
                            task.wait(0.8 + math.random() * 0.8)  -- 0.8-1.6s
                        else
                            task.wait(0.1)
                        end
                        continue
                    end
                end

                -- Logical-mode 'thinking' beat between movements. Once
                -- per autoplay tick (NOT per step), before we even look
                -- at the deduced safes, pause briefly so the bot looks
                -- like it's reading the board instead of snap-chaining
                -- moves. Skipped during the chain loop further down so
                -- already-walking momentum isn't interrupted mid-chain.
                if playstyleMode == "logical" then
                    task.wait(0.5 + math.random() * 0.6)  -- 0.5-1.1s
                end
                -- (b) walk to nearest REACHABLE deduced-safe tile
                local startTile = findCurrentTile(all, origin)
                if startTile then
                    -- Pick the tile to walk to. If we just chose a target
                    -- recently (within autoTargetDebounce) AND it's still
                    -- a valid covered deduced-safe AND still reachable,
                    -- STICK with it - prevents target jitter when new
                    -- deductions shuffle the candidate list mid-walk.
                    local nowTick = tick()
                    local pick    = nil
                    if _lastWalkTarget and _lastWalkTarget.Parent
                       and (nowTick - _lastWalkTargetAt) < autoTargetDebounce
                       and state[_lastWalkTarget] == "covered"
                       and safes[_lastWalkTarget]
                       and not mines[_lastWalkTarget] then
                        local p = bfsPath(startTile, _lastWalkTarget, state, mines, falseFlags)
                        if p and #p > 0 then pick = _lastWalkTarget end
                    end
                    -- No locked target (or it became invalid) - pick fresh
                    -- from the full board, sorted by distance.
                    if not pick then
                        local candidates = {}
                        for s in pairs(safes) do
                            if state[s] == "covered" then
                                local dx = s.Position.X - origin.X
                                local dz = s.Position.Z - origin.Z
                                table.insert(candidates, { tile = s, d2 = dx*dx + dz*dz })
                            end
                        end
                        table.sort(candidates, function(a, b) return a.d2 < b.d2 end)
                        for _, c in ipairs(candidates) do
                            if not autoActive then break end
                            local p = bfsPath(startTile, c.tile, state, mines, falseFlags)
                            if p and #p > 0 then
                                pick = c.tile
                                _lastWalkTarget   = pick
                                _lastWalkTargetAt = nowTick
                                break
                            end
                        end
                    end
                    local walked = false
                    if pick then
                        local path = bfsPath(startTile, pick, state, mines, falseFlags)
                        if path and #path > 0 then
                            drawPathPreview({ startTile, table.unpack(path) })
                            local lastIdx = #path
                            for stepIdx, step in ipairs(path) do
                                if not autoActive then break end
                                local s = tileState(step)
                                if stepIdx < lastIdx then
                                    if s == "flagged" then
                                        -- ok, flag protects
                                    elseif s ~= "revealed" or mines[step] then
                                        break
                                    end
                                else
                                    if mines[step] then break end
                                end
                                walkTo(step)
                            end
                            walked = true

                            -- CONTINUOUS WALK LOOP. After revealing
                            -- `pick`, keep going without returning to
                            -- the outer autoplay tick:
                            --   1. Re-deduce live state.
                            --   2. If a cardinal neighbour is still
                            --      covered + deduced-safe, step into
                            --      it directly (this is the original
                            --      "chain" - cheap, no BFS).
                            --   3. Otherwise BFS to the nearest
                            --      non-adjacent reachable safe and
                            --      walk that path inline.
                            --   4. Loop until there's no reachable
                            --      safe left.
                            --
                            -- The user complained about a ~ms stall
                            -- when switching targets. That stall was
                            -- the outer loop's getParts / O(N) state
                            -- build / candidate sort / new BFS work
                            -- that ran between the chain ending and
                            -- the next walk starting. By keeping the
                            -- planning loop here on the live state
                            -- maps we already computed, the character
                            -- can re-issue MoveTo without ever fully
                            -- decelerating to a stop.
                            local current = pick
                            while autoActive do
                                local liveState = {}
                                for _, t in ipairs(all) do
                                    liveState[t] = tileStateCached(t)
                                end
                                local liveMines, liveSafes = deduce(all, liveState)
                                liveMines = liveMines or {}
                                liveSafes = liveSafes or {}

                                -- ADJACENT chain step (cheapest path)
                                local card = cardinalNeighbors[current]
                                local pos  = myPos()
                                local nextTile, nextD2 = nil, math.huge
                                if card then
                                    for _, nb in ipairs(card) do
                                        if liveState[nb] == "covered"
                                           and liveSafes[nb]
                                           and not liveMines[nb] then
                                            local dx = nb.Position.X - pos.X
                                            local dz = nb.Position.Z - pos.Z
                                            local d2 = dx*dx + dz*dz
                                            if d2 < nextD2 then
                                                nextTile, nextD2 = nb, d2
                                            end
                                        end
                                    end
                                end
                                if nextTile then
                                    walkTo(nextTile)
                                    current = nextTile
                                else
                                    -- NO adjacent safe. Find the
                                    -- nearest non-adjacent reachable.
                                    local candidates = {}
                                    for s in pairs(liveSafes) do
                                        if liveState[s] == "covered" then
                                            local dx = s.Position.X - pos.X
                                            local dz = s.Position.Z - pos.Z
                                            table.insert(candidates,
                                                { tile = s, d2 = dx*dx + dz*dz })
                                        end
                                    end
                                    if #candidates == 0 then break end
                                    table.sort(candidates,
                                        function(a, b) return a.d2 < b.d2 end)

                                    local startTile2 = findCurrentTile(all, pos)
                                    if not startTile2 then break end
                                    local newPick, newPath = nil, nil
                                    for _, c in ipairs(candidates) do
                                        if not autoActive then break end
                                        local p = bfsPath(startTile2, c.tile,
                                            liveState, liveMines, falseFlags)
                                        if p and #p > 0 then
                                            newPick, newPath = c.tile, p
                                            break
                                        end
                                    end
                                    if not newPick or not newPath then break end

                                    drawPathPreview(
                                        { startTile2, table.unpack(newPath) })
                                    local lastIdx2 = #newPath
                                    for stepIdx, step in ipairs(newPath) do
                                        if not autoActive then break end
                                        local s = tileState(step)
                                        if stepIdx < lastIdx2 then
                                            if s == "flagged" then
                                                -- ok
                                            elseif s ~= "revealed" or liveMines[step] then
                                                break
                                            end
                                        else
                                            if liveMines[step] then break end
                                        end
                                        walkTo(step)
                                    end
                                    current = newPick
                                end
                            end
                        end
                    end
                    if not walked then hidePathSegments() end
                    -- GUESS FALLBACK: we got here without walking a safe
                    -- AND the flag step above didn't fire (it would have
                    -- `continue`d the loop). So nothing useful happened
                    -- this tick - if guess mode is on, walk to the
                    -- lowest-probability covered tile we have prob info
                    -- on (cap at p <= 0.55 so we never deliberately step
                    -- onto worse-than-coinflip).
                    if not walked and autoGuess and startTile then
                        -- Priority 1: explicit 50/50 pair handling.
                        -- For a (a,b) pair with exactly 1 mine between
                        -- them, flag one + walk the other in the same
                        -- tick. The walked tile reveals safely if our
                        -- pick was right; if wrong, we die anyway. Same
                        -- 50% outcome as just walking one, BUT we also
                        -- correctly mark the other tile if we live.
                        for _, pair in ipairs(fiftyPairs) do
                            if not autoActive then break end
                            local a, b = pair[1], pair[2]
                            if not a.Parent or not b.Parent then continue end
                            if state[a] ~= "covered" or state[b] ~= "covered" then continue end
                            local pathA = bfsPath(startTile, a, state, mines, falseFlags)
                            local pathB = bfsPath(startTile, b, state, mines, falseFlags)
                            local walkTile, flagTile, path
                            if pathA then walkTile, flagTile, path = a, b, pathA
                            elseif pathB then walkTile, flagTile, path = b, a, pathB
                            end
                            if walkTile and token and remote then
                                pcall(function() remote:FireServer(flagTile, token, true) end)
                                lastFlagAt = tick()
                                drawPathPreview({ startTile, table.unpack(path) })
                                for stepIdx, step in ipairs(path) do
                                    if not autoActive then break end
                                    local s = tileState(step)
                                    if stepIdx < #path then
                                        if s == "flagged" then
                                            -- ok
                                        elseif s ~= "revealed" or mines[step] then
                                            break
                                        end
                                    end
                                    walkTo(step)
                                end
                                walked = true
                                -- After the guess step lands, give
                                -- the game ~0.5s to process the
                                -- reveal (cascade or bomb death)
                                -- before the loop re-iterates. Stops
                                -- our 10Hz spin from compounding on
                                -- top of the game's bomb scripts.
                                task.wait(0.5)
                                break
                            end
                        end
                        -- Priority 2: lowest-prob covered tile walk.
                        -- For tiles outside any 50/50 pair (e.g. 3-tile
                        -- group with prob ~0.33 each).
                        if not walked then
                            local guesses = {}
                            for tile, p in pairs(probs) do
                                if state[tile] == "covered" and p <= 0.55 then
                                    table.insert(guesses, { tile = tile, p = p })
                                end
                            end
                            table.sort(guesses, function(a, b) return a.p < b.p end)
                            for _, g in ipairs(guesses) do
                                if not autoActive then break end
                                local path = bfsPath(startTile, g.tile, state, mines, falseFlags)
                                if path and #path > 0 then
                                    drawPathPreview({ startTile, table.unpack(path) })
                                    for stepIdx, step in ipairs(path) do
                                        if not autoActive then break end
                                        local s = tileState(step)
                                        if stepIdx < #path then
                                            if s == "flagged" then
                                                -- ok
                                            elseif s ~= "revealed" or mines[step] then
                                                break
                                            end
                                        end
                                        walkTo(step)
                                    end
                                    walked = true
                                    -- settle (same reason as the 50/50 path)
                                    task.wait(0.5)
                                    break
                                end
                            end
                        end
                    end
                    if not walked then task.wait(0.3) end
                else
                    task.wait(0.3)
                end
            end
        end)
    end

    local function autoPlayStop()
        autoActive = false
        if autoThread     then pcall(task.cancel, autoThread);     autoThread     = nil end
        if detectorThread then pcall(task.cancel, detectorThread); detectorThread = nil end
        stopAction()
        stopRespawnAction()
        if _respawnCharConn then _respawnCharConn:Disconnect(); _respawnCharConn = nil end
        gameOverState = nil
        clearPathPreview()
        setFollowCam(false)
        -- release the cursor from tracking whatever tile was last
        -- targeted by the flag step
        _clearCursorTarget()
        -- keep stats GUI visible across autoplay toggles - user
        -- explicitly toggles it via setStatsGui. Stats counts also
        -- persist via the file on disk.
    end

    return {
        esp = {
            start    = espStart,
            stop     = espStop,
            isActive = function() return espActive end,
            setRange         = function(n) espRange         = math.clamp(tonumber(n) or 80,  10, 1000) end,
            setShowSafes     = function(v) espShowSafes     = v == true end,
            setShowWarnings  = function(v) espShowWarnings  = v == true end,
            setShowFifties   = function(v) espShowFifties   = v == true end,
            setHeatmap       = function(v) espHeatmap       = v == true end,
            setMineColor     = function(c) if typeof(c) == "Color3" then MINE_COLOR  = c end end,
            setSafeColor     = function(c) if typeof(c) == "Color3" then SAFE_COLOR  = c end end,
            setWarnColor     = function(c) if typeof(c) == "Color3" then WARN_COLOR  = c end end,
            setFiftyColor    = function(c) if typeof(c) == "Color3" then FIFTY_COLOR = c end end,
            getMineColor     = function() return MINE_COLOR end,
            getSafeColor     = function() return SAFE_COLOR end,
            getWarnColor     = function() return WARN_COLOR end,
            getFiftyColor    = function() return FIFTY_COLOR end,
            -- Scan-radius visualizer: a flat translucent cylinder on
            -- the ground centred on the player, showing exactly which
            -- area ESP is currently scanning each tick.
            setScanRadiusViz   = setScanRadiusViz,
            setScanRadiusColor = setScanRadiusColor,
            getScanRadiusColor = function() return scanVizColor end,
        },
        legitFlag = {
            start    = legitFlagStart,
            stop     = legitFlagStop,
            isActive = function() return flagActive end,
            -- Setters reset lastFlagAt so the new value takes effect on
            -- the very next tick instead of waiting for the OLD cooldown
            -- to elapse. That was the 'settings don't feel live' issue.
            setDelayMin   = function(n) flagDelayMin   = math.clamp(tonumber(n) or 0.6, 0, 10); lastFlagAt = 0 end,
            setDelayMax   = function(n) flagDelayMax   = math.clamp(tonumber(n) or 1.4, 0, 10); lastFlagAt = 0 end,
            setMissChance = function(n) flagMissChance = math.clamp(tonumber(n) or 0,   0,    100) end,
            setRange      = function(n) flagRange = math.clamp(tonumber(n) or 60, 5, 500) end,
            setAimCone    = function(v) flagAimCone = v == true end,
            setAimHalfDeg = function(n) flagAimHalfDeg = math.clamp(tonumber(n) or 30, 1, 180) end,
            -- Aim-cone visualizer: a translucent ConeHandleAdornment
            -- anchored to the camera, showing the actual filter
            -- region. Only renders when the aim-cone filter is on.
            setAimConeViz   = setAimConeViz,
            setAimConeColor = setAimConeColor,
            getAimConeColor = function() return aimConeVizColor end,
        },
        autoPlay = {
            start    = autoPlayStart,
            stop     = autoPlayStop,
            isActive = function() return autoActive end,
            setStepDelay      = function(n) autoStepDelay = math.clamp(tonumber(n) or 0.4, 0.05, 3) end,
            setGuess          = function(v) autoGuess = v == true end,
            setTargetDebounce = function(n) autoTargetDebounce = math.clamp(tonumber(n) or 0.2, 0, 5) end,
            setSmoothness     = function(n) walkSmoothness = math.clamp(tonumber(n) or 0.6, 0, 1.5) end,
            setLegit          = function(v) walkLegit = v == true end,
            setLegitJitter    = function(n) walkLegitJitter = math.clamp(tonumber(n) or 0.6, 0, 2) end,
            setPathPreview    = function(v) pathPreview = v == true; if not v then hidePathSegments() end end,
            setPathPreviewColor = function(c) if typeof(c) == "Color3" then pathPreviewColor = c end end,
            getPathPreviewColor = function() return pathPreviewColor end,
            -- camera tilt
            -- Camera tilt: now INDEPENDENT of follow-cam. Spawns or
            -- tears down its own thread + CharacterAdded re-bind
            -- so tilt works whether or not the camera mode override
            -- is engaged.
            setCamTilt        = function(v)
                _camTiltOn = v == true
                if autoActive then
                    if _camTiltOn then _startCamTilt() else _stopCamTilt() end
                end
            end,
            -- Camera-mode override (UserGameSettings.Follow). Only
            -- touches the camera mode now - tilt has its own setter.
            setFollowCam      = function(v)
                _followCamOn = v == true
                if autoActive then
                    _setCamMode(_followCamOn)
                end
            end,
            setCamTiltAngle   = function(n)
                local deg = math.clamp(tonumber(n) or 60, 0, 90)
                _camTiltAngle = math.rad(-deg)
            end,
            -- post-round actions (playstyle moved to top-level
            -- hook.games.bms.setPlaystyle since it now applies to the
            -- standalone auto-flag as well, not just auto-play)
            setWinAction  = function(a)
                if a then winAction = tostring(a) end
            end,
            setFailAction = function(a)
                if a then failAction = tostring(a) end
            end,
            setRespawnAction = function(a)
                if a then respawnAction = tostring(a) end
            end,
            getWinAction     = function() return winAction end,
            getFailAction    = function() return failAction end,
            getRespawnAction = function() return respawnAction end,
            -- stats
            setStatsGui   = setStatsGui,
            resetStats    = resetStats,
            getStats      = function() return stats.wins, stats.losses end,
        },
        hasToken      = function() return getgenv()._BMS_TOKEN ~= nil end,
        setToken      = setManualToken,
        getToken      = function() return getgenv()._BMS_TOKEN end,
        autoCaptureToken = autoCaptureToken,
        -- Playstyle applies to BOTH the standalone auto-flag thread
        -- and the auto-play planner. Exposed at module level (not
        -- under autoPlay) so the UI can sit in its own groupbox and
        -- not look like it requires auto-play to be on.
        --   'legit'    = current behaviour, no extra pacing
        --   'logical'  = longer 'reading the board' beats after every
        --                flag fire + between movements
        setPlaystyle = function(m)
            if m == "legit" or m == "logical" then
                playstyleMode = m
            end
        end,
        getPlaystyle = function() return playstyleMode end,
        -- Screenshare stealth: cursor sim + reaction-time variance +
        -- fake hesitation. Applies to both legit auto-flag and auto-
        -- play's flag step (whichever fires PlaceFlag). See the big
        -- comment block above preFlagSequence() for details.
        stealth = {
            setCursorSim = function(v)
                _st.cursorOn = v == true
                if _st.cursorOn then
                    _startTracker()
                else
                    _stopTracker()
                end
            end,
            setReactionMean = function(n)
                _st.reactMs = math.clamp(tonumber(n) or 350, 0, 5000)
            end,
            setReactionJitter = function(n)
                _st.reactJitter = math.clamp(tonumber(n) or 250, 0, 5000)
            end,
            setHesitate = function(n)
                _st.hesitatePct = math.clamp(tonumber(n) or 0, 0, 100)
            end,
            -- On-screen filter: prune flag candidates to tiles whose
            -- viewport coords are inside the visible screen rect.
            -- Critical for manual-play screenshare safety so flags
            -- don't pop on parts of the map you're not looking at.
            setOnScreenOnly = function(v) _st.onScreenOnly = v == true end,
            -- Min seconds between fires (hard rate cap). 0 = off.
            setMinSecBetween = function(n)
                _st.minSecBetween = math.clamp(tonumber(n) or 0, 0, 10)
            end,
            -- General cursor speed in px/sec for flag sweeps.
            setCursorSpeed = function(n)
                _st.cursorSpeed = math.clamp(tonumber(n) or 600, 50, 5000)
            end,
            -- Bezier curve magnitude (0..200 %). Scales how far
            -- the path bows from a straight line. 0 = straight,
            -- ~30-50 = subtle arc, 100+ = exaggerated.
            setCurveAmount = function(n)
                _st.curveAmount = math.clamp((tonumber(n) or 35) / 100, 0, 2)
            end,
            -- Per-sweep speed variance (0..100 %). Each sweep
            -- rolls a speed multiplier in [1-v, 1+v] so the cursor
            -- doesn't take the same exact time on every sweep.
            setSpeedVariance = function(n)
                _st.speedVariance = math.clamp((tonumber(n) or 45) / 100, 0, 1)
            end,
            -- Flag magnet: standalone. When the user's cursor moves
            -- within N px of a deduced mine, magnet runs its own
            -- quick smooth-sweep to the tile + fires PlaceFlag.
            -- Doesn't require legitFlag or cursor sim to be on.
            setMagnet      = function(v)
                _st.magnetOn = v == true
                if _st.magnetOn then _startMagnet() else _stopMagnet() end
            end,
            setMagnetRange = function(n)
                _st.magnetRange = math.clamp(tonumber(n) or 80, 5, 500)
            end,
            -- Triggerbot: independent of legitFlag. Fires PlaceFlag
            -- when cursor is within N px of a deduced unflagged
            -- mine. No sweep, no reaction delay.
            setTriggerbot  = function(v)
                _st.triggerbotOn = v == true
                if _st.triggerbotOn then _startTriggerbot() else _stopTriggerbot() end
            end,
            setTriggerRange = function(n)
                _st.triggerRange = math.clamp(tonumber(n) or 12, 1, 100)
            end,
            -- Radial over/undershoot range (px). The initial landing
            -- offset is uniform random in [min, max] px from tile
            -- centre; a correction pulls cursor to ~30% of that
            -- before fire.
            setOffsetMin = function(n)
                _st.offsetMin = math.clamp(tonumber(n) or 5, 0, 100)
            end,
            setOffsetMax = function(n)
                _st.offsetMax = math.clamp(tonumber(n) or 15, 0, 100)
            end,
            hasCursorAPI = function() return _stealthMoveCursor ~= nil end,
        },
    }
end)()

end  -- BMS backend
-- ============================================================
--  UI  (3 tabs: Autoplay, Autoflag, Mouse mover)
-- ============================================================
local bms = hook.games.bms
if bms then

local autoPlayT, autoFlagT
local tokenLblPlay, tokenLblFlag

-- ---------------- AUTOPLAY ----------------
local AutoPlay = Window:NewTab("Autoplay")
AutoPlay:NewSection("Token")
tokenLblPlay = AutoPlay:NewLabel("Token: checking...", "left")
AutoPlay:NewSection("Auto play")
autoPlayT = regToggle(AutoPlay, "BMSAutoPlay", "Auto play (walk safes + flag mines)", false, function(v)
    if v then
        if autoFlagT then autoFlagT:Set(false) end
        bms.autoPlay.start()
    else
        bms.autoPlay.stop()
    end
end)
regDecimal(AutoPlay, "BMSAutoStepDelay", "Walk step max delay", " s", 0.05, 3, 0.4, 100, function(v) bms.autoPlay.setStepDelay(v) end)
regToggle(AutoPlay, "BMSAutoGuess", "Guess when truly stuck", false, function(v) bms.autoPlay.setGuess(v) end)
regDecimal(AutoPlay, "BMSAutoDebounce", "Target switch debounce", " s", 0, 5, 0.2, 100, function(v) bms.autoPlay.setTargetDebounce(v) end)
regDecimal(AutoPlay, "BMSAutoSmoothness", "Walk smoothness", " studs", 0, 1.5, 0.6, 100, function(v) bms.autoPlay.setSmoothness(v) end)
regToggle(AutoPlay, "BMSAutoLegit", "Legit walk (humanlike jitter)", true, function(v) bms.autoPlay.setLegit(v) end)
regDecimal(AutoPlay, "BMSAutoLegitJitter", "Legit walk jitter", " studs", 0, 2, 0.6, 100, function(v) bms.autoPlay.setLegitJitter(v) end)
regToggle(AutoPlay, "BMSAutoFollowCam", "Follow camera mode", true, function(v) bms.autoPlay.setFollowCam(v) end)
regToggle(AutoPlay, "BMSAutoCamTilt", "Camera tilt", true, function(v) bms.autoPlay.setCamTilt(v) end)
regSlider(AutoPlay, "BMSAutoCamTiltAngle", "Camera tilt angle", " deg", { min = 0, max = 90, default = 60 }, function(v) bms.autoPlay.setCamTiltAngle(v) end)

AutoPlay:NewSection("Path preview")
regToggle(AutoPlay, "BMSAutoPathPreview", "Show path preview (glowing line)", false, function(v) bms.autoPlay.setPathPreview(v) end)
regColor(AutoPlay, "BMSAutoPathColor", "Path color", bms.autoPlay.getPathPreviewColor(), function(c) bms.autoPlay.setPathPreviewColor(c) end)

AutoPlay:NewSection("Round-end actions")
local BMS_ACTIONS = { "staying still", "walking randomly", "jumping in a circle", "jumping off map", "random" }
regDropdown(AutoPlay, "BMSWinAction", "Action after win", "staying still", BMS_ACTIONS, false, function(v) bms.autoPlay.setWinAction(v) end)
regDropdown(AutoPlay, "BMSFailAction", "Action after fail", "staying still", BMS_ACTIONS, false, function(v) bms.autoPlay.setFailAction(v) end)
regDropdown(AutoPlay, "BMSRespawnAction", "Action after respawn", "stay still", { "stay still", "walk randomly", "sit down", "random" }, false, function(v) bms.autoPlay.setRespawnAction(v) end)

AutoPlay:NewSection("Stats")
regToggle(AutoPlay, "BMSStatsGui", "Show stats overlay", false, function(v) bms.autoPlay.setStatsGui(v) end)
AutoPlay:NewButton("Reset stats", function() bms.autoPlay.resetStats() end)
AutoPlay:NewLabel("Reuses the Autoflag tab settings.", "left")

-- ---------------- AUTOFLAG ----------------
local AutoFlag = Window:NewTab("Autoflag")
AutoFlag:NewSection("Token")
tokenLblFlag = AutoFlag:NewLabel("Token: checking...", "left")
AutoFlag:NewSection("Legit auto-flag")
autoFlagT = regToggle(AutoFlag, "BMSLegitFlag", "Auto-flag deduced mines", false, function(v)
    if v then
        if autoPlayT then autoPlayT:Set(false) end
        bms.legitFlag.start()
    else
        bms.legitFlag.stop()
    end
end)
-- shown in ms (0-240), applied in seconds
regDecimal(AutoFlag, "BMSFlagDelayMin", "Flag delay min", " ms", 0, 0.24, 0, 1000, function(v) bms.legitFlag.setDelayMin(v) end)
regDecimal(AutoFlag, "BMSFlagDelayMax", "Flag delay max", " ms", 0, 0.24, 0.24, 1000, function(v) bms.legitFlag.setDelayMax(v) end)
regSlider(AutoFlag, "BMSFlagMissChance", "Flag miss chance", " %", { min = 0, max = 100, default = 0 }, function(v) bms.legitFlag.setMissChance(v) end)
regSlider(AutoFlag, "BMSFlagRange", "Flag range", " studs", { min = 5, max = 500, default = 60 }, function(v) bms.legitFlag.setRange(v) end)

AutoFlag:NewSection("Aim cone")
regToggle(AutoFlag, "BMSFlagAimCone", "Only flag what I'm looking at", false, function(v) bms.legitFlag.setAimCone(v) end)
regSlider(AutoFlag, "BMSFlagAimAngle", "Aim cone half-angle", " deg", { min = 5, max = 90, default = 30 }, function(v) bms.legitFlag.setAimHalfDeg(v) end)
regToggle(AutoFlag, "BMSAimConeViz", "Show aim cone", false, function(v) bms.legitFlag.setAimConeViz(v) end)
regColor(AutoFlag, "BMSAimConeColor", "Aim cone color", bms.legitFlag.getAimConeColor(), function(c) bms.legitFlag.setAimConeColor(c) end)

AutoFlag:NewSection("Playstyle")
regDropdown(AutoFlag, "BMSPlaystyle", "Playstyle", "legit", { "legit", "logical" }, false, function(v) bms.setPlaystyle(v) end)

-- ---------------- ESP ----------------
local Esp = Window:NewTab("ESP")
Esp:NewSection("Mine ESP")
regToggle(Esp, "BMSEsp", "Mine ESP", false, function(v) if v then bms.esp.start() else bms.esp.stop() end end)
regSlider(Esp, "BMSEspRange", "ESP range", " studs", { min = 10, max = 1000, default = 80 }, function(v) bms.esp.setRange(v) end)
regToggle(Esp, "BMSEspShowSafes", "Highlight deduced-safe tiles", false, function(v) bms.esp.setShowSafes(v) end)
regToggle(Esp, "BMSEspShowWarnings", "Highlight false-flag warnings", true, function(v) bms.esp.setShowWarnings(v) end)
regToggle(Esp, "BMSEspShowFifties", "Highlight 50/50 tiles", true, function(v) bms.esp.setShowFifties(v) end)
regToggle(Esp, "BMSEspHeatmap", "Heatmap (probability gradient)", false, function(v) bms.esp.setHeatmap(v) end)
Esp:NewSection("Colors")
regColor(Esp, "BMSEspMineColor", "Mine color", bms.esp.getMineColor(), function(c) bms.esp.setMineColor(c) end)
regColor(Esp, "BMSEspSafeColor", "Safe color", bms.esp.getSafeColor(), function(c) bms.esp.setSafeColor(c) end)
regColor(Esp, "BMSEspWarnColor", "False-flag color", bms.esp.getWarnColor(), function(c) bms.esp.setWarnColor(c) end)
regColor(Esp, "BMSEspFiftyColor", "50/50 color", bms.esp.getFiftyColor(), function(c) bms.esp.setFiftyColor(c) end)
Esp:NewSection("Scan radius")
regToggle(Esp, "BMSScanRadiusViz", "Show ESP scan radius", false, function(v) bms.esp.setScanRadiusViz(v) end)
regColor(Esp, "BMSScanRadiusColor", "Scan radius color", bms.esp.getScanRadiusColor(), function(c) bms.esp.setScanRadiusColor(c) end)

-- ---------------- MOUSE MOVER ----------------
local MouseMover = Window:NewTab("Mouse mover")
MouseMover:NewSection("Cursor simulation")
regToggle(MouseMover, "BMSCursorSim", "Move OS cursor to tile before flagging", false, function(v) bms.stealth.setCursorSim(v) end)
regSlider(MouseMover, "BMSReactionMean", "Reaction time", " ms", { min = 0, max = 1500, default = 350 }, function(v) bms.stealth.setReactionMean(v) end)
regSlider(MouseMover, "BMSReactionJitter", "Reaction +/- jitter", " ms", { min = 0, max = 1500, default = 250 }, function(v) bms.stealth.setReactionJitter(v) end)
regSlider(MouseMover, "BMSHesitate", "Fake hesitation chance", " %", { min = 0, max = 100, default = 0 }, function(v) bms.stealth.setHesitate(v) end)
regToggle(MouseMover, "BMSOnScreenOnly", "Only flag tiles visible on screen", false, function(v) bms.stealth.setOnScreenOnly(v) end)
regDecimal(MouseMover, "BMSMinSecBetween", "Min time between flags", " s", 0, 5, 0, 100, function(v) bms.stealth.setMinSecBetween(v) end)
regSlider(MouseMover, "BMSCursorSpeed", "Cursor speed", " px/s", { min = 100, max = 3000, default = 600 }, function(v) bms.stealth.setCursorSpeed(v) end)
regSlider(MouseMover, "BMSCurveAmount", "Path curve amount", " %", { min = 0, max = 200, default = 35 }, function(v) bms.stealth.setCurveAmount(v) end)
regSlider(MouseMover, "BMSSpeedVariance", "Speed variance", " %", { min = 0, max = 100, default = 45 }, function(v) bms.stealth.setSpeedVariance(v) end)
regSlider(MouseMover, "BMSOffsetMin", "Over/undershoot min", " px", { min = 0, max = 50, default = 5 }, function(v) bms.stealth.setOffsetMin(v) end)
regSlider(MouseMover, "BMSOffsetMax", "Over/undershoot max", " px", { min = 0, max = 50, default = 15 }, function(v) bms.stealth.setOffsetMax(v) end)

MouseMover:NewSection("Flag magnet")
regToggle(MouseMover, "BMSMagnet", "Enable flag magnet", false, function(v) bms.stealth.setMagnet(v) end)
regSlider(MouseMover, "BMSMagnetRange", "Magnet range", " px", { min = 10, max = 300, default = 80 }, function(v) bms.stealth.setMagnetRange(v) end)

MouseMover:NewSection("Triggerbot")
regToggle(MouseMover, "BMSTriggerbot", "Enable triggerbot", false, function(v) bms.stealth.setTriggerbot(v) end)
regSlider(MouseMover, "BMSTriggerRange", "Triggerbot range", " px", { min = 1, max = 50, default = 12 }, function(v) bms.stealth.setTriggerRange(v) end)

-- live token status: the PlaceFlag token is captured from your first manual
-- flag. Auto-flag / auto-play can't fire until it's been seen.
task.spawn(function()
    while true do
        local txt = bms.hasToken()
            and "Token: CAPTURED - auto-flag & auto-play are ready."
            or  "Token: not captured yet - place ONE flag manually to capture it."
        if tokenLblPlay then pcall(function() tokenLblPlay:Text(txt) end) end
        if tokenLblFlag then pcall(function() tokenLblFlag:Text(txt) end) end
        task.wait(0.5)
    end
end)

end  -- if bms

-- shared witherhook tabs (Movement / Players / Visuals / Misc / Settings / ...)
api.buildShared()

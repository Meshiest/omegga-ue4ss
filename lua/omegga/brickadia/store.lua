-- BR.store: Small tables a mod keeps across restarts, kept in the ue4ss omegga
-- plugin's own storage (one entry per name), so they live and get backed up
-- with omegga's data.
--
-- Lua can't wait on omegga from the game thread, so every Lua state keeps a
-- copy of all stores: omegga sends it when the bridge connects, and saves go
-- back in the background. Until that first copy arrives the stores aren't
-- ready, and reading one is an error rather than an empty table a later save
-- would write over the real data. Use BR.store.on_ready for anything that
-- runs at load.
local I = require("omegga.brickadia.internal")
local json = require("omegga.json")
local store = {}

-- names: { [name] = table }, dirty: names saved here that omegga hasn't
-- acknowledged yet (sent again after a reconnect), gen: a save counter per
-- name, so an old acknowledgement doesn't clear a newer save
_G.BR_STORE = _G.BR_STORE or { ready = false, names = {}, dirty = {}, gen = {}, waiting = {} }
local S = _G.BR_STORE

local function check(name)
    assert(type(name) == "string" and name:match("^[%w_%-%.]+$") and not name:match("^%."),
        "a store name is letters, digits, '_', '-' and '.'")
end

-- stores hold plain data; a copy keeps one open store's edits from reaching
-- another's table before it saves
local function copy(v) return json.decode(json.encode(v)) end

local function push(name)
    local Omegga = require("omegga")
    local gen = S.gen[name]
    local value = S.names[name]
    local args = value == nil and { "delete", name } or { "set", name, value }
    Omegga.call("ue4ss", "store", args, function(ok, err)
        if not ok then return I.report("BR.store " .. name, err) end
        if S.gen[name] == gen then S.dirty[name] = nil end
    end)
end

local function write(name, value)
    S.names[name] = value
    S.gen[name] = (S.gen[name] or 0) + 1
    S.dirty[name] = true
    push(name)
end

local function fetch()
    local Omegga = require("omegga")
    Omegga.call("ue4ss", "store", { "all" }, function(ok, all)
        if not ok or type(all) ~= "table" then return I.report("BR.store", all) end
        -- a save made here and not yet acknowledged is newer than omegga's copy
        for name, value in pairs(all) do
            if not S.dirty[name] then S.names[name] = value end
        end
        for name in pairs(S.dirty) do push(name) end
        if S.ready then return end
        S.ready = true
        local waiting = S.waiting
        S.waiting = {}
        for _, fn in ipairs(waiting) do
            local called, err = pcall(fn)
            if not called then I.report("BR.store.on_ready", err) end
        end
    end)
end

--- Whether the stores have arrived from omegga.
function store.ready() return S.ready end

--- Run fn once the stores have arrived (now, if they have).
function store.on_ready(fn)
    if S.ready then return fn() end
    S.waiting[#S.waiting + 1] = fn
end

local function need_ready()
    if not S.ready then error("BR.store isn't loaded from omegga yet; wait with BR.store.on_ready", 3) end
end

--- The table saved under `name`, or an empty table when nothing is.
function store.load(name)
    check(name)
    need_ready()
    local v = S.names[name]
    return type(v) == "table" and copy(v) or {}
end

--- Save `value` (a table of strings, numbers, booleans and tables) under `name`.
function store.save(name, value)
    check(name)
    need_ready()
    write(name, copy(value))
end

--- Forget what is saved under `name`.
function store.delete(name)
    check(name)
    need_ready()
    write(name, nil)
end

--- A table saved under `name` that saves itself: `s.data` is the table, change it
--- freely and call `s.save()`, or `s.set(key, value)` to change and save one key.
---
--- opts.version (a number) and opts.migrate ({ [n] = fn(data) }) keep the
--- layout current: data saved at an older version runs through each step up to
--- opts.version in order (fn changes the table it gets, or returns a new one)
--- and is saved at once. Data saved before the mod used versions counts as
--- version 1; a store with nothing saved starts at opts.version. The version is
--- kept with the data as `__version`, not in `s.data`. Data from a newer version
--- than opts.version is an error, rather than being overwritten.
---
---   local s = BR.store.open("arena", { version = 2, migrate = {
---       [2] = function(d) d.scores = d.points d.points = nil end,
---   } })
function store.open(name, opts)
    local data = store.load(name)
    local version = opts and opts.version
    local migrated = false
    if version then
        assert(type(version) == "number" and version >= 1, "a store version is a number from 1")
        local have = data.__version
        data.__version = nil
        if have == nil then have = next(data) == nil and version or 1 end
        assert(type(have) == "number", name .. " has a __version that isn't a number")
        if have > version then
            error(string.format("%s is at version %d, newer than this mod's %d", name, have, version), 2)
        end
        for v = have + 1, version do
            local step = opts.migrate and opts.migrate[v]
            if step then
                local out = step(data)
                if type(out) == "table" then data = out end
            end
        end
        migrated = have ~= version
    end
    local s = { data = data, version = version }
    function s.save()
        if not version then return store.save(name, s.data) end
        local out = {}
        for k, v in pairs(s.data) do out[k] = v end
        out.__version = version
        store.save(name, out)
    end
    function s.get(key) return s.data[key] end
    function s.set(key, value)
        s.data[key] = value
        s.save()
    end
    if migrated then s.save() end
    return s
end

local function refuse() error("BR.store isn't loaded from omegga yet; wait with BR.store.on_ready", 2) end

--- BR.store.open once the stores have arrived. Before then, an empty store
--- with `pending = true` whose save is an error, for code that may run before
--- omegga connects (a permission check, a placement) and can treat that as
--- "nothing saved". Keep the store only once it isn't pending.
function store.view(name, opts)
    if S.ready then return store.open(name, opts) end
    check(name)
    local s = { data = {}, pending = true, save = refuse, set = refuse }
    function s.get(key) return s.data[key] end
    return s
end

--- A store kept per world: BR.store.open under a name that carries the current
--- world's (BR.server.world), so a mod's data for one world stays apart from
--- another's and comes back when that world is loaded again. opts as
--- BR.store.open. Open it again after a world load (BR.event.on_ready) to
--- follow the new world.
function store.for_world(name, opts)
    local world = assert(I.BR.server.world(), "the current world isn't known")
    -- a world path may hold "/", which a store name can't
    return store.open("world." .. world:gsub("[^%w_%-%.]", "_") .. "." .. name, opts)
end

-- asked at load (a reload, or omegga already connected) and on every connect;
-- with no omegga connected the first ask goes nowhere and the connect answers
require("omegga").on_connect("BR.store", fetch)
fetch()

return store

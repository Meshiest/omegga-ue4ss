-- BR.behavior: Scripted brick types. A mod defines a behaviour once, for an asset
-- (or any bricks a match function picks), and it is called for every such brick
-- in the world: when it appears (there already, placed by anyone, loaded,
-- pasted), when it is removed (by any route: a player, a wire, Lua, a reset),
-- when a player presses or hits it, and on its own timers. Each brick gets a
-- `self` with saved state of its own.
--
-- The game has no "brick removed" broadcast, so the world grid is indexed and
-- re-read on an interval (0.2 s by default; about 3 ms for 4,600 bricks), and
-- what appeared or vanished since is dispatched. A brick handle is a stable
-- key for as long as the brick exists, so the comparison costs no calls into
-- the game; only a new brick's asset is read, once.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local behavior = {}

--- Seconds between reads of the world grid. Lower finds bricks sooner and costs more.
behavior.interval = 0.2

-- Definitions and the index outlive a reload of this module (as BR.timer's
-- timers do), so a reload doesn't drop behaviours other code defined.
_G.BR_BEHAVIORS = _G.BR_BEHAVIORS or { defs = {}, index = {} }
local shared = _G.BR_BEHAVIORS
local defs = shared.defs -- name -> def

local function asset_name(h)
    local a = BR.brick.info(h).asset
    return a and a:IsValid() and a:GetFName():ToString() or nil
end

local function call(def, what, ...)
    local fn = def.spec[what]
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then I.report("BR.behavior " .. def.name .. " " .. what, err) end
end

-- opened on first use: define() runs at a mod's load, before omegga connects
local function store_of(def)
    if def.store then return def.store end
    local s = BR.store.view("behavior-" .. def.name)
    if not s.pending then def.store = s end
    return s
end

local function make_self(def, h)
    local id = string.unpack("<I4", BR.brick.id(h))
    local key = tostring(id)
    local self = { brick = h, id = id, behavior = def.name }
    self.state = store_of(def).data[key] or {}
    --- Keep self.state (anything JSON can hold) across restarts.
    function self:save()
        local st = store_of(def)
        st.data[key] = self.state
        st.save()
    end
    --- Timers that end by themselves when the brick is removed.
    function self:every(seconds, fn, opts)
        local o = { owner = h, now = opts and opts.now }
        return BR.timer.every(seconds, function() return fn(self) end, o)
    end
    function self:after(seconds, fn) return BR.timer.after(seconds, function() fn(self) end, { owner = h }) end
    function self:forget()
        local st = store_of(def)
        st.data[key] = nil
        st.save()
    end
    return self
end

local function matches(def, h, asset)
    if def.assets then return asset ~= nil and def.assets[asset] == true end
    local ok, r = pcall(def.spec.match, h, asset)
    if not ok then
        I.report("BR.behavior " .. def.name .. " match", r)
        return false
    end
    return r == true
end

local function attach(def, h, entry, how)
    if not matches(def, h, entry.asset) then return end
    local self = make_self(def, h)
    entry.selves[def.name] = self
    call(def, "appear", self, how)
end

local function scan(how)
    local g = BR.world.global_grid()
    -- a new world: the old index names bricks that no longer exist, but they
    -- weren't removed (the save still has them), so they are dropped quietly
    if shared.grid ~= __addr(g) then
        shared.grid = __addr(g)
        shared.index = {}
        how = "existing"
    end
    local index = shared.index
    local present = {}
    for _, h in ipairs(BR.brick.in_grid(g)) do
        present[h] = true
        if not index[h] then
            local entry = { asset = asset_name(h), selves = {} }
            index[h] = entry
            for _, def in pairs(defs) do attach(def, h, entry, how) end
        end
    end
    for h, entry in pairs(index) do
        if not present[h] then
            index[h] = nil
            for name, self in pairs(entry.selves) do
                local def = defs[name]
                if def then
                    call(def, "remove", self)
                    if not def.spec.keep_state then self:forget() end
                end
            end
        end
    end
end

local function dispatch(what, h, ...)
    local entry = h and shared.index[h]
    if not entry then return end
    for name, self in pairs(entry.selves) do
        local def = defs[name]
        if def then call(def, what, self, ...) end
    end
end

-- one poller and one set of event listeners per Lua state
local function start()
    -- a reload replaces the poller, so the new module's code runs it
    if _G.BR_BEHAVIOR and _G.BR_BEHAVIOR.module == behavior then return end
    if _G.BR_BEHAVIOR then _G.BR_BEHAVIOR.stop() end
    local wait = 0
    local stops = {
        BR.event.tick(function(dt)
            wait = wait - dt
            if wait > 0 then return end
            wait = behavior.interval
            if next(defs) == nil or not BR.world.ready() then return end
            local ok, err = pcall(scan, "placed")
            if not ok then I.report("BR.behavior", err) end
        end),
        BR.event.on("interact", function(ps, info) dispatch("interact", info.brick, ps, info) end),
        BR.event.on("melee_hit", function(ps, info) dispatch("hit", info.brick, ps, info) end),
        BR.event.on("projectile_hit", function(ps, info) dispatch("hit", info.brick, ps, info) end),
    }
    _G.BR_BEHAVIOR = { module = behavior, stop = function() for _, s in ipairs(stops) do s() end end }
end

--- Give every brick that matches a behaviour. `spec`:
---   assets: asset names (BR.BrickAsset) it applies to, or
---   match: fn(handle, asset name) -> bool, for anything else (read the brick's
---     components with BR.component, its owner, its position...)
---   appear: fn(self, how), how = "existing" (there when the behaviour was
---     defined or the world loaded) or "placed" (it showed up since: built,
---     pasted, loaded as a prefab, placed by Lua)
---   remove: fn(self), once the brick is gone, by any route
---   interact: fn(self, player, info) when a player presses it
---   hit: fn(self, player, info) when a weapon or projectile hits it
---   keep_state: keep a removed brick's saved state (default: dropped)
--- self: { brick = handle, id = its persistent id, state = a table,
---   save(), every(seconds, fn(self)), after(seconds, fn(self)), forget() }.
--- self.state is saved by self:save() and comes back with the brick after a
--- restart (keyed by the brick's id in the world, in BR.store "behavior-<name>").
--- Defining a name again replaces it. Returns a function that removes the
--- behaviour (bricks get no remove call for that).
--- Covers the world grid; bricks on moving grids (vehicles, contraptions)
--- aren't included yet.
function behavior.define(name, spec)
    assert(type(name) == "string" and name:match("^[%w_%-]+$"), "a behaviour name is letters, digits, '_' and '-'")
    assert(spec.assets or spec.match, "a behaviour needs assets or match")
    local def = { name = name, spec = spec }
    if spec.assets then
        def.assets = {}
        for _, a in ipairs(spec.assets) do def.assets[a] = true end
    end
    for _, entry in pairs(shared.index) do entry.selves[name] = nil end
    defs[name] = def
    start()
    if BR.world.ready() then
        local ok, err = pcall(function()
            -- a first scan builds the index; after that the new behaviour is
            -- attached to what's indexed
            if shared.grid == nil then
                scan("existing")
            else
                for h, entry in pairs(shared.index) do attach(def, h, entry, "existing") end
            end
        end)
        if not ok then I.report("BR.behavior " .. name, err) end
    end
    return function()
        if defs[name] ~= def then return end
        defs[name] = nil
        for _, entry in pairs(shared.index) do entry.selves[name] = nil end
    end
end

--- The `self` of every brick that has behaviour `name` now.
function behavior.bricks(name)
    local out = {}
    for _, entry in pairs(shared.index) do
        local self = entry.selves[name]
        if self then out[#out + 1] = self end
    end
    return out
end

--- The behaviour `name`'s self for brick `handle`, or nil.
function behavior.of(name, handle)
    local entry = shared.index[handle]
    return entry and entry.selves[name]
end

return behavior

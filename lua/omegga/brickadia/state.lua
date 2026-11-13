-- BR.state: Shared values with change handlers. A mod sets a value under a key;
-- whoever watches that key (another mod in the same Lua state, a UI element, an
-- omegga plugin) hears each change. Values are anything JSON can hold.
--
-- omegga plugins see every change as the Lua event "state" ({ key, value }),
-- through the plugin's usual delivery (`ue4ss:state` on omegga, or a
-- subscription). opts.persist keeps a key's value across restarts (BR.store
-- "state").
local I = require("omegga.brickadia.internal")
local BR = I.BR
local state = {}

_G.BR_STATE = _G.BR_STATE or { values = {}, watchers = {}, persisted = {} }
local S = _G.BR_STATE

local saved
local function store()
    if saved then return saved end
    local s = BR.store.view("state")
    if s.pending then return s end
    saved = s
    for k, v in pairs(saved.data) do
        if S.values[k] == nil then S.values[k] = v end
        S.persisted[k] = true
    end
    return saved
end

local function equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local json = require("omegga.json")
    return json.encode(a) == json.encode(b)
end

local function notify(key, value, old)
    for _, list in ipairs({ S.watchers[key] or {}, S.watchers["*"] or {} }) do
        for _, fn in ipairs(list) do
            local ok, err = pcall(fn, value, old, key)
            if not ok then I.report("BR.state " .. key, err) end
        end
    end
    -- the omegga module is there in every Lua state the bridge serves; a state
    -- without a connection just has nobody to deliver to
    local ok, omegga = pcall(require, "omegga")
    if ok and omegga and omegga.emit then pcall(omegga.emit, "state", { key = key, value = value }) end
end

--- The value under `key`, or nil.
function state.get(key)
    store()
    return S.values[key]
end

--- Set `key` to `value` (nil removes it) and tell its watchers, if it changed.
--- opts.persist saves it with the world from now on.
function state.set(key, value, opts)
    assert(type(key) == "string", "a state key is a string")
    local st = store()
    local old = S.values[key]
    if opts and opts.persist then S.persisted[key] = true end
    if equal(old, value) then return end
    S.values[key] = value
    if S.persisted[key] then
        st.data[key] = value
        st.save()
    end
    notify(key, value, old)
end

--- Call fn(value, old, key) whenever `key` changes ("*": any key). With
--- opts.now, also once at once with the current value. Returns a function that
--- stops watching.
function state.watch(key, fn, opts)
    store()
    S.watchers[key] = S.watchers[key] or {}
    local list = S.watchers[key]
    list[#list + 1] = fn
    if opts and opts.now and key ~= "*" then
        local ok, err = pcall(fn, S.values[key], nil, key)
        if not ok then I.report("BR.state " .. key, err) end
    end
    return function()
        for i, f in ipairs(list) do if f == fn then table.remove(list, i) break end end
    end
end

--- Keep a BR.ui element in step with `key`: render(value) returns the options to
--- change (as el:set takes them); motion animates each change. Returns a stop
--- function.
---   BR.state.bind_ui("score.red", label, function(v) return { text = "Red " .. (v or 0) } end)
function state.bind_ui(key, element, render, motion)
    return state.watch(key, function(value) element:set(render(value), motion) end, { now = true })
end

--- Every key and value.
function state.all()
    store()
    local out = {}
    for k, v in pairs(S.values) do out[k] = v end
    return out
end

return state

-- BR.watch: One signal when something a mod cares about is gone, however it
-- went: a brick hammered, deleted by a selection, cleared, replaced by a load
-- or a transaction, removed by a gate; an entity or actor destroyed. Checked
-- five times a second, so the call comes within about 0.2 s.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local watch = {}

_G.BR_WATCH = _G.BR_WATCH or { list = {} }
local S = _G.BR_WATCH

local function gone(w)
    if w.brick then return not BR.brick.valid(w.target) end
    -- a destroyed actor is flagged garbage at once, before IsValid turns false
    return not I.alive(w.target)
end

local function check()
    local keep, fire = {}, {}
    for _, w in ipairs(S.list) do
        if not w.stopped then
            if gone(w) then fire[#fire + 1] = w else keep[#keep + 1] = w end
        end
    end
    S.list = keep
    -- in the order they were watched
    for _, w in ipairs(fire) do
        local ok, err = I.call("watch.removed", w.fn, w.target)
        if not ok then I.report("BR.watch.removed", err) end
    end
end

-- one checker per Lua state, replaced by each reload's
local function start()
    S.check = check
    if S.ticking then return end
    S.ticking = true
    local wait = 0
    BR.event.tick(function(dt)
        if #S.list == 0 then return end
        wait = wait - dt
        if wait > 0 then return end
        wait = 0.2
        S.check()
    end)
end

--- Call fn(target) once when `target` is gone: a brick handle, or an entity
--- or other actor. Returns a function that stops watching. Within about 0.2 s
--- of the removal; a brick's handle can't be read by then, so keep what fn
--- needs to know about it.
function watch.removed(target, fn)
    assert(type(fn) == "function", "watch.removed needs a function")
    local w = { target = target, fn = fn, brick = type(target) == "string" }
    if not w.brick then assert(target and target.IsValid and target:IsValid(), "a brick handle or a valid object") end
    start()
    table.insert(S.list, w)
    return function() w.stopped = true end
end

--- How many things are being watched.
function watch.count() return #S.list end

return watch

-- BR.profile: Where the server's time goes in Lua: every callback BR runs for a
-- mod (event handlers, ticks, timers, hooks, after-hooks, chat commands) timed
-- on a steady clock while profiling is on, by kind and by the handler's source
-- file and line, so a slow handler points at its mod. Off, it costs one check
-- per callback.
local I = require("omegga.brickadia.internal")
local profile = {}

local P = _G.BR_PROFILE

--- Start recording (keeping what was recorded so far; BR.profile.reset clears it).
function profile.start() P.on = true end

--- Stop recording.
function profile.stop() P.on = false end

--- Whether recording is on.
function profile.running() return P.on end

--- Forget what was recorded.
function profile.reset() P.stats = {} end

--- What was recorded, slowest in total first (opts.limit entries, default 20):
--- { kind ("event chat", "tick", "timer.every", "hook ServerPlace...",
--- "command /vote", or a BR.profile.measure name), source (file:line of the
--- handler), calls, total_ms, avg_ms, max_ms }.
function profile.report(opts)
    local out = {}
    for _, st in pairs(P.stats) do
        out[#out + 1] = { kind = st.kind, source = st.source, calls = st.calls, total_ms = st.total * 1000,
            avg_ms = st.total * 1000 / st.calls, max_ms = st.max * 1000 }
    end
    table.sort(out, function(a, b) return a.total_ms > b.total_ms end)
    local limit = (opts and opts.limit) or 20
    while #out > limit do out[#out] = nil end
    return out
end

--- Run fn(...) and record it under `name` when profiling is on (a mod timing
--- its own work, such as a world scan). Returns what fn returns; errors pass on.
function profile.measure(name, fn, ...)
    local r = table.pack(I.call(name, fn, ...))
    if not r[1] then error(r[2], 2) end
    return table.unpack(r, 2, r.n)
end

--- Profile for `seconds`, then hand fn the report (as BR.profile.report).
function profile.sample(seconds, fn, opts)
    profile.reset()
    profile.start()
    I.BR.timer.after(seconds, function()
        profile.stop()
        fn(profile.report(opts))
    end)
end

return profile

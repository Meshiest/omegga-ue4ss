-- BR.timer: Delayed and repeating calls on the game thread, in game time, and
-- wall-clock schedules (cron, "every day at 20:00").
--
-- All timers of a Lua state run from one tick callback. A timer can be tied to
-- an owner (a UObject such as a PlayerState, character or entity, or a brick
-- handle) and ends quietly once the owner is gone (a player leaving, an actor
-- destroyed, a brick removed), so a plugin needn't track what it scheduled.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local timer = {}

-- Timers and the clock outlive a reload of this module: a timer scheduled before
-- a reload still runs after it, from the one ticker. A reload installs its own
-- `run`, which the ticker calls.
_G.BR_TIMERS = _G.BR_TIMERS or { list = {}, now = 0, seq = 0 }
local shared = _G.BR_TIMERS
local timers = shared.list
shared.schedules = shared.schedules or {}
local schedules = shared.schedules

-- PlayerStates in the game's player list this tick, by address. A player who
-- leaves keeps a valid PlayerState for a while (the engine holds it for a
-- reconnect), so being in the list is what counts as present.
local present

local function players_present()
    if present then return present end
    present = {}
    I.game_state().PlayerArray:ForEach(function(_, p) present[__addr(p:get())] = true end)
    return present
end

local PLAYER_STATE
local function alive(owner)
    if owner == nil then return true end
    if type(owner) == "string" then return BR.brick.valid(owner) end
    if not owner:IsValid() then return false end
    PLAYER_STATE = PLAYER_STATE or StaticFindObject("/Script/Engine.PlayerState")
    if owner:IsA(PLAYER_STATE) then return players_present()[__addr(owner)] == true end
    return true
end

-- Cron: minute hour day-of-month month day-of-week, each `*`, a number, a
-- range `a-b`, a step `*/n` or `a-b/n`, or a comma list of those. Day of week
-- is 0-6 from Sunday (7 is Sunday too).
local FIELDS = { { 0, 59 }, { 0, 23 }, { 1, 31 }, { 1, 12 }, { 0, 7 } }

local function parse_field(text, lo, hi)
    local set = {}
    for part in text:gmatch("[^,]+") do
        local range, step = part:match("^([^/]+)/(%d+)$")
        range, step = range or part, tonumber(step) or 1
        local a, b
        if range == "*" then
            a, b = lo, hi
        else
            a, b = range:match("^(%d+)%-(%d+)$")
            a, b = tonumber(a), tonumber(b)
            if not a then
                a = tonumber(range)
                -- `5/15` means from 5 on, every 15
                b = (part:find("/") and hi) or a
            end
        end
        assert(a and b and a >= lo and b <= hi and a <= b and step > 0, "bad cron field " .. text)
        for v = a, b, step do set[v] = true end
    end
    return set
end

local function parse_cron(expr)
    local parts = {}
    for f in expr:gmatch("%S+") do parts[#parts + 1] = f end
    assert(#parts == 5, "a cron expression has 5 fields: minute hour day month weekday")
    local c = {}
    for i, f in ipairs(parts) do c[i] = parse_field(f, FIELDS[i][1], FIELDS[i][2]) end
    if c[5][7] then c[5][0] = true end
    -- with both day fields restricted, either one matching is enough (as cron does)
    c.days_either = parts[3] ~= "*" and parts[5] ~= "*"
    return c
end

local function cron_matches(c, t)
    if not (c[1][t.min] and c[2][t.hour] and c[4][t.month]) then return false end
    local dom, dow = c[3][t.day], c[5][t.wday - 1]
    if c.days_either then return dom == true or dow == true end
    return dom == true and dow == true
end

local function check_schedules()
    local minute = os.time() // 60
    if shared.minute == minute then return end
    shared.minute = minute
    local local_t, utc_t = os.date("*t"), os.date("!*t")
    for i = #schedules, 1, -1 do
        local sc = schedules[i]
        if sc.cancelled or not alive(sc.owner) then
            table.remove(schedules, i)
        elseif sc.last ~= minute and cron_matches(sc.cron, sc.utc and utc_t or local_t) then
            sc.last = minute
            local ok, result = pcall(sc.fn)
            if not ok then I.report("BR.timer schedule", result) end
            if result == false then sc.cancelled = true end
        end
    end
end

-- Due times come from sums of seconds, and rounding makes two that should be
-- equal (0.05 * 4 and 0.2 after the same start) differ in the last bits; they
-- are compared in whole microseconds, so those come out equal
local function tick_of(seconds) return math.floor(seconds * 1e6 + 0.5) end

local function run()
    local now = shared.now
    present = nil
    if #schedules > 0 then check_schedules() end
    local due = {}
    for i = #timers, 1, -1 do
        local t = timers[i]
        if t.cancelled or not alive(t.owner) then
            table.remove(timers, i)
        elseif tick_of(t.at) <= tick_of(now) then
            due[#due + 1] = t
        end
    end
    -- earliest first; of two due at the same time, the one made first
    table.sort(due, function(a, b)
        local ta, tb = tick_of(a.at), tick_of(b.at)
        if ta ~= tb then return ta < tb end
        return a.seq < b.seq
    end)
    for _, t in ipairs(due) do
        if not t.cancelled then
            local ok, result = I.call(t.every and "timer.every" or "timer.after", t.fn)
            if not ok then I.report("BR.timer", result) end
            if t.every and result ~= false and not t.cancelled then
                -- from the planned time, not from now, so a repeating timer doesn't
                -- drift; and as start + n * period rather than by adding the period
                -- each time, whose rounding would make timers due together (a 0.05 s
                -- one's 4th run and a 0.2 s one) fall due in a different order
                -- a timer made before a reload of this module has neither field
                t.base = t.base or t.at
                t.runs = (t.runs or 0) + 1
                t.at = t.base + t.every * t.runs
                -- behind by more than a period (a long tick): run once more now,
                -- and count on from here
                if t.at < now then t.base, t.runs, t.at = now, 0, now end
            else
                t.cancelled = true
            end
        end
    end
end

-- one ticker per Lua state, started by the first timer and kept across reloads
local function ensure_ticker()
    shared.run = run
    if shared.ticking then return end
    shared.ticking = true
    BR.event.tick(function(dt)
        shared.now = shared.now + dt
        shared.run()
    end)
end

local function add(delay, every, fn, opts)
    assert(type(delay) == "number" and delay >= 0, "a delay is seconds, 0 or more")
    assert(type(fn) == "function", "a timer needs a function")
    ensure_ticker()
    shared.seq = shared.seq + 1
    local t = { at = shared.now + delay, every = every, fn = fn, owner = opts and opts.owner, seq = shared.seq, runs = 0 }
    t.base = t.at
    timers[#timers + 1] = t
    return function() t.cancelled = true end
end

--- Call fn once, `seconds` from now (0 = the next tick). opts.owner ends it
--- early if the owner is gone first. Returns a function that cancels it.
function timer.after(seconds, fn, opts) return add(seconds, nil, fn, opts) end

--- Call fn every `seconds` (the first time `seconds` from now, or at once with
--- opts.now), until it returns false, the returned cancel function is called,
--- or opts.owner is gone. Ticks are the finest grain: a period shorter than a
--- tick runs once per tick.
function timer.every(seconds, fn, opts)
    assert(type(seconds) == "number" and seconds > 0, "a period is seconds, more than 0")
    return add(opts and opts.now and 0 or seconds, seconds, fn, opts)
end

--- Call fn at the start of the next tick: to act after the current call
--- finishes, such as reading a brick a transaction just placed.
function timer.next_tick(fn, opts) return add(0, nil, fn, opts) end

--- Call fn on a wall-clock schedule, a cron expression ("0 */2 * * *": every
--- two hours on the hour; "30 20 * * 5": Fridays at 20:30), in the server's
--- local time (opts.utc: UTC). Checked once a minute, so fn runs within a second
--- or so of the minute starting; never twice in one minute, and not in the
--- minute the schedule was made. Runs until fn returns false, the returned
--- cancel function is called, or opts.owner is gone.
function timer.cron(expr, fn, opts)
    assert(type(fn) == "function", "a schedule needs a function")
    local c = parse_cron(expr)
    ensure_ticker()
    local sc = { cron = c, fn = fn, utc = opts and opts.utc, owner = opts and opts.owner, last = os.time() // 60 }
    schedules[#schedules + 1] = sc
    return function() sc.cancelled = true end
end

--- Call fn every day at "HH:MM" (24-hour, the server's local time, or UTC with
--- opts.utc). As BR.timer.cron otherwise.
function timer.at(clock, fn, opts)
    local h, m = tostring(clock):match("^(%d%d?):(%d%d)$")
    h, m = tonumber(h), tonumber(m)
    assert(h and m and h < 24 and m < 60, "a time of day is \"HH:MM\"")
    return timer.cron(string.format("%d %d * * *", m, h), fn, opts)
end

--- Whether cron expression `expr` matches the time `t` (os.date("*t") form; now
--- in local time by default).
function timer.cron_matches(expr, t)
    return cron_matches(parse_cron(expr), t or os.date("*t"))
end

--- Run fn as a coroutine, so it can wait without blocking the game: inside it,
--- BR.timer.sleep(seconds) pauses and comes back later on the game thread.
--- opts.owner ends it (at its next wake-up) once the owner is gone. Returns a
--- function that cancels it.
---
---   BR.timer.async(function()
---       BR.server.chat("Round starts in 3")
---       for i = 2, 1, -1 do BR.timer.sleep(1) BR.server.chat(tostring(i)) end
---       BR.timer.sleep(1)
---       BR.world.next_round()
---   end)
function timer.async(fn, opts)
    local co = coroutine.create(fn)
    local cancelled = false
    local function step(...)
        if cancelled then return end
        local ok, err = coroutine.resume(co, ...)
        if not ok then I.report("BR.timer.async", debug.traceback(co, err)) return end
        if coroutine.status(co) == "dead" then return end
        -- it yielded a number of seconds to sleep
        timer.after(math.max(0, tonumber(err) or 0), function() step() end, opts)
    end
    step()
    return function() cancelled = true end
end

--- Pause the BR.timer.async coroutine this runs in for `seconds` (game time).
function timer.sleep(seconds)
    assert(coroutine.isyieldable(), "BR.timer.sleep only works inside BR.timer.async")
    coroutine.yield(seconds or 0)
end

--- Seconds of game time counted since the first timer in this Lua state.
function timer.now() return shared.now end

return timer

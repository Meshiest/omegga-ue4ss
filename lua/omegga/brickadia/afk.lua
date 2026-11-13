-- BR.afk: Who isn't playing: seconds since each player last did anything. A
-- player counts as active when where they look, where they are, or the keys
-- they hold change (sampled once a second), or the moment they chat, build,
-- interact with a brick (press, click, sit), shoot, swing a melee weapon,
-- emote, or crouch or stand up.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local afk = {}

-- per player key: { sig = last sample, at = clock of last activity, idle = reported }
_G.BR_AFK = _G.BR_AFK or { seen = {}, watchers = {}, clock = 0 }
local S = _G.BR_AFK

local function key(ps) return __addr(ps) end

local function signature(ps)
    local parts = {}
    local pc = BR.player.controller(ps)
    if pc then
        local ok, r = pcall(function() return pc:GetControlRotation() end)
        if ok and r then parts[#parts + 1] = string.format("%.0f,%.0f", r.Pitch, r.Yaw) end
    end
    local ch = BR.player.character(ps)
    if ch then
        local l = ch:K2_GetActorLocation()
        parts[#parts + 1] = string.format("%.0f,%.0f,%.0f", l.X / 10, l.Y / 10, l.Z / 10)
        parts[#parts + 1] = tostring(ch.PendingWeaponSimInputs.Keys)
    else
        parts[#parts + 1] = "dead"
    end
    return table.concat(parts, "|")
end

local function touch(ps)
    local s = S.seen[key(ps)]
    if s then s.at = S.clock end
end

local function sample()
    local present = {}
    local everyone = BR.player.list()
    for _, b in ipairs(BR.bot.list()) do everyone[#everyone + 1] = b end
    for _, ps in ipairs(everyone) do
        local k = key(ps)
        local bot = BR.bot.is_bot(ps)
        present[k] = true
        local sig = signature(ps)
        local s = S.seen[k]
        if not s then
            s = { sig = sig, at = S.clock }
            S.seen[k] = s
        elseif s.sig ~= sig then
            s.sig, s.at = sig, S.clock
        end
        for _, w in ipairs(S.watchers) do
            local over = (S.clock - s.at) >= w.seconds
            if (w.bots or not bot) and (w.state[k] or false) ~= over then
                w.state[k] = over
                -- coming back is only news to a watcher that saw them go
                if over or w.state_seen[k] then
                    local ok, err = pcall(w.fn, ps, over)
                    if not ok then I.report("BR.afk", err) end
                end
                w.state_seen[k] = over or nil
            end
        end
    end
    for k in pairs(S.seen) do if not present[k] then S.seen[k] = nil end end
end

-- one sampler per Lua state, replaced by each reload's
local function start()
    if _G.BR_AFK_POLL and _G.BR_AFK_POLL.module == afk then return end
    if _G.BR_AFK_POLL then _G.BR_AFK_POLL.stop() end
    local wait = 0
    _G.BR_AFK_POLL = { module = afk, stop = BR.event.tick(function(dt)
        S.clock = S.clock + dt
        wait = wait - dt
        if wait > 0 then return end
        wait = 1
        sample()
    end) }
    -- things a player does without moving still count, as they happen rather
    -- than at the next sample
    if S.activity then for _, stop in ipairs(S.activity) do stop() end end
    local function active(ps) if ps then touch(ps) end end
    S.activity = {}
    for _, name in ipairs({ "chat", "place", "interact", "shoot", "melee_hit", "emote" }) do
        S.activity[#S.activity + 1] = BR.event.on(name, active)
    end
    S.activity[#S.activity + 1] = BR.event.on_crouch(active)
end

--- Seconds since `ps` last did anything (0 until they have been watched for
--- a second: sampling starts with the first BR.afk call).
function afk.idle(ps)
    start()
    local s = S.seen[key(ps)]
    return s and (S.clock - s.at) or 0
end

--- Call fn(player, true) when a player has done nothing for `seconds`, and
--- fn(player, false) when they're back. opts.bots includes bots. Returns a
--- function that stops it.
---
---   BR.afk.on(300, function(ps, away)
---       if away then BR.mod.kick(ps, "away for 5 minutes") end
---   end)
function afk.on(seconds, fn, opts)
    assert(type(seconds) == "number" and seconds > 0, "seconds of inactivity, more than 0")
    start()
    local w = { seconds = seconds, fn = fn, state = {}, state_seen = {}, bots = opts and opts.bots }
    S.watchers[#S.watchers + 1] = w
    return function()
        for i, x in ipairs(S.watchers) do if x == w then table.remove(S.watchers, i) break end end
    end
end

--- Mark a player active now (a mod's own idea of activity: a vote, a button).
function afk.touch(ps)
    start()
    touch(ps)
end

return afk

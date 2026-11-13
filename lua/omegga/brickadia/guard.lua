-- BR.guard: Signals of suspicious play for a mod to act on: moving faster than
-- the character may, jumping across the map, flying without permission,
-- building faster than a person can. Detection only: what to do (log, warn,
-- kick, freeze) is the mod's call.
--
-- Movement is sampled 10 times a second from what the server simulates, which
-- the client's moves feed; the server already corrects moves it finds
-- impossible, so these mostly catch what gets through its tolerance, and
-- settings that disagree with the client (a speed change made without a team
-- rule). Bots are left out unless opts.bots.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local guard = {}

-- watchers by kind, and BR.world.teleport's recent moves, kept across reloads
-- `clock` counts seconds from the guard's own tick (os.clock is CPU time)
_G.BR_GUARD = _G.BR_GUARD or { watchers = { speed = {}, teleport = {}, fly = {}, build_rate = {} }, moved = {}, clock = 0 }
local shared = _G.BR_GUARD
local watchers = shared.watchers

local INTERVAL = 0.1

local function emit(kind, ps, amount, info)
    for _, w in ipairs(watchers[kind]) do
        if w.opts.bots or not BR.bot.is_bot(ps) then
            local ok, err = pcall(w.fn, ps, amount, info)
            if not ok then I.report("BR.guard " .. kind, err) end
        end
    end
end

-- per PlayerState: last sample { ch, x, y, z, over = { kind = polls in a row } }
local last = {}

local function sample(ps, dt)
    local ch = BR.player.character(ps)
    if not ch then
        last[__addr(ps)] = nil
        return
    end
    local key = __addr(ps)
    local l = ch:K2_GetActorLocation()
    local v = ch:GetVelocity()
    local cm = ch.CharacterMovement
    local m = BR.player.movement(ch)
    local prev = last[key]
    local now = { ch = __addr(ch), x = l.X, y = l.Y, z = l.Z, over = prev and prev.over or {} }
    last[key] = now
    -- a new character (spawn, respawn) starts fresh
    if not prev or prev.ch ~= now.ch then
        now.over = {}
        return
    end
    local function sustained(kind, bad, polls)
        now.over[kind] = bad and (now.over[kind] or 0) + 1 or 0
        return now.over[kind] == polls
    end

    if #watchers.speed > 0 then
        for _, w in ipairs(watchers.speed) do
            local max = cm:GetMaxSpeed() * (w.opts.tolerance or 1.25)
            local bad = m.mode == "walk" and max > 0 and m.speed > max
            if sustained("speed" .. tostring(w), bad, w.opts.sustain or 3) then
                if w.opts.bots or not BR.bot.is_bot(ps) then
                    local ok, err = pcall(w.fn, ps, m.speed / cm:GetMaxSpeed(), { character = ch, speed = m.speed, max = cm:GetMaxSpeed() })
                    if not ok then I.report("BR.guard speed", err) end
                end
            end
        end
    end

    if #watchers.teleport > 0 then
        local dx, dy, dz = now.x - prev.x, now.y - prev.y, now.z - prev.z
        local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
        local speed = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
        local by_us = shared.moved[now.ch] and shared.clock - shared.moved[now.ch] < 1
        for _, w in ipairs(watchers.teleport) do
            -- further than its own velocity explains, with room for a frame of
            -- acceleration and the poll's own jitter
            if not by_us and moved > speed * dt * 2 + (w.opts.slack or 300) then
                if w.opts.bots or not BR.bot.is_bot(ps) then
                    local ok, err = pcall(w.fn, ps, moved, { character = ch, from = { prev.x, prev.y, prev.z }, to = { now.x, now.y, now.z } })
                    if not ok then I.report("BR.guard teleport", err) end
                end
            end
        end
    end

    if #watchers.fly > 0 then
        local bad = m.mode == "fly" and not BR.perm.has(ps, "BR.Permission.Fly")
        if sustained("fly", bad, 2) then emit("fly", ps, 1, { character = ch }) end
    end
end

local function poll(dt)
    if #watchers.speed + #watchers.teleport + #watchers.fly == 0 then return end
    local seen = {}
    I.game_state().PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if not ps:IsValid() then return end
        seen[__addr(ps)] = true
        sample(ps, dt)
    end)
    for key in pairs(last) do if not seen[key] then last[key] = nil end end
    for ch, t in pairs(shared.moved) do if shared.clock - t > 2 then shared.moved[ch] = nil end end
end

-- one poller per Lua state; a reload replaces the previous module's
local function start()
    if _G.BR_GUARD_POLL and _G.BR_GUARD_POLL.module == last then return end
    if _G.BR_GUARD_POLL then _G.BR_GUARD_POLL.stop() end
    local wait = 0
    _G.BR_GUARD_POLL = { module = last, stop = BR.event.tick(function(dt)
        shared.clock = shared.clock + dt
        wait = wait - dt
        if wait > 0 then return end
        wait = INTERVAL
        poll(INTERVAL)
    end) }
end

-- place requests per player in the last second
local builds = {}
local function watch_builds()
    if shared.build_hook == builds then return end
    if shared.build_stop then shared.build_stop() end
    shared.build_hook = builds
    shared.build_stop = BR.event.on("place", function(ps)
        if not ps or #watchers.build_rate == 0 then return nil end
        local key = __addr(ps)
        local now = shared.clock
        local list = builds[key] or {}
        builds[key] = list
        list[#list + 1] = now
        while list[1] and now - list[1] > 1 do table.remove(list, 1) end
        for _, w in ipairs(watchers.build_rate) do
            if #list == (w.opts.max or 20) + 1 and (w.opts.bots or not BR.bot.is_bot(ps)) then
                local ok, err = pcall(w.fn, ps, #list, {})
                if not ok then I.report("BR.guard build_rate", err) end
            end
        end
        return nil
    end)
end

--- Call fn(player, amount, info) on a signal of `kind`:
---   "speed": faster on the ground than the character's own top speed (which
---     follows sprinting, crouching and team rules) times opts.tolerance
---     (default 1.25), for opts.sustain polls in a row (default 3, 0.3 s).
---     amount: speed over top speed. info: character, speed, max.
---   "teleport": moved further between two polls than its velocity explains,
---     plus opts.slack units (default 300). BR.world.teleport moves and new
---     characters don't count; the game's own teleports (teleporter bricks,
---     admin teleports) do, so check where they went. amount: the distance.
---     info: character, from, to.
---   "fly": flying for 0.2 s without the BR.Permission.Fly permission.
---   "build_rate": more than opts.max (default 20) place requests in a second
---     (a request may place many bricks). amount: requests in the last second.
--- opts.bots includes bots. Returns a function that stops it.
---
---   BR.guard.on("speed", function(ps, amount)
---       BR.server.chat(BR.player.info(ps).display_name .. " is moving " .. string.format("%.1f", amount) .. "x too fast")
---   end)
function guard.on(kind, fn, opts)
    local list = assert(watchers[kind], "a guard kind is speed, teleport, fly or build_rate")
    local w = { fn = fn, opts = opts or {} }
    list[#list + 1] = w
    start()
    if kind == "build_rate" then watch_builds() end
    return function()
        for i, x in ipairs(list) do if x == w then table.remove(list, i) break end end
    end
end

--- Tell the teleport signal that `actor` is being moved on purpose (a mod's own
--- teleport made some other way than BR.world.teleport).
function guard.expect_move(actor)
    shared.moved[__addr(actor)] = shared.clock
end

return guard

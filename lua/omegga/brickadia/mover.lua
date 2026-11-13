-- BR.mover: Entities (a dynamic grid: a platform, a door, a vehicle body; or
-- any other entity) moved along waypoints at a speed: elevators, moving
-- platforms, trains. Each step is an entity move transaction, the same change a
-- player's tools make, so clients see it. Turn physics off on what moves, or
-- physics fights the mover.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local mover = {}

local function dist(a, b)
    local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Move `entity` through `points` ({ {x, y, z}, ... }, world units) at
--- opts.speed units per second (default 200), starting from the first point.
--- opts.mode: "once" (default: stop at the last point), "loop" (back to the
--- first and round again), "ping_pong" (back and forth). opts.wait: seconds to
--- pause at each point (default 0). opts.rate: moves sent per second (default
--- 60; at 30 a rider sees it judder). opts.on_arrive(index) runs at each point.
--- The entity keeps the rotation it had. Returns the mover: m:stop(), m:pause(),
--- m:resume(), m.position.
function mover.path(entity, points, opts)
    assert(#points >= 2, "a path needs at least two points")
    opts = opts or {}
    local speed, mode, wait, rate = opts.speed or 200, opts.mode or "once", opts.wait or 0, opts.rate or 60
    local rot = BR.math.rot(entity:K2_GetActorRotation()):quat():array()
    local m = { position = { points[1][1], points[1][2], points[1][3] }, paused = false }
    local from, dir, travelled, waiting = 1, 1, 0, wait
    local function target_index()
        local to = from + dir
        if to > #points then
            if mode == "loop" then return 1 end
            if mode == "ping_pong" then return from - 1 end
            return nil
        end
        if to < 1 then return from + 1 end
        return to
    end
    local function send(pos)
        m.position = pos
        BR.brick.transaction(BR.player.server(), function(tx)
            tx.move_entity(entity, { pos = pos, rot = rot })
        end)
    end
    send(m.position)
    local stop = BR.timer.every(1 / rate, function()
        if m.paused then return end
        if not I.alive(entity) then return false end
        local step = speed / rate
        if waiting > 0 then
            waiting = waiting - 1 / rate
            return
        end
        local to = target_index()
        if not to then return false end
        local a, b = points[from], points[to]
        local len = dist(a, b)
        travelled = travelled + step
        if travelled >= len then
            send({ b[1], b[2], b[3] })
            travelled, waiting = 0, wait
            if mode == "ping_pong" and (to == #points or to == 1) then dir = -dir end
            from = to
            if mode == "loop" and from == 1 then dir = 1 end
            if opts.on_arrive then
                local ok, err = I.call("mover.on_arrive", opts.on_arrive, from)
                if not ok then I.report("BR.mover on_arrive", err) end
            end
            if mode == "once" and from == #points then return false end
            return
        end
        local t = travelled / len
        send({ a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t })
    end, { owner = entity })
    function m:stop() stop() end
    function m:pause() m.paused = true end
    function m:resume() m.paused = false end
    return m
end

return mover

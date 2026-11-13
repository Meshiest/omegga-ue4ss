-- BR.zone: Zones: the boxes Zone Projector bricks project (water, wind, building
-- rules, occupancy). A zone is named by its projector brick's BrickHandle.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local zone = {}

--- The component a zone projector carries; BR.component.data(zone, BR.zone.COMPONENT)
--- reads its settings (bWater, bDetectPlayers, ZoneWindForce, OccupantCount, ...).
zone.COMPONENT = "Component_Internal_AttachedZone"

--- Whether a brick projects a zone.
function zone.is_zone(handle)
    return BR.brick.valid(handle) and BR.component.handle(handle, zone.COMPONENT) ~= nil
end

--- Every zone on a grid, or on every grid (the global grid and each dynamic
--- one) when none is given. It looks at every brick, so it is slow on a large
--- build: keep the result rather than calling it every tick.
function zone.list(grid)
    local grids = grid and { grid } or { BR.world.global_grid() }
    if not grid then
        for _, g in ipairs(BR.world.grids()) do grids[#grids + 1] = g end
    end
    local ctype = BR.component.type(zone.COMPONENT)
    local out = {}
    for _, g in ipairs(grids) do
        for _, h in ipairs(BR.brick.in_grid(g)) do
            if BR.component.handle(h, ctype) then out[#out + 1] = h end
        end
    end
    return out
end

--- A zone's box as `{ center = {x, y, z}, half = {x, y, z}, grid = grid actor }`,
--- in its grid's coordinates (world coordinates on the global grid), or nil if
--- the brick is gone or projects no zone.
function zone.box(handle)
    if not BR.brick.valid(handle) then return nil end
    local b = BR.component.get(handle, zone.COMPONENT, "ComputedZoneBox")
    if not b then return nil end
    return {
        center = { b.Center.X, b.Center.Y, b.Center.Z },
        half = { b.HalfExtent.X, b.HalfExtent.Y, b.HalfExtent.Z },
        grid = BR.brick.grid(handle),
    }
end

local function to_grid(grid, loc)
    if __addr(grid) == __addr(BR.world.global_grid()) then return loc end
    -- a dynamic grid moves and turns; its bricks sit in the grid actor's space
    return StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):InverseTransformLocation(grid:GetTransform(), loc)
end

-- The game counts a character in a zone when its capsule touches the box, not
-- its centre: a capsule is a vertical segment (half height less the radius,
-- either side of the centre) grown by the radius, so it touches when the
-- segment is within a radius of the box. On a tilted grid the capsule is taken
-- as upright in the grid's space, which is close but not exact.
local function touches(box, ch)
    local p = to_grid(box.grid, ch:K2_GetActorLocation())
    local cap = ch.CapsuleComponent
    local r, h = cap:GetScaledCapsuleRadius(), cap:GetScaledCapsuleHalfHeight()
    local c, e = box.center, box.half
    local dx = math.max(0, math.abs(p.X - c[1]) - e[1])
    local dy = math.max(0, math.abs(p.Y - c[2]) - e[2])
    local dz = math.max(0, math.abs(p.Z - c[3]) - e[3] - (h - r))
    return dx * dx + dy * dy + dz * dz <= r * r
end

--- Whether a character is in a zone, by the game's measure (its capsule touches
--- the box), whatever the zone's own detection settings say. `box` is a
--- BR.zone.box result to reuse, for checking many characters against one zone.
function zone.contains(handle, ch, box)
    box = box or zone.box(handle)
    return box ~= nil and touches(box, ch)
end

--- PlayerStates of the players (bots included) whose characters are in a zone.
function zone.occupants(handle)
    local box = zone.box(handle)
    local out = {}
    if not box then return out end
    I.game_state().PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if not ps:IsValid() then return end
        local ch = BR.player.character(ps)
        if ch and touches(box, ch) then out[#out + 1] = ps end
    end)
    return out
end

return zone

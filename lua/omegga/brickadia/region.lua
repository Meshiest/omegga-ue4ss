-- BR.region: Areas of the world with their own build rules: plots that belong
-- to players, spawn areas nobody builds in, bans on bricks or components, and
-- an override for admins. Regions are saved (BR.store "regions"), so bought
-- plots survive restarts.
--
-- Every tool action that changes the world is checked against them before the
-- game acts: placing (by the full extent of what lands, so a dragged volume or
-- a long brick reaching over a border counts), deleting, painting, applicator
-- changes, resizing, selecting (which guards copy, cut and delete) and wiring.
-- A prefab's bricks are only known once they are down, so a prefab placement
-- is checked brick by brick right after, and removed whole if any brick broke
-- a rule.
--
-- Coordinates are grid units on the world grid (as BR.brick positions are).
-- Bricks on dynamic grids (vehicles, contraptions) aren't covered.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local region = {}

local SCRIPT = "/Script/Brickadia."
local BYPASS = "region.bypass"

-- regions, bans and toggles in _G, so a BR_RELOAD keeps them; hooks install once
_G.BR_REGION = _G.BR_REGION or { regions = nil, bans = nil, bypassing = {}, listeners = {}, pending = {} }
local S = _G.BR_REGION

local function valid(o) return o ~= nil and o:IsValid() end

-- Persistence --------------------------------------------------------------

-- the open store lives in S with the regions, so a reload of this module
-- doesn't lose it
local function load()
    if S.saved then return end
    local s = BR.store.view("regions", { version = 1 })
    -- before the stores arrive, nothing is saved yet: an empty set of regions
    -- to check against, replaced once they do (and a save is an error)
    if not s.pending then S.saved = s end
    S.regions = s.data.regions or {}
    S.bans = s.data.bans or { assets = {}, components = {} }
    S.default = s.data.default or "everyone"
end

local function save()
    load()
    if not S.saved then error("BR.store isn't loaded from omegga yet; define regions in BR.store.on_ready", 3) end
    S.saved.data.regions, S.saved.data.bans, S.saved.data.default = S.regions, S.bans, S.default
    S.saved.save()
end

-- Geometry -----------------------------------------------------------------

-- a box is { min = {x, y, z}, max = {x, y, z} }; touching faces don't overlap,
-- so building right up to a border is fine
local function overlaps(a, b)
    for i = 1, 3 do
        if a.min[i] >= b.max[i] or a.max[i] <= b.min[i] then return false end
    end
    return true
end

local function box_around(center, half)
    return { min = { center[1] - half[1], center[2] - half[2], center[3] - half[3] },
        max = { center[1] + half[1], center[2] + half[2], center[3] + half[3] } }
end

local function merge(a, b)
    if not a then return b end
    return { min = { math.min(a.min[1], b.min[1]), math.min(a.min[2], b.min[2]), math.min(a.min[3], b.min[3]) },
        max = { math.max(a.max[1], b.max[1]), math.max(a.max[2], b.max[2]), math.max(a.max[3], b.max[3]) } }
end

-- A brick's half size in the world for an orientation (0-23: up axis X+ 0..3,
-- X- 4..7, Y+ 8..11, Y- 12..15, Z+ 16..19, Z- 20..23; an odd turn about that
-- axis swaps the other two), measured on Release-EA3-CL-16507.
local function rotate(s, o)
    local up, odd = o // 8, (o % 2) == 1
    if up == 2 then return odd and { s[2], s[1], s[3] } or { s[1], s[2], s[3] } end
    if up == 0 then return odd and { s[3], s[1], s[2] } or { s[3], s[2], s[1] } end
    return odd and { s[1], s[3], s[2] } or { s[2], s[3], s[1] }
end

local half_sizes = {}
-- a fixed-size asset's half size (procedural assets have none of their own)
local function asset_half(asset)
    local key = __addr(asset)
    local hs = half_sizes[key]
    if hs == nil then
        local ok, v = pcall(function() return asset:GetBrickType():GetHalfSize() end)
        hs = ok and v and { v.X, v.Y, v.Z } or false
        half_sizes[key] = hs
    end
    return hs or nil
end

local function cdo(name) return StaticFindObject(SCRIPT .. "Default__" .. name) end

-- Whether a brick is on the world grid. Bricks on dynamic grids (vehicles,
-- contraptions) have positions in their grid's own space, near its origin, so
-- checking them against regions would refuse a car anywhere by the region at
-- the world's origin; they aren't covered.
local function on_world_grid(h)
    local g = BR.brick.grid(h)
    if not valid(g) then return true end
    local w = BR.world.global_grid()
    return __addr(g) == __addr(w) or __addr(g) == __addr(w.BrickGridComponent)
end

--- The box a brick takes up (grid units), from its position, size and
--- orientation. The handle must be valid.
local function brick_box(h)
    local pos = BR.brick.info(h).position
    local b = BR.raw.call(cdo("BRLuauBuilderLibrary"), "BRLuauBuilderLibrary", "FromBrick", { Brick = h }).ReturnValue
    local size = { string.unpack("<i4i4i4", BR.raw.call(cdo("BRLuauBuilderLibrary"), "BRLuauBuilderLibrary", "GetSize", { Self = b }).OutSize) }
    if size[1] == 0 and size[2] == 0 and size[3] == 0 then
        size = asset_half(BR.brick.info(h).asset) or { 5, 5, 6 }
    end
    local o = BR.raw.call(cdo("BRLuauBrickLibrary"), "BRLuauBrickLibrary", "GetOrientation", { Self = h }).ReturnValue:byte(1)
    return box_around(pos, rotate(size, o))
end

-- The box a dragged volume covers: the game lays out ceil(VolumeSize / 2)
-- copies per axis, 2 * (InstanceSize + Spacing) apart, from Position in the
-- direction of VolumeSigns (mirror mode: both ways). `half` is one copy's half
-- size in the world.
local function volume_box(p, at, half)
    local pos = { string.unpack("<i4i4i4", p, at.position + 1) }
    local inst = { string.unpack("<i4i4i4", p, at.instance + 1) }
    local spacing = { string.unpack("<i4i4i4", p, at.spacing + 1) }
    local vol = { string.unpack("<i4i4i4", p, at.volume + 1) }
    local signs = { string.unpack("<i4i4i4", p, at.signs + 1) }
    local mirror = p:byte(at.mirror + 1) ~= 0
    local first, last = {}, {}
    for i = 1, 3 do
        local n = math.max(1, (math.max(0, vol[i]) + 1) // 2)
        local reach = (n - 1) * 2 * (math.abs(inst[i]) + math.abs(spacing[i]))
        local dir = signs[i] < 0 and -1 or 1
        first[i], last[i] = pos[i], pos[i] + reach * dir
        if mirror then first[i] = pos[i] - reach * dir end
    end
    return merge(box_around(first, half), box_around(last, half))
end

-- Rules --------------------------------------------------------------------

local function bypassing(ps)
    if S.bypassing[__addr(ps)] then return true end
    local ok, has = pcall(BR.perm.has, ps, BYPASS)
    return ok and has
end

-- a region's own permission: its holders build there as owners do
local function has_permission(ps, name)
    local ok, has = pcall(BR.perm.has, ps, name)
    return ok and has
end

local function boxes_of(r)
    return r.boxes
end

local function owners_of(r)
    local set = {}
    for _, id in ipairs(r.owners or {}) do set[id] = true end
    return set
end

-- Zone bricks ---------------------------------------------------------------

-- Listing zones walks every brick on the world grid, so the list is kept and
-- taken again at most every ZONE_REFRESH seconds while a zone rule is set.
local ZONE_REFRESH = 10

-- world-grid zones as { brick, box = { min, max }, tag, building }
local function zones()
    local now = os.clock()
    if S.zones and S.zones_at and now - S.zones_at < ZONE_REFRESH then return S.zones end
    local out = {}
    local world = BR.world.global_grid()
    for _, h in ipairs(BR.zone.list(world)) do
        local b = BR.zone.box(h)
        if b then
            local c, e = b.center, b.half
            out[#out + 1] = {
                brick = h,
                box = { min = { c[1] - e[1], c[2] - e[2], c[3] - e[3] }, max = { c[1] + e[1], c[2] + e[2], c[3] + e[3] } },
                tag = BR.component.get(h, BR.zone.COMPONENT, "TagFilter"),
                building = BR.component.get(h, BR.zone.COMPONENT, "bIsBuildingZone") == true,
            }
        end
    end
    S.zones, S.zones_at = out, now
    return out
end

--- Whether `ps` may build in `box`: every region the box overlaps must let them,
--- and outside all regions the default rule applies. `action` "select" also
--- lets through regions that allow copying. Returns true, or false and the
--- region (nil for the default rule) that says no.
local function allows(ps, box, action)
    load()
    if bypassing(ps) then return true end
    local id = BR.player.id(ps)
    local any = false
    for name, r in pairs(S.regions) do
        for _, b in ipairs(boxes_of(r)) do
            if overlaps(box, b) then
                any = true
                local ok = r.build == "everyone"
                    or (r.build ~= "nobody" and owners_of(r)[id])
                    or (action == "select" and r.copy)
                    or (r.permission ~= nil and has_permission(ps, r.permission))
                if not ok then return false, name end
                break
            end
        end
    end
    if S.zone_rule then
        for _, z in ipairs(zones()) do
            if overlaps(box, z.box) then
                local ok, verdict, message = pcall(S.zone_rule, z, ps, action)
                if not ok then
                    I.report("BR.region.zone_rule", verdict)
                elseif verdict == false then
                    -- a zone refusal travels as a table where a region's name would
                    return false, { zone = z.brick, message = message }
                elseif verdict == true then
                    any = true
                end
            end
        end
    end
    if not any and S.default == "nobody" then return false, nil end
    return true
end

local function set_of(list)
    local set = {}
    for _, v in ipairs(list or {}) do set[v] = true end
    return set
end

-- the asset names and component names banned where `box` is (everywhere, and
-- in each region it overlaps)
local function bans_at(box)
    load()
    local assets, components = set_of(S.bans.assets), set_of(S.bans.components)
    for _, r in pairs(S.regions) do
        for _, b in ipairs(boxes_of(r)) do
            if overlaps(box, b) then
                for _, a in ipairs(r.ban_assets or {}) do assets[a] = true end
                for _, c in ipairs(r.ban_components or {}) do components[c] = true end
                break
            end
        end
    end
    return assets, components
end

local function component_types(names)
    local out = {}
    for name in pairs(names) do
        local ok, t = pcall(BR.component.type, name)
        if ok and t then out[#out + 1] = { name = name, type = t } end
    end
    return out
end

-- the banned component a placed brick has, if any
local function banned_component(h, components)
    for _, c in ipairs(component_types(components)) do
        if BR.component.handle(h, c.type) then return c.name end
    end
end

-- Refusals -------------------------------------------------------------------

local function refuse(ps, info)
    local zone = type(info.region) == "table" and info.region or nil
    if zone then
        info.region, info.zone = nil, zone.zone
    end
    for _, fn in ipairs(S.listeners) do
        local ok, err = pcall(fn, ps, info)
        if not ok then I.report("BR.region.on_refused", err) end
    end
    if info.quiet then return false end
    local r = info.region and S.regions[info.region]
    local text = (r and r.message)
        or (zone and (zone.message or "You can't build in this zone"))
        or (info.banned and ("<b>" .. info.banned .. "</> isn't allowed here"))
        or (info.region and ("You can't build in <b>" .. info.region .. "</>"))
        or "You can't build here"
    if BR.player.connected(ps) then pcall(BR.player.status, ps, text, true) end
    return false
end

-- Hooks --------------------------------------------------------------------

local PLACER = SCRIPT .. "BRTool_Placer:"

-- Byte offsets in each placement call's parameters, read from the game's own
-- reflection by name, so a game update that moves them doesn't break this.
local function offsets(fn)
    local l = I.layout(PLACER .. fn)
    local function at(name) return assert(l[name], fn .. " has no parameter " .. name).offset end
    return { context = l.Context and l.Context.offset, position = at("Position"), orientation = l.Orientation and l.Orientation.offset, instance = at("InstanceSize"),
        spacing = at("InstanceSpacing"), volume = at("VolumeSize"), signs = at("VolumeSigns"), mirror = at("bMirrorMode"),
        brick_type = l.BrickType and l.BrickType.offset }
end
-- filled on first use rather than while modules load
local BRICK_VOLUME, ENTITY_VOLUME, PREFAB_VOLUME
local function layouts()
    if BRICK_VOLUME then return end
    BRICK_VOLUME = offsets("ServerPlaceSimpleBrickVolume")
    ENTITY_VOLUME = offsets("ServerPlaceSimpleEntityVolume")
    PREFAB_VOLUME = offsets("ServerPlaceCurrentPrefab")
    -- inside the BrickType parameter (an FBrickType struct): the asset, then the
    -- procedural size
    local bt = StaticFindObject(SCRIPT .. "BrickType")
    local is_struct = bt and bt:IsValid() and bt:GetClass():GetFName():ToString() == "ScriptStruct"
    local asset = is_struct and I.find_field(bt, "BrickAsset")
    local size = is_struct and I.find_field(bt, "ProceduralSize")
    BRICK_VOLUME.asset = BRICK_VOLUME.brick_type + (asset and asset:GetOffset_Internal() or 0)
    BRICK_VOLUME.size = BRICK_VOLUME.brick_type + (size and size:GetOffset_Internal() or 8)
end

-- The prefab being placed, as a half size: the placer's CurrentPlaceable
-- (what the player holds), else the largest prefab they carry. Only bounds
-- where to look for what landed; the bricks themselves are what get checked.
local function held_prefab_half(ps, placer)
    local ok, s = pcall(function()
        local cur = placer.CurrentPlaceable
        if cur.Type ~= 3 then return nil end
        local size = cur.PrefabInfo.Counts.Size
        return math.max(size.X, size.Y, size.Z)
    end)
    if ok and s and s > 0 then return s end
    local ch = BR.player.character(ps)
    local best = 0
    local function consider(e)
        local ok, s = pcall(function()
            if e.Placeable.Type ~= 3 then return nil end
            local size = e.Placeable.PrefabInfo.Counts.Size
            return math.max(size.X, size.Y, size.Z)
        end)
        if ok and s and s > best then best = s end
    end
    if ch then
        consider(ch:GetCharacterTempInventoryEntry())
        for i = 0, 9 do
            local ok, e = pcall(function() return ch:GetCharacterInventoryEntry(i) end)
            if ok and e then consider(e) end
        end
    end
    return best > 0 and best or 500
end

local SNAPSHOT_MAX = 50000

-- bricks in `box`, as a set of handle bytes, or nil if there were too many to
-- be sure of
local function snapshot(box)
    local found = BR.brick.in_box(box.min, box.max, { max = SNAPSHOT_MAX })
    if #found >= SNAPSHOT_MAX then return nil end
    local set = {}
    for _, h in ipairs(found) do set[h] = true end
    return set, found
end

-- the dynamic grids (vehicles, contraptions) in the world, by address
local function dynamic_grids()
    local found = {}
    StaticFindObject("/Script/Engine.Default__GameplayStatics")
        :GetAllActorsOfClass(BR.world.context(), StaticFindObject(SCRIPT .. "BrickGridDynamicActor"), found)
    local set = {}
    for _, a in ipairs(found) do
        local g = a:get()
        if valid(g) then set[__addr(g)] = g end
    end
    return set
end

-- what a brick breaks, if anything: the region rules where `box` is, and the
-- bans there for its asset and components
local function violation(ps, h, box)
    local ok, name = allows(ps, box, "build")
    if not ok then return { action = "place", region = name } end
    local assets, components = bans_at(box)
    local asset = BR.brick.info(h).asset
    local an = valid(asset) and asset:GetFName():ToString()
    if an and assets[an] then return { action = "place", banned = an } end
    local cn = next(components) and banned_component(h, components)
    if cn then return { action = "place", banned = cn } end
end

-- After a placement: what it added, each brick checked as if placed alone. A
-- paste can also bring dynamic grids along (a vehicle, a door); each new grid
-- is checked by its bounds in the world and by its bricks. Anything breaking a
-- rule takes the whole placement out, grids included.
local function check_placed(ps, before, box, grids_before)
    local _, after = snapshot(box)
    if not after then return end
    local placed = {}
    for _, h in ipairs(after) do if not before[h] then placed[#placed + 1] = h end end
    local new_grids = {}
    if grids_before then
        for key, g in pairs(dynamic_grids()) do if not grids_before[key] then new_grids[#new_grids + 1] = g end end
    end
    if #placed == 0 and #new_grids == 0 then return end
    local why
    for _, h in ipairs(placed) do
        if BR.brick.valid(h) then
            why = violation(ps, h, brick_box(h))
            if why then break end
        end
    end
    if not why then
        for _, g in ipairs(new_grids) do
            local origin, extent = {}, {}
            g:GetActorBounds(false, origin, extent, false)
            local gbox = box_around({ origin.X, origin.Y, origin.Z }, { extent.X, extent.Y, extent.Z })
            local bricks = BR.brick.in_box({ -2000000000, -2000000000, -2000000000 }, { 2000000000, 2000000000, 2000000000 }, { grid = g, max = SNAPSHOT_MAX })
            if #bricks == 0 then
                local ok, name = allows(ps, gbox, "build")
                if not ok then why = { action = "place", region = name } end
            end
            for _, h in ipairs(bricks) do
                -- a grid's bricks are judged where the grid is in the world
                why = violation(ps, h, gbox)
                if why then break end
            end
            if why then break end
        end
    end
    if not why then return end
    if #placed > 0 then
        BR.brick.transaction(BR.player.server(), function(tx)
            for _, h in ipairs(placed) do if BR.brick.valid(h) then tx.delete(BR.brick.id(h)) end end
        end)
    end
    for _, g in ipairs(new_grids) do if valid(g) then pcall(BR.entity.delete, g) end end
    why.removed = #placed
    why.removed_grids = #new_grids
    refuse(ps, why)
end

local function before_placing(key, ps, box)
    local before = snapshot(box)
    if before then S.pending[key] = { ps = ps, before = before, box = box, grids = dynamic_grids() } end
end

local function after_placing(key)
    local p = S.pending[key]
    S.pending[key] = nil
    if p then check_placed(p.ps, p.before, p.box, p.grids) end
end

-- Whether a placement lands on the world grid. FBRPlacementContext: Type@0
-- (EBRPlacementContextType: ExistingBrickGrid 0, NewBrickGrid 1,
-- JointConnectedBrickGrid 2), ExistingBrickGrid@8. On another grid the
-- position is in that grid's own space, so it isn't checked (see on_world_grid).
local function places_on_world(p, at)
    if not at.context then return true end
    if p:byte(at.context + 1) ~= 0 then return false end
    local g = BR.raw.obj(p:sub(at.context + 9, at.context + 16))
    if not valid(g) then return true end
    return __addr(g) == __addr(BR.world.global_grid().BrickGridComponent)
end

local function brick_volume(tool, p)
    layouts()
    local ps = BR.player.of(tool)
    if not ps or bypassing(ps) then return nil end
    if not places_on_world(p, BRICK_VOLUME) then return nil end
    local asset = BR.raw.obj(p:sub(BRICK_VOLUME.asset + 1, BRICK_VOLUME.asset + 8))
    local size = { string.unpack("<i4i4i4", p, BRICK_VOLUME.size + 1) }
    if size[1] == 0 and size[2] == 0 and size[3] == 0 then size = (valid(asset) and asset_half(asset)) or { 5, 5, 6 } end
    local box = volume_box(p, BRICK_VOLUME, rotate(size, p:byte(BRICK_VOLUME.orientation + 1)))
    local ok, name = allows(ps, box, "build")
    if not ok then return refuse(ps, { action = "place", region = name }) end
    local assets, components = bans_at(box)
    local an = valid(asset) and asset:GetFName():ToString()
    if an and assets[an] then return refuse(ps, { action = "place", banned = an }) end
    -- an asset can bring components along (a gate brick): checked once placed
    if next(components) then before_placing(__addr(tool), ps, box) end
    return nil
end

local function entity_volume(tool, p)
    layouts()
    local ps = BR.player.of(tool)
    if not ps or bypassing(ps) then return nil end
    if not places_on_world(p, ENTITY_VOLUME) then return nil end
    local inst = { string.unpack("<i4i4i4", p, ENTITY_VOLUME.instance + 1) }
    local half = { math.max(1, math.abs(inst[1])), math.max(1, math.abs(inst[2])), math.max(1, math.abs(inst[3])) }
    local ok, name = allows(ps, volume_box(p, ENTITY_VOLUME, half), "build")
    if not ok then return refuse(ps, { action = "place", region = name }) end
    return nil
end

local function prefab_volume(tool, p)
    layouts()
    local ps = BR.player.of(tool)
    if not ps or bypassing(ps) then return nil end
    if not places_on_world(p, PREFAB_VOLUME) then return nil end
    local r = held_prefab_half(ps, tool)
    local box = volume_box(p, PREFAB_VOLUME, { r, r, r })
    -- the anchor itself in a forbidden place needs no wait
    local pos = { string.unpack("<i4i4i4", p, PREFAB_VOLUME.position + 1) }
    local ok, name = allows(ps, box_around(pos, { 1, 1, 1 }), "build")
    if not ok then return refuse(ps, { action = "place", region = name }) end
    before_placing(__addr(tool), ps, box)
    return nil
end

local function brick_handle_at(p, offset) return p:sub(offset + 1, offset + 8) end

-- a parameter's byte offset in a call, by name (see offsets above)
local function param(path, name)
    return assert(I.layout(path)[name], path .. " has no parameter " .. name).offset
end
local function ivec_at(p, offset) return { string.unpack("<i4i4i4", p, offset + 1) } end

-- an action on one existing brick: the player must be allowed where it is
local function on_brick(action, path, name, select)
    local at = param(path, name)
    return function(tool, p)
        local ps = BR.player.of(tool)
        if not ps or bypassing(ps) then return nil end
        local h = brick_handle_at(p, at)
        if not BR.brick.valid(h) then return nil end
        if not on_world_grid(h) then return nil end
        local ok, name = allows(ps, brick_box(h), select and "select" or "build")
        if not ok then return refuse(ps, { action = action, region = name }) end
        return nil
    end
end

local RESIZE = SCRIPT .. "BRTool_Resizer:ServerApplyBrickTransform"
local function resize(tool, p)
    local ps = BR.player.of(tool)
    if not ps or bypassing(ps) then return nil end
    local h = brick_handle_at(p, param(RESIZE, "BrickHandle"))
    if not BR.brick.valid(h) then return nil end
    if not on_world_grid(h) then return nil end
    local ok, name = allows(ps, brick_box(h), "build")
    if ok then
        local center = ivec_at(p, param(RESIZE, "InNewCenter"))
        local extent = ivec_at(p, param(RESIZE, "InNewExtent"))
        ok, name = allows(ps, box_around(center, { math.abs(extent[1]), math.abs(extent[2]), math.abs(extent[3]) }), "build")
    end
    if not ok then return refuse(ps, { action = "resize", region = name }) end
    return nil
end

-- the applicator adds components by type; a banned one is refused
local APPLY = SCRIPT .. "BRTool_Applicator:ServerApplyBrickState"
local function apply_state(tool, p)
    local ps = BR.player.of(tool)
    if not ps or bypassing(ps) then return nil end
    local h = brick_handle_at(p, param(APPLY, "BrickHandle"))
    if not BR.brick.valid(h) then return nil end
    if not on_world_grid(h) then return nil end
    local b = brick_box(h)
    local ok, name = allows(ps, b, "build")
    if not ok then return refuse(ps, { action = "apply", region = name }) end
    local _, components = bans_at(b)
    if not next(components) then return nil end
    -- ComponentTypes is a TArray of type pointers: compared by address only
    local data, num = string.unpack("<I8i4", p, param(APPLY, "ComponentTypes") + 1)
    if data == 0 or num <= 0 or num > 256 then return nil end
    local present = {}
    local raw = __peek(data, num * 8)
    for i = 0, num - 1 do present[string.unpack("<I8", raw, i * 8 + 1)] = true end
    for _, c in ipairs(component_types(components)) do
        if present[__addr(c.type)] then return refuse(ps, { action = "apply", banned = c.name }) end
    end
    return nil
end

-- adding one component: the brick's region must allow building, and the type
-- must not be banned there
local ADD = SCRIPT .. "BRTool_Applicator:ServerAddComponent"
local function add_component(tool, p)
    local ps = BR.player.of(tool)
    if not ps or bypassing(ps) then return nil end
    local h = brick_handle_at(p, param(ADD, "BrickHandle"))
    if not BR.brick.valid(h) then return nil end
    if not on_world_grid(h) then return nil end
    local b = brick_box(h)
    local ok, name = allows(ps, b, "build")
    if not ok then return refuse(ps, { action = "apply", region = name }) end
    local _, components = bans_at(b)
    if not next(components) then return nil end
    local added = string.unpack("<I8", p, param(ADD, "Component") + 1)
    for _, c in ipairs(component_types(components)) do
        if __addr(c.type) == added then return refuse(ps, { action = "apply", banned = c.name }) end
    end
    return nil
end

-- pasting a brick's state brings whatever components it had: strip banned ones after
local PASTE = SCRIPT .. "BRTool_Applicator:ServerPasteBrick"
local function after_paste(tool, p)
    local ps = BR.player.of(tool)
    if not ps or bypassing(ps) then return end
    local h = brick_handle_at(p, param(PASTE, "BrickHandle"))
    if not BR.brick.valid(h) then return end
    local _, components = bans_at(brick_box(h))
    local strip = {}
    for _, c in ipairs(component_types(components)) do
        if BR.component.handle(h, c.type) then strip[#strip + 1] = c end
    end
    if #strip == 0 then return end
    BR.brick.transaction(BR.player.server(), function(tx)
        for _, c in ipairs(strip) do tx.detach(BR.brick.id(h), c.type) end
    end)
    refuse(ps, { action = "paste", banned = strip[1].name })
end

-- selecting by box: SelectionCenter and SelectionSize (half extents) on a grid
local SELECT_BOX = SCRIPT .. "BRTool_Selector:ServerSelectInBox"
local function select_box(tool, p)
    local ps = BR.player.of(tool)
    if not ps or bypassing(ps) then return nil end
    local g = param(SELECT_BOX, "TargetGrid")
    local grid = BR.raw.obj(p:sub(g + 1, g + 8))
    -- TargetGrid is a grid component; the world grid's belongs to the global grid actor
    if valid(grid) and __addr(grid) ~= __addr(BR.world.global_grid().BrickGridComponent) then return nil end
    local center = ivec_at(p, param(SELECT_BOX, "SelectionCenter"))
    local size = ivec_at(p, param(SELECT_BOX, "SelectionSize"))
    local ok, name = allows(ps, box_around(center, { math.abs(size[1]), math.abs(size[2]), math.abs(size[3]) }), "select")
    if not ok then return refuse(ps, { action = "select", region = name }) end
    return nil
end

-- delete or cut a selection: the fallback box, when the call uses one (the
-- selection itself was checked when made)
local function selection_op(path)
    return function(tool, p)
        local ps = BR.player.of(tool)
        if not ps or bypassing(ps) then return nil end
        if p:byte(param(path, "bUseFallbackBox") + 1) == 0 then return nil end
        local center = ivec_at(p, param(path, "FallbackSelectionCenter"))
        local size = ivec_at(p, param(path, "FallbackSelectionSize"))
        local ok, name = allows(ps, box_around(center, { math.abs(size[1]), math.abs(size[2]), math.abs(size[3]) }), "build")
        if not ok then return refuse(ps, { action = "selection", region = name }) end
        return nil
    end
end

-- the brick behind a wire port reference (its first 8 bytes are the component)
local function port_brick(ref)
    local lib = cdo("BRLuauComponentLibrary")
    if not BR.raw.bool(BR.raw.call(lib, "BRLuauComponentLibrary", "IsAlive", { Self = ref:sub(1, 8) }).ReturnValue) then return nil end
    local h = BR.raw.call(lib, "BRLuauComponentLibrary", "GetBrick", { Self = ref:sub(1, 8) }).ReturnValue
    if BR.brick.valid(h) then return h end
end

local function wires(path, names)
    return function(tool, p)
        local ps = BR.player.of(tool)
        if not ps or bypassing(ps) then return nil end
        for _, n in ipairs(names) do
            local off = param(path, n)
            local h = port_brick(p:sub(off + 1, off + 16))
            if h then
                local ok, name = allows(ps, brick_box(h), "build")
                if not ok then return refuse(ps, { action = "wire", region = name }) end
            end
        end
        return nil
    end
end

-- The hooks are installed once per Lua state and call through S.impl, which
-- each load of this module fills, so a BR_RELOAD changes what they do.
S.impl = S.impl or {}
local function hook()
    local install = not S.hooked
    -- each function is hooked once per Lua state; a reload only swaps what the
    -- hook calls, and a guard added since gets its hook then. A state hooked
    -- before paths were recorded has a hook for every guard it registered.
    if not S.hooked_paths then
        S.hooked_paths = {}
        if S.hooked then for path in pairs(S.impl) do S.hooked_paths[path] = true end end
    end
    S.hooked = true
    local function guard(path, fn)
        S.impl[path] = fn
        if S.hooked_paths[path] then return end
        S.hooked_paths[path] = true
        BR.event.hook(path, function(self, p)
            local ok, r = pcall(S.impl[path], self, p)
            if not ok then I.report("BR.region " .. path, r) return nil end
            return r
        end)
    end
    guard(PLACER .. "ServerPlaceSimpleBrickVolume", brick_volume)
    guard(PLACER .. "ServerPlaceSimpleEntityVolume", entity_volume)
    guard(PLACER .. "ServerPlaceCurrentPrefab", prefab_volume)
    local function tool_fn(t, f) return SCRIPT .. "BRTool_" .. t .. ":" .. f end
    local function brick_action(action, path, name, select) guard(path, on_brick(action, path, name, select)) end
    brick_action("delete", tool_fn("Hammer", "ServerHammerBrick"), "BrickHandle")
    brick_action("delete", SCRIPT .. "BRPlacerControlMode_Delete:ServerHammerBrick", "BrickHandle")
    brick_action("paint", tool_fn("Painter", "ServerPaintBrick"), "BrickHandle")
    brick_action("paint", tool_fn("Painter", "ServerFillPaint"), "BrickHandle")
    guard(tool_fn("Applicator", "ServerApplyBrickState"), apply_state)
    brick_action("paste", tool_fn("Applicator", "ServerPasteBrick"), "BrickHandle")
    brick_action("reset", tool_fn("Applicator", "ServerResetBrickState"), "BrickHandle")
    brick_action("remove_component", tool_fn("Applicator", "ServerRemoveComponent"), "BrickHandle")
    brick_action("apply", tool_fn("Applicator", "ServerSetVisible"), "BrickHandle")
    brick_action("apply", tool_fn("Applicator", "ServerSetCollisionChannels"), "BrickHandle")
    brick_action("apply", tool_fn("Applicator", "ServerSetComponentEnabledProp"), "BrickHandle")
    brick_action("apply", tool_fn("Applicator", "ServerModifyComponentV3"), "BrickHandle")
    guard(tool_fn("Applicator", "ServerAddComponent"), add_component)
    guard(tool_fn("Resizer", "ServerApplyBrickTransform"), resize)
    brick_action("rotate", tool_fn("Resizer", "ServerApplyBrickRotation"), "BrickHandle")
    brick_action("rotate", tool_fn("Resizer", "ServerApplyBrickDirection"), "BrickHandle")
    guard(tool_fn("Selector", "ServerSelectInBox"), select_box)
    brick_action("select", tool_fn("Selector", "ServerSelectBrick"), "Brick", true)
    guard(tool_fn("Selector", "ServerDeleteSelection"), selection_op(tool_fn("Selector", "ServerDeleteSelection")))
    guard(tool_fn("Selector", "ServerCopySelection"), selection_op(tool_fn("Selector", "ServerCopySelection")))
    local connector = function(f) return tool_fn("Connector", f) end
    guard(connector("ServerConnectOrDisconnectComponentWire"), wires(connector("ServerConnectOrDisconnectComponentWire"), { "SourcePortRef", "TargetPortRef" }))
    guard(connector("ServerReplaceComponentWire"), wires(connector("ServerReplaceComponentWire"), { "OldSourceRef", "OldTargetRef", "NewSourceRef", "NewTargetRef" }))
    guard(connector("ServerDisconnectComponentWirePort"), wires(connector("ServerDisconnectComponentWirePort"), { "PortRef" }))
    -- the after-hooks, like the others, call whatever this load put in S.impl
    S.impl.after_placing = after_placing
    S.impl.after_paste = after_paste
    if not install then return end
    for _, path in ipairs({ PLACER .. "ServerPlaceSimpleBrickVolume", PLACER .. "ServerPlaceCurrentPrefab" }) do
        BR.event.after(path, function(self)
            local ok, err = pcall(S.impl.after_placing, __addr(self))
            if not ok then I.report("BR.region placing", err) end
        end)
    end
    BR.event.after(SCRIPT .. "BRTool_Applicator:ServerPasteBrick", function(self, p)
        local ok, err = pcall(S.impl.after_paste, self, p)
        if not ok then I.report("BR.region paste", err) end
    end)
end

-- defined here unless something defined it already: defining again would
-- reset the roles an admin gave it
if not BR.perm.defined()[BYPASS] then
    BR.perm.define(BYPASS, { description = "Build anywhere, past every region's rules and bans" })
end

-- API ----------------------------------------------------------------------

local function ids(list)
    local out = {}
    for _, v in ipairs(list or {}) do out[#out + 1] = type(v) == "string" and v or BR.player.id(v) end
    return out
end

local function norm_box(b)
    local min, max = b.min or b[1], b.max or b[2]
    return { min = { math.min(min[1], max[1]), math.min(min[2], max[2]), math.min(min[3], max[3]) },
        max = { math.max(min[1], max[1]), math.max(min[2], max[2]), math.max(min[3], max[3]) } }
end

--- Define (or replace) region `name`. opts:
---   box = { min = {x, y, z}, max = {x, y, z} } (grid units), or boxes = { ... }
---   owners: player ids or PlayerStates who may build there
---   build: "owners" (default: the owners only), "nobody", or "everyone"
---   copy: true lets anyone select (and so copy) in it
---   permission: a BR.perm permission whose holders build there as owners do
---     (unlike region.bypass, only in this region, and bans still apply)
---   ban_assets, ban_components: names not allowed there, for owners too
---   message: what a refused player is told
--- Saved at once. Returns the region's table (as BR.region.get).
function region.define(name, opts)
    assert(type(name) == "string" and name ~= "", "a region needs a name")
    load()
    hook()
    local boxes = {}
    for _, b in ipairs(opts.boxes or { opts.box }) do boxes[#boxes + 1] = norm_box(b) end
    assert(#boxes > 0, "a region needs a box (or boxes)")
    local build = opts.build or "owners"
    assert(build == "owners" or build == "nobody" or build == "everyone", "build is owners, nobody or everyone")
    S.regions[name] = { boxes = boxes, owners = ids(opts.owners), build = build, copy = opts.copy or nil,
        permission = opts.permission,
        ban_assets = opts.ban_assets, ban_components = opts.ban_components, message = opts.message }
    save()
    return S.regions[name]
end

--- Region `name`'s table ({ boxes, owners, build, copy, permission, ban_assets,
--- ban_components, message }), or nil. Change it through define and the
--- functions below, which save.
function region.get(name) load() return S.regions[name] end

--- Every region, by name.
function region.list() load() return S.regions end

function region.remove(name)
    load()
    S.regions[name] = nil
    save()
end

--- Give `ps` (or a player id) the right to build in region `name`.
function region.add_owner(name, ps)
    load()
    local r = assert(S.regions[name], "no region " .. tostring(name))
    local id = ids({ ps })[1]
    for _, o in ipairs(r.owners) do if o == id then return end end
    r.owners[#r.owners + 1] = id
    save()
end

function region.remove_owner(name, ps)
    load()
    local r = assert(S.regions[name], "no region " .. tostring(name))
    local id = ids({ ps })[1]
    for i, o in ipairs(r.owners) do if o == id then table.remove(r.owners, i) break end end
    save()
end

--- The names of the regions containing point {x, y, z} (grid units).
function region.at(point)
    load()
    local out = {}
    local p = box_around(point, { 0.5, 0.5, 0.5 })
    for name, r in pairs(S.regions) do
        for _, b in ipairs(r.boxes) do if overlaps(p, b) then out[#out + 1] = name break end end
    end
    table.sort(out)
    return out
end

--- What happens outside every region: "everyone" builds (the default) or
--- "nobody" does (players build only in regions that let them).
function region.set_default(rule)
    assert(rule == "everyone" or rule == "nobody", "the default is everyone or nobody")
    load()
    hook()
    S.default = rule
    save()
end

--- Ban asset or component names everywhere (as opposed to a region's own
--- ban_assets and ban_components). kind: "assets" or "components".
function region.ban(kind, names)
    load()
    hook()
    local list = assert(S.bans[kind], "kind is assets or components")
    for _, n in ipairs(type(names) == "table" and names or { names }) do
        local have = false
        for _, x in ipairs(list) do if x == n then have = true end end
        if not have then list[#list + 1] = n end
    end
    save()
end

function region.unban(kind, names)
    load()
    local list = assert(S.bans[kind], "kind is assets or components")
    for _, n in ipairs(type(names) == "table" and names or { names }) do
        for i, x in ipairs(list) do if x == n then table.remove(list, i) break end end
    end
    save()
end

--- Whether `ps` may build in the box { min, max }: true, or false and the
--- region in the way (nil: outside every region, under the default "nobody").
function region.allows(ps, box) return allows(ps, norm_box(box), "build") end

--- Let `ps` build anywhere until turned off (on = false), whatever their
--- permissions. The `region.bypass` permission does the same for a role.
function region.bypass(ps, on)
    S.bypassing[__addr(ps)] = on ~= false or nil
end

--- Call fn(player, info) when a player is refused. info: action ("place",
--- "delete", "paint", "apply", "paste", "resize", "rotate", "select",
--- "selection", "wire", ...), region (the region's name), zone (the zone brick
--- a zone rule refused in) or banned (the asset or component name), removed
--- (bricks taken back out, for a prefab).
--- Set info.quiet = true to stop the default status line message. Returns a
--- function that stops it.
function region.on_refused(fn)
    S.listeners[#S.listeners + 1] = fn
    return function()
        for i, f in ipairs(S.listeners) do if f == fn then table.remove(S.listeners, i) break end end
    end
end

--- Build rules from zone bricks: fn(zone, player, action) runs for each zone
--- on the world grid that a build overlaps, with zone = { brick, box = { min,
--- max }, tag (the zone's tag filter), building (its building zone flag) } and
--- action "build" or "select". It returns true to allow the build there (as
--- a region would, so a "nobody" default doesn't apply), false and optionally
--- a message to refuse it, or nil when the zone has no say. Regions are still
--- checked too. One rule at a time; nil turns it off. Not saved: set it again
--- at load. The zone list is taken again every 10 seconds, or at once with
--- BR.region.refresh_zones.
---
---   BR.region.zone_rule(function(zone, ps)
---       if zone.tag ~= "plot" then return nil end
---       return BR.perm.has(ps, "plots.build"), "Plots are for members"
---   end)
function region.zone_rule(fn)
    assert(fn == nil or type(fn) == "function", "a zone rule is a function")
    load()
    S.zone_rule = fn
    S.zones = nil
    if fn then hook() end
end

--- Take the zone list again now, after placing or removing zone bricks.
function region.refresh_zones() S.zones = nil end

local function matcher(filter)
    filter = filter or {}
    local assets = filter.asset and set_of(type(filter.asset) == "table" and filter.asset or { filter.asset })
    local comps = filter.component and component_types(set_of(type(filter.component) == "table" and filter.component or { filter.component }))
    local owner = filter.owner
    if owner and type(owner) ~= "number" then error("filter.owner is a brick owner index (BR.brick owner ids)") end
    return function(h)
        if assets then
            local a = BR.brick.info(h).asset
            if not (valid(a) and assets[a:GetFName():ToString()]) then return false end
        end
        if comps then
            local any = false
            for _, c in ipairs(comps) do if BR.component.handle(h, c.type) then any = true break end end
            if not any then return false end
        end
        if owner then
            local o = string.unpack("<i4", BR.raw.call(cdo("BRLuauBrickLibrary"), "BRLuauBrickLibrary", "GetOwnerId", { Self = h }).ReturnValue)
            if o ~= owner then return false end
        end
        return true
    end
end

--- The bricks in region `name` (touching its boxes) that match filter: asset
--- (a name or list), component (a name or list), owner (a brick owner index).
--- No filter: every brick.
function region.bricks(name, filter)
    load()
    local r = assert(S.regions[name], "no region " .. tostring(name))
    local match = matcher(filter)
    local seen, out = {}, {}
    for _, b in ipairs(r.boxes) do
        for _, h in ipairs(BR.brick.in_box(b.min, b.max, { max = SNAPSHOT_MAX })) do
            if not seen[h] and BR.brick.valid(h) and match(h) then
                seen[h] = true
                out[#out + 1] = h
            end
        end
    end
    return out
end

--- Remove the bricks in region `name` that match filter (as BR.region.bricks
--- takes it; no filter clears the region). Returns how many were removed.
function region.clear(name, filter)
    local list = region.bricks(name, filter)
    if #list == 0 then return 0 end
    local report = BR.brick.transaction(BR.player.server(), function(tx)
        for _, h in ipairs(list) do tx.delete(BR.brick.id(h)) end
    end)
    return report.BricksDeleted or #list
end

-- regions saved before this server start: their hooks come back with them
local ok, err = pcall(function()
    load()
    if S.hooked or next(S.regions) or S.default == "nobody" or #S.bans.assets > 0 or #S.bans.components > 0 then hook() end
end)
if not ok then I.report("BR.region", err) end

return region

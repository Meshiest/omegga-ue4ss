-- BR.brick: Placing, reading and changing bricks, and brick transactions.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local SCRIPT, cdo, layout, valid, decode_report = I.SCRIPT, I.cdo, I.layout, I.valid, I.decode_report
local brick = {}

--- The owner index of PUBLIC, the owner bricks get when none is given.
brick.PUBLIC = 0

--- Orientation 16 (Z+ facing, no rotation) leaves a prefab as it was saved;
--- 0 is X+ facing and turns it on its side.
-- EBrickOrientation: X+ 0..3, X- 4..7, Y+ 8..11, Y- 12..15, Z+ 16..19, Z- 20..23
brick.Z_UP = 16

brick.ALL_COLLISION = 0x7F

function brick.asset(name)
    local a = cdo("BRLuauWorldLibrary"):FindAsset(name)
    assert(a and a:IsValid(), "no brick asset " .. name)
    return a
end

--- EBrickMaterial, for BR.brick.builder's `material` option.
brick.MATERIAL = { Plastic = 0, Glass = 1, TranslucentPlastic = 2, Glow = 3, Metal = 4, Hologram = 5 }

--- A BRLuauBuilder as raw bytes. opts: asset (name), size {x,y,z} (procedural
--- bricks only: half sizes, multiples of 5 for x and y and of 2 for z; anything
--- else is an error), color {r,g,b,a}, material (a BR.brick.MATERIAL name or number,
--- default Plastic), alpha (material alpha, default 5), grid (actor), owner
--- (brick owner index, default BR.brick.PUBLIC), visible, collision.
function brick.builder(opts)
    local lib = cdo("BRLuauBuilderLibrary")
    local self = string.rep("\0", layout(SCRIPT .. "BRLuauBuilderLibrary:SetAsset").Self.size)
    local function set(fn, param, bytes, extra)
        local args = { Self = self, [param] = bytes }
        for k, v in pairs(extra or {}) do args[k] = v end
        self = BR.raw.call(lib, "BRLuauBuilderLibrary", fn, args).Self
    end
    local ctx = { WorldContextObject = BR.raw.ptr(BR.world.context()) }
    set("SetAsset", "NewAsset", BR.raw.ptr(BR.brick.asset(opts.asset or "PB_DefaultBrick")))
    set("SetGrid", "NewGrid", BR.raw.ptr(opts.grid or BR.world.global_grid()))
    if opts.size then
        set("SetSize", "NewSize", BR.raw.ivec(table.unpack(opts.size)))
        -- the game drops a size it doesn't allow and the brick comes out as the
        -- asset's default (a 2x4 for PB_DefaultBrick), so say so instead
        local got = BR.raw.call(lib, "BRLuauBuilderLibrary", "GetSize", { Self = self })
        if not BR.raw.bool(got.ReturnValue) then
            error(string.format("brick size {%s} was refused: procedural half sizes are multiples of 5 for x and y and of 2 for z, at most 4000",
                table.concat(opts.size, ", ")), 2)
        end
    end
    local c = opts.color or { 255, 255, 255, 255 }
    -- FColor is stored B, G, R, A
    set("SetColor", "NewColor", string.pack("BBBB", c[3], c[2], c[1], c[4]))
    -- a builder that never had SetMaterial places bricks clients draw as
    -- nothing (the server still reports them visible)
    local material = opts.material or "Plastic"
    if type(material) == "string" then material = assert(BR.brick.MATERIAL[material], "no material " .. material) end
    set("SetMaterial", "NewMaterial", string.pack("B", material), ctx)
    set("SetMaterialAlpha", "NewMaterialAlpha", string.pack("<i4", opts.alpha or 5))
    set("SetCollision", "NewChannels", string.pack("B", opts.collision == false and 0 or BR.brick.ALL_COLLISION))
    set("SetVisible", "bNewVisible", string.pack("B", opts.visible == false and 0 or 1))
    -- without an owner a brick shows the server stand-in's (a blank name); PUBLIC reads better
    set("SetOwnerId", "NewOwnerId", string.pack("<i4", opts.owner or brick.PUBLIC), ctx)
    return self
end

--- Place a builder at an integer position (brick units). Returns the BrickHandle
--- bytes, or nil when the grid refused it.
function brick.place(builder, x, y, z, orientation)
    local r = BR.raw.call(cdo("BRLuauBuilderLibrary"), "BRLuauBuilderLibrary", "Place", {
        Self = builder,
        Position = BR.raw.ivec(x, y, z),
        Orientation = string.pack("B", orientation or BR.brick.Z_UP),
        WorldContextObject = BR.raw.ptr(BR.world.context()),
    })
    if not BR.raw.bool(r.ReturnValue) then return nil end
    return r.OutBrick
end

local function raw_brick_call(fn, handle, args)
    args = args or {}
    args.Self = handle
    return BR.raw.call(cdo("BRLuauBrickLibrary"), "BRLuauBrickLibrary", fn, args)
end

--- Whether a brick handle still names a live brick. A null or stale handle
--- (deleted brick, a trace that hit no brick) is fine here.
function brick.valid(handle)
    return BR.raw.bool(raw_brick_call("IsValid", handle).ReturnValue)
end

-- Every other BRLuauBrickLibrary function aborts the server on an invalid
-- handle (a fatal check, not a Lua error), so they are only called after IsValid.
local function brick_call(fn, handle, args)
    if not BR.brick.valid(handle) then error("invalid brick handle", 3) end
    return raw_brick_call(fn, handle, args)
end

function brick.info(handle)
    if not BR.brick.valid(handle) then return { valid = false } end
    local x, y, z = string.unpack("<i4i4i4", brick_call("GetPosition", handle).ReturnValue)
    return {
        valid = true,
        asset = BR.raw.obj(brick_call("GetAsset", handle).ReturnValue),
        position = { x, y, z },
    }
end

--- The grid a brick is on: the world's global grid, or a dynamic grid entity
--- (a contraption, vehicle, prefab spawned as an entity).
function brick.grid(handle)
    return BR.raw.obj(brick_call("GetGrid", handle).ReturnValue)
end

function brick.visible(handle) return BR.raw.bool(brick_call("IsVisible", handle).ReturnValue) end

function brick.id(handle) return brick_call("GetId", handle).ReturnValue end

--- Who a brick owner index stands for: { index, id (account id, 8-4-4-4-12
--- hex), name, display_name }, from the game's owner table, or nil for an index
--- it doesn't have. Owners stay in the table after they leave, so this names
--- whoever built a brick even when they're gone.
function brick.owner_info(index)
    local found
    -- UE4SS counts array entries from 1; owner indexes count from 0
    I.game_state().BrickOwnerTable:ForEach(function(i, e)
        if i - 1 == index then found = e:get() end
    end)
    if not found then return nil end
    local g = found.OwnerGuid
    return {
        index = index,
        id = string.format("%08x-%04x-%04x-%04x-%04x%08x", g.A, g.B >> 16, g.B & 0xFFFF, g.C >> 16, g.C & 0xFFFF, g.D),
        name = found.OwnerName:ToString(),
        display_name = found.OwnerDisplayName:ToString(),
    }
end

--- A brick's owner, as BR.brick.owner_info describes one (nil if the index has
--- no entry).
function brick.owner(handle)
    local index = string.unpack("<i4", brick_call("GetOwnerId", handle).ReturnValue)
    return brick.owner_info(index)
end

function brick.count(grid)
    return cdo("BRLuauGridLibrary"):GetCount(grid or BR.world.global_grid())
end

--- Every brick on a grid (default: the global grid) as BrickHandles. A
--- microchip's gates live on their own grid, a BP_MicrochipBrickGridDynamicActor_C.
function brick.in_grid(grid)
    local raw = BR.raw.call(cdo("BRLuauGridLibrary"), "BRLuauGridLibrary", "GetBricks", { Self = BR.raw.ptr(grid or BR.world.global_grid()) }).ReturnValue
    return BR.raw.take_handles(raw)
end

local function query_opts(opts)
    opts = opts or {}
    return BR.raw.ptr(opts.grid or BR.world.global_grid()), string.pack("<i4", opts.max or 10000)
end

--- Bricks within `radius` of `center` ({x, y, z}), as BrickHandles. Positions are
--- in the grid's space: world space on the global grid (the default). opts.grid
--- searches another grid; opts.max caps the results (default 10000).
function brick.in_sphere(center, radius, opts)
    local grid, max = query_opts(opts)
    local r = BR.raw.call(cdo("BRLuauGridLibrary"), "BRLuauGridLibrary", "InSphere", {
        Self = grid, Center = string.pack("<ddd", center[1], center[2], center[3]), Radius = string.pack("<d", radius), MaxResults = max,
    })
    return BR.raw.take_handles(r.ReturnValue)
end

--- Bricks touching the box from `min` to `max` (whole grid units, {x, y, z}), as
--- BrickHandles. Options as for BR.brick.in_sphere.
function brick.in_box(min, max, opts)
    local grid, cap = query_opts(opts)
    local r = BR.raw.call(cdo("BRLuauGridLibrary"), "BRLuauGridLibrary", "InBox", {
        -- grid units are whole numbers; a box from world positions rounds outwards
        Self = grid, Min = BR.raw.ivec(math.floor(min[1]), math.floor(min[2]), math.floor(min[3])),
        Max = BR.raw.ivec(math.ceil(max[1]), math.ceil(max[2]), math.ceil(max[3])), MaxResults = cap,
    })
    return BR.raw.take_handles(r.ReturnValue)
end

--- EBrickCollisionChannels bits, for tx.collision: a brick blocks what it has
--- the bit for.
brick.COLLISION = { Player = 1, Player1 = 2, Player2 = 4, Player3 = 8, Weapon = 16, Interaction = 32, Physics = 64 }

local function material_number(m)
    if type(m) == "string" then return assert(BR.brick.MATERIAL[m], "no material " .. m) end
    return m
end

-- FColor is stored B, G, R, A
local function color_bytes(c) return string.pack("BBBB", c[3], c[2], c[1], c[4] or 255) end

--- An FTransform's bytes: rotation (a quaternion), translation, scale, each 4
--- doubles. t: { pos = {x, y, z}, rot = {x, y, z, w} (default none), scale =
--- {x, y, z} or a number (default 1) }, in world units.
function brick.transform(t)
    local p, q, s = t.pos or { 0, 0, 0 }, t.rot or { 0, 0, 0, 1 }, t.scale or 1
    if type(s) == "number" then s = { s, s, s } end
    return string.pack("<dddd", q[1], q[2], q[3], q[4]) .. string.pack("<dddd", p[1], p[2], p[3], 0)
        .. string.pack("<dddd", s[1], s[2], s[3], 0)
end

-- an id as the 4 bytes a handle is: BR.brick.id's bytes pass through, a number is packed
local function id_bytes(id)
    if type(id) == "number" then return string.pack("<I4", id) end
    assert(type(id) == "string" and #id == 4, "an id is BR.brick.id's bytes or a number")
    return id
end

-- an entity actor or its id, as handle bytes
local function entity_id(e)
    if type(e) == "number" or type(e) == "string" then return id_bytes(e) end
    return string.pack("<I4", BR.entity.id(e))
end

--- Run a transaction as `player` (see BR.player.server): `record(tx)` appends
--- actions, then it executes once, with the player's trust and quotas checked
--- the way the game checks the player's own building. Returns the
--- TransactionReport counters by name. Bricks are named by id (BR.brick.id, or
--- the id tx.place returned); entities by the actor or its id. Positions and
--- sizes are whole grid units.
---
--- Bricks:
---   tx.place(builder, {x, y, z}, orientation, grid) -> id, usable later in the same transaction
---   tx.restore(id, builder, {x, y, z}, orientation, grid)  -- put a deleted brick back under its id
---   tx.delete(id)
---   tx.move(id, {x, y, z}, orientation)
---   tx.reorient(id, orientation)
---   tx.resize(id, size, {x, y, z})      -- procedural bricks; size is half extents
---   tx.color(id, {r, g, b, a}, material, alpha)  -- material optional; alpha needs a material
---   tx.material(id, material, alpha)    -- a BR.brick.MATERIAL name or number
---   tx.collision(id, channels)          -- BR.brick.COLLISION bits, or true / false for all / none
---   tx.visible(id, bool)
---   tx.owner(id, playerState)
--- Components and wires:
---   tx.set(id, inputPort, wireValue)
---   tx.connect(sourceId, outputPort, targetId, inputPort)
---   tx.disconnect(sourceId, outputPort, targetId, inputPort)
---   tx.attach(id, componentType)        -- a component type object
---   tx.detach(id, componentType)
--- Entities (grid: a dynamic grid entity to place onto; default the world grid):
---   tx.place_entity(class, transform, opts) -> id; opts.frozen, opts.owner (owner index)
---   tx.move_entity(entity, transform)
---   tx.delete_entity(entity)
---   tx.entity_color(entity, slot, {r, g, b, a})
---   tx.physics(entity, bool)
---   tx.connect_joint(jointId, entity, transform)
---   tx.disconnect_joint(jointId, entity)
---   tx.entity_properties(entity, props)  -- replace its custom properties (BR.entity.set_properties)
--- A transform is BR.brick.transform's table, or its bytes.
function brick.transaction(player, record)
    local lib = cdo("BRLuauTransactionLibrary")
    local self = string.rep("\0", layout(SCRIPT .. "BRLuauTransactionLibrary:Execute").Self.size)
    local function rec(fn, args)
        args.Self = self
        local r = BR.raw.call(lib, "BRLuauTransactionLibrary", fn, args)
        self = r.Self
        return r
    end
    local function ctx() return BR.raw.ptr(BR.world.context()) end
    local function ivec(v) return BR.raw.ivec(v[1], v[2], v[3]) end
    local function orient(o) return string.pack("B", o or BR.brick.Z_UP) end
    local function transform(t) return type(t) == "string" and t or BR.brick.transform(t) end
    -- handle 0 is the world grid
    local function grid_id(g) return g and entity_id(g) or string.pack("<I4", 0) end

    local tx = {}
    function tx.place(builder, pos, orientation, grid)
        return rec("RecordPlace", { Builder = builder, Position = ivec(pos), Orientation = orient(orientation), WorldContextObject = ctx(), GridId = grid_id(grid) }).ReturnValue
    end
    function tx.restore(id, builder, pos, orientation, grid)
        rec("RecordRestore", { ID = id_bytes(id), Builder = builder, Position = ivec(pos), Orientation = orient(orientation), WorldContextObject = ctx(), GridId = grid_id(grid) })
    end
    function tx.delete(id) rec("RecordDelete", { ID = id_bytes(id) }) end
    function tx.move(id, pos, orientation) rec("RecordMove", { ID = id_bytes(id), NewPosition = ivec(pos), NewOrientation = orient(orientation) }) end
    function tx.reorient(id, orientation) rec("RecordReorient", { ID = id_bytes(id), NewOrientation = orient(orientation) }) end
    function tx.resize(id, size, pos) rec("RecordResize", { ID = id_bytes(id), NewSize = ivec(size), NewPosition = ivec(pos) }) end
    function tx.color(id, c, material, alpha)
        -- the game sets alpha only together with a material, and there is no
        -- reading the brick's current one here to keep it
        assert(material ~= nil or alpha == nil, "tx.color: give a material with alpha")
        if material == nil then
            rec("RecordSetColor", { ID = id_bytes(id), NewColor = color_bytes(c) })
        else
            rec("RecordSetColorAndMaterial", { ID = id_bytes(id), NewColor = color_bytes(c),
                NewMaterial = string.pack("B", material_number(material)), NewMaterialAlpha = string.pack("<i4", alpha or 5) })
        end
    end
    function tx.material(id, material, alpha)
        rec("RecordSetMaterial", { ID = id_bytes(id), NewMaterial = string.pack("B", material_number(material)), NewMaterialAlpha = string.pack("<i4", alpha or 5) })
    end
    function tx.collision(id, channels)
        if channels == true then channels = BR.brick.ALL_COLLISION elseif channels == false then channels = 0 end
        rec("RecordSetCollision", { ID = id_bytes(id), NewChannels = string.pack("B", channels) })
    end
    function tx.visible(id, on) rec("RecordSetVisibility", { ID = id_bytes(id), bNewVisible = string.pack("B", on and 1 or 0) }) end
    function tx.owner(id, ps) rec("RecordSetOwner", { ID = id_bytes(id), NewOwner = BR.raw.ptr(ps), WorldContextObject = ctx() }) end

    function tx.set(id, port, value) rec("RecordSet", { ID = id_bytes(id), Port = port, Value = value }) end
    function tx.connect(source, output, target, input)
        rec("RecordConnect", { SourceId = id_bytes(source), Output = output, TargetId = id_bytes(target), Input = input })
    end
    function tx.disconnect(source, output, target, input)
        rec("RecordDisconnect", { SourceId = id_bytes(source), Output = output, TargetId = id_bytes(target), Input = input })
    end
    function tx.attach(id, type) rec("RecordAttach", { ID = id_bytes(id), Type = BR.raw.ptr(type) }) end
    function tx.detach(id, type) rec("RecordDetach", { ID = id_bytes(id), Type = BR.raw.ptr(type) }) end

    function tx.place_entity(class, t, opts)
        opts = opts or {}
        return rec("RecordPlaceEntity", { WorldContextObject = ctx(), Type = BR.raw.ptr(BR.entity.class(class)), Transform = transform(t),
            bFrozen = string.pack("B", opts.frozen and 1 or 0), OwnerId = string.pack("<i4", opts.owner or 0) }).ReturnValue
    end
    function tx.move_entity(e, t) rec("RecordMoveEntity", { ID = entity_id(e), NewTransform = transform(t) }) end
    function tx.delete_entity(e) rec("RecordDeleteEntity", { ID = entity_id(e) }) end
    function tx.entity_color(e, slot, c) rec("RecordSetEntityColor", { ID = entity_id(e), Slot = string.pack("<i4", slot), NewColor = color_bytes(c) }) end
    function tx.physics(e, on) rec("RecordSetPhysicsEnabled", { ID = entity_id(e), bEnabled = string.pack("B", on and 1 or 0) }) end
    function tx.connect_joint(joint, e, t) rec("RecordConnectJoint", { JointId = id_bytes(joint), EntityID = entity_id(e), Attach = transform(t) }) end
    function tx.disconnect_joint(joint, e) rec("RecordDisconnectJoint", { JointId = id_bytes(joint), EntityID = entity_id(e) }) end
    -- no record function covers this action, so the bridge places it as one would
    function tx.entity_properties(e, props)
        local bytes, count = I.property_changelist(props)
        local st = StaticFindObject(SCRIPT .. "BrickAction_ApplyChangelistToEntity")
        local off = {}
        local s = st
        while s and s:IsValid() do
            s:ForEachProperty(function(p) off[p:GetFName():ToString()] = off[p:GetFName():ToString()] or p:GetOffset_Internal() end)
            s = s:GetSuperStruct()
        end
        assert(off.EntityPersistentHandle and off.Changelist, "BrickAction_ApplyChangelistToEntity's layout changed")
        local addr
        self, addr = __tx_append(self, st)
        __poke(addr + off.EntityPersistentHandle, entity_id(e))
        -- the action owns the token array (and the WireStrings in it) from here
        __poke(addr + off.Changelist, string.pack("<I8i4i4", __game_alloc(bytes), count, count))
        __tx_finish(self, addr)
    end

    record(tx)
    return decode_report(BR.raw.call(lib, "BRLuauTransactionLibrary", "Execute", { Self = self, Player = BR.raw.ptr(player) }).ReturnValue)
end

--- Only the non-zero counters of a report, for printing.
function brick.changes(report)
    local out = {}
    for k, v in pairs(report) do
        if k == "lines" then
            if #v > 0 then out.lines = v end
        elseif v ~= 0 then
            out[k] = v
        end
    end
    return out
end

-- Exec triggers: firing exec gates (Send Custom Event, Broadcast Chat Message,
-- any exec input) from Lua. Lua can only set component inputs, so a Change
-- Detector gate does the firing: every new value set on its input fires its
-- OnChanged exec output on the next tick.

local DETECTOR = "B_1x1_Gate_Expr_ChangeDetectorExec"

--- Place a trigger gate at grid position (x, y, z) and return
--- { brick, connect(target, type, port), fire() }. A wire made in the same
--- tick as a fire is not live yet, so connect, then fire from a later call.
function brick.trigger(x, y, z)
    local ps = BR.player.server()
    local brick = assert(BR.brick.place(BR.brick.builder({ asset = DETECTOR }), x, y, z), "the trigger could not be placed")
    local det = BR.component.type("ChangeDetectorExec"):GetFName():ToString()
    -- a reload starts a fresh counter while the gate keeps its old value, and an
    -- equal value would not fire
    local n = os.time() % 1000000 * 1000
    local t = { brick = brick }
    function t.connect(target, type, port)
        return BR.brick.changes(BR.brick.transaction(ps, function(tx)
            tx.connect(BR.brick.id(brick), BR.component.output_port(det, "OnChanged"), BR.brick.id(target), BR.component.input_port(type, port))
        end))
    end
    function t.fire()
        n = n + 1
        return BR.component.set_input(brick, det, "Input", BR.wire.int(n))
    end
    -- the detector's first value only sets its baseline, so spend it here
    t.fire()
    return t
end

return brick

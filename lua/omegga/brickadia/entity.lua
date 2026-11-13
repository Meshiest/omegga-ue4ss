-- BR.entity: Entities and dynamic brick grids: tags, spawning and their state.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local cdo, wirestring = I.cdo, I.wirestring
local entity = {}

-- Entities (physics objects: balls, wheels, vehicles) are BREntityActor actors.

function entity.list() return FindAllOf("BREntityActor") or {} end

-- Entity tags: a WireString property `EntityTag` on entities (BREntityActor) and
-- on dynamic brick grids (BrickGridDynamicActor), set in game from the entity's
-- properties. Both classes put it at the same offset today; it is looked up by
-- reflection rather than assumed.
local tag_offsets = {}

local function tag_offset(class_path)
    if not tag_offsets[class_path] then
        StaticFindObject(class_path):ForEachProperty(function(p)
            if p:GetFName():ToString() == "EntityTag" then tag_offsets[class_path] = p:GetOffset_Internal() end
        end)
    end
    return assert(tag_offsets[class_path], "no EntityTag on " .. class_path)
end

local TAGGED = { "/Script/Brickadia.BREntityActor", "/Script/Brickadia.BrickGridDynamicActor" }

local function tag_class(actor)
    for _, path in ipairs(TAGGED) do
        if actor:IsA(StaticFindObject(path)) then return path end
    end
end

--- An entity's or dynamic grid's tag, or nil when it has none.
function entity.tag(actor)
    local path = tag_class(actor)
    if not path then return nil end
    -- the WireString's first word points at {TArray<char> text with NUL, hash}
    local obj = string.unpack("<I8", __peek(__addr(actor) + tag_offset(path), 8))
    if obj == 0 then return nil end
    local data, num = string.unpack("<I8i4", __peek(obj, 12))
    if data == 0 or num <= 1 then return nil end
    return __peek(data, num - 1)
end

--- Set an entity's or dynamic grid's tag.
function entity.set_tag(actor, text)
    local path = assert(tag_class(actor), "not an entity or dynamic grid")
    local class = path:match("%.(%w+)$")
    BR.raw.call(actor, class, "SetEntityTag", { Tag = wirestring(text) })
end

-- Custom properties: a TMap<WireString, WireValue> `CustomProperties` on the
-- same two classes, which the Set/Get Custom Property gates and the applicator
-- edit. The game keeps it as a dense map: Num live entries from the start of
-- its data, each a WireString key then a WireValue, with the hash index after
-- them.
local prop_offsets = {}

local function props_offset(class_path)
    if not prop_offsets[class_path] then
        StaticFindObject(class_path):ForEachProperty(function(p)
            if p:GetFName():ToString() == "CustomProperties" then prop_offsets[class_path] = p:GetOffset_Internal() end
        end)
    end
    return assert(prop_offsets[class_path], "no CustomProperties on " .. class_path)
end

local PROP_ENTRY = 0x10 + I.WIRE_SIZE

--- An entity's or dynamic grid's custom properties, { [key] = value }: values
--- as wire values read in Lua (booleans, numbers, strings, vectors).
function entity.properties(actor)
    if not I.alive(actor) then error("not a live entity", 2) end
    local path = tag_class(actor)
    if not path then error("not an entity or dynamic grid", 2) end
    local map = __addr(actor) + props_offset(path)
    local data, num = string.unpack("<I8i4", __peek(map, 12))
    local out = {}
    if data == 0 or num <= 0 then return out end
    for i = 0, num - 1 do
        local at = data + i * PROP_ENTRY
        out[I.read_wirestring(at)] = I.read_wirevalue(at + 0x10)
    end
    return out
end

--- One custom property of an entity or dynamic grid, or nil.
function entity.property(actor, key)
    return entity.properties(actor)[key]
end

-- Writing goes through the changelist the applicator sends for an entity
-- (FBRPropertyChangelist tokens, 32 bytes: a 0x18-byte payload, the tag at
-- +0x18). The map is written whole: push the field (2), begin and clear it
-- (16, 4), then for each entry the key (127, a WireString), the value's wire
-- kind (25: 0 bool, 1 int, 2 double, 7 string), its leaf (28 bool, 35 int64,
-- 38 double, 42 WireString) and two pops (3); then end it (5) and pop (3). A
-- leaf that doesn't match the kind stops the game applying the rest.
local function token(tag, payload)
    payload = payload or ""
    return payload .. string.rep("\0", 0x18 - #payload) .. string.pack("B", tag) .. string.rep("\0", 7)
end

local function value_tokens(key, v)
    local t = type(v)
    if t == "boolean" then
        return token(25, string.pack("<I4", 0)) .. token(28, v and "\1" or "\0")
    elseif math.type(v) == "integer" then
        return token(25, string.pack("<I4", 1)) .. token(35, string.pack("<i8", v))
    elseif t == "number" then
        return token(25, string.pack("<I4", 2)) .. token(38, string.pack("<d", v))
    elseif t == "string" then
        return token(25, string.pack("<I4", 7)) .. token(42, I.wirestring(v))
    end
    error("custom property " .. tostring(key) .. " is a " .. t .. "; properties are booleans, numbers and strings", 4)
end

-- the changelist bytes setting an entity's custom properties to `props`, and
-- how many tokens they are
function I.property_changelist(props)
    local keys = {}
    for k in pairs(props) do
        if type(k) ~= "string" then error("custom property keys are strings", 3) end
        keys[#keys + 1] = k
    end
    table.sort(keys)
    -- values are checked before any WireString is made, so an error leaks none
    for _, k in ipairs(keys) do
        local v = props[k]
        if not (type(v) == "boolean" or type(v) == "number" or type(v) == "string") then value_tokens(k, v) end
    end
    local out = { token(2, string.pack("<I8", __fname("CustomProperties"))), token(16), token(4) }
    for _, k in ipairs(keys) do
        out[#out + 1] = token(127, I.wirestring(k))
        out[#out + 1] = value_tokens(k, props[k])
        out[#out + 1] = token(3) .. token(3)
    end
    out[#out + 1] = token(5) .. token(3)
    local bytes = table.concat(out)
    return bytes, #bytes // 32
end

--- Set an entity's or dynamic grid's custom properties to `props` (replacing
--- them all), as the server: `{ [key] = value }`, values booleans, numbers
--- (an integer stays one) and strings.
function entity.set_properties(actor, props)
    if not I.alive(actor) then error("not a live entity", 2) end
    if not tag_class(actor) then error("not an entity or dynamic grid", 2) end
    local report = BR.brick.transaction(BR.player.server(), function(tx) tx.entity_properties(actor, props) end)
    if (report.EntitiesChanged or 0) < 1 then
        error("the game didn't change the entity's properties", 2)
    end
end

--- Set one custom property (nil removes it).
function entity.set_property(actor, key, value)
    local props = entity.properties(actor)
    props[key] = value
    entity.set_properties(actor, props)
end

--- Entities and dynamic grids whose tag is `tag` (all tagged ones when nil).
function entity.find(tag)
    local out = {}
    for _, path in ipairs(TAGGED) do
        for _, a in ipairs(FindAllOf(path:match("%.(%w+)$")) or {}) do
            if a:IsValid() then
                local t = BR.entity.tag(a)
                if t and (tag == nil or t == tag) then out[#out + 1] = a end
            end
        end
    end
    return out
end

local function entity_lib(fn, ...) return cdo("BRLuauEntityLibrary")[fn](cdo("BRLuauEntityLibrary"), ...) end

--- An entity's id, as transactions name it (tx.move_entity and the others take
--- the actor too).
function entity.id(e)
    return cdo("BRLuauEntityLibrary"):GetId(e, BR.world.context()).ElementID
end

--- The entity actor with transaction id `id`, or nil.
function entity.by_id(id)
    for _, e in ipairs(BR.entity.list()) do
        if e:IsValid() and entity.id(e) == id then return e end
    end
end

--- An entity class from its name ("Entity_Ball", as BR.enums lists them) or
--- the class itself.
function entity.class(class)
    if type(class) ~= "string" then return class end
    local c = cdo("BRLuauWorldLibrary"):FindEntityType(class, BR.world.context())
    assert(c and c:IsValid(), "no entity class " .. class)
    return c
end

--- Spawn an entity of `class` (a name such as "Entity_Ball", or a UClass) at a
--- world location. opts: frozen, owner (owner index, default BR.brick.PUBLIC).
function entity.spawn(class, x, y, z, opts)
    opts = opts or {}
    class = entity.class(class)
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local e = cdo("BRLuauWorldLibrary"):SpawnEntity(BR.world.context(), class, xf, opts.frozen and true or false, opts.owner or BR.brick.PUBLIC, {})
    assert(e and e:IsValid(), "spawn failed")
    return e
end

function entity.color(e, slot, r, g, b, a) return entity_lib("SetEntityColor", e, slot, { R = r, G = g, B = b, A = a or 255 }) end

function entity.frozen(e) return entity_lib("GetFrozen", e) end

function entity.set_frozen(e, frozen) return entity_lib("SetFrozen", e, frozen) end

--- Stop an entity or dynamic grid where it is (physics lets go of it).
function entity.freeze(e) return entity_lib("SetFrozen", e, true) end

--- Hand a frozen entity or dynamic grid back to physics.
function entity.unfreeze(e) return entity_lib("SetFrozen", e, false) end

-- gravity is a property of physics entities (balls, wheels, ...) and dynamic
-- grids, each with its own setter; other entities have none
local GRAVITY = { "/Script/Brickadia.BRPhysicsMeshEntity", "/Script/Brickadia.BrickGridDynamicActor" }

local function has_gravity(e)
    for _, path in ipairs(GRAVITY) do
        if e:IsA(StaticFindObject(path)) then return true end
    end
    return false
end

--- Whether gravity pulls on a physics entity or dynamic grid.
function entity.gravity(e)
    if not (I.alive(e) and has_gravity(e)) then error("not a physics entity or dynamic grid", 2) end
    return e.bEnableGravity
end

--- Turn gravity on or off for a physics entity (a ball, a wheel) or dynamic
--- grid. Off, it floats where physics leaves it; it isn't frozen.
function entity.set_gravity(e, enabled)
    if not (I.alive(e) and has_gravity(e)) then error("not a physics entity or dynamic grid", 2) end
    e:SetEnableGravity(enabled and true or false)
end

--- Point a character's gravity along {x, y, z} (normalized; {0, 0, -1} is
--- normal): they fall that way and stand on surfaces facing against it, as the
--- Set Gravity Direction gate does. `target` is a PlayerState or character.
--- Entities and grids have no direction, only gravity on or off.
function entity.set_gravity_direction(target, dir)
    if I.alive(target) and target:IsA(StaticFindObject("/Script/Engine.PlayerState")) then
        target = BR.player.character(target)
    end
    if not (I.alive(target) and target:IsA(StaticFindObject("/Script/Engine.Character"))) then
        error("gravity direction is for a player or character", 2)
    end
    local x, y, z = dir[1], dir[2], dir[3]
    local len = math.sqrt(x * x + y * y + z * z)
    assert(len > 0, "a gravity direction can't be zero")
    local v = { X = x / len, Y = y / len, Z = z / len }
    local cm = target.CharacterMovement
    cm:SetGravityDirection(v)
    -- SetGravityDirection only changes the server's copy. Brickadia's movement
    -- component and the engine's character each keep a replicated copy, and the
    -- owning client (which simulates its own movement) takes a change through
    -- the movement corrections only when it is flagged
    cm.ReplicatedGravityDirection = v
    pcall(function() target.ReplicatedGravityDirection = v end)
    pcall(function() cm.bNetworkGravityDirectionChanged = true end)
    target:ForceNetUpdate()
end

--- A character's gravity direction, { x, y, z }.
function entity.gravity_direction(target)
    if I.alive(target) and target:IsA(StaticFindObject("/Script/Engine.PlayerState")) then
        target = BR.player.character(target)
    end
    if not (I.alive(target) and target:IsA(StaticFindObject("/Script/Engine.Character"))) then
        error("gravity direction is for a player or character", 2)
    end
    local g = target.CharacterMovement.GravityDirection
    return { g.X, g.Y, g.Z }
end

function entity.visible(e) return entity_lib("GetVisible", e) end

function entity.set_visible(e, visible) return entity_lib("SetVisible", e, visible) end

function entity.owner(e) return entity_lib("GetOwnerId", e) end

function entity.delete(e) return entity_lib("DeleteEntity", e) end

-- EAttachmentRule
local KEEP_WORLD, SNAP_TO_TARGET = 1, 2

--- Attach an entity or dynamic brick grid to a player's character (`target`: a
--- PlayerState, or a character) so it moves and turns with them. It goes on the
--- character's skeletal mesh, at bone or socket opts.socket ("Part_Head", ...)
--- if given: attached to the actor itself, clients see it trail loosely behind,
--- while on the mesh it stays put. It is frozen first, since physics would pull
--- it away, and the character's movement ignores it (otherwise its collision
--- pins or shoves the character carrying it). opts.offset {x, y, z} places it
--- relative to the socket; without it, it keeps where it is now. When the
--- character goes (a death, a respawn), the grid stays behind, detached.
function entity.attach(e, target, opts)
    opts = opts or {}
    if not (e and e:IsValid()) then error("invalid entity", 2) end
    if target:IsA(StaticFindObject("/Script/Engine.PlayerState")) then
        target = BR.player.character(target)
        if not target then error("the player has no living character", 2) end
    end
    local mesh = target.Mesh
    if not (mesh and mesh:IsValid()) then error("the target has no skeletal mesh", 2) end
    local socket = FName(opts.socket or "None")
    BR.entity.set_frozen(e, true)
    target.CapsuleComponent:IgnoreActorWhenMoving(e, true)
    if opts.offset then
        e:K2_AttachToComponent(mesh, socket, SNAP_TO_TARGET, SNAP_TO_TARGET, KEEP_WORLD, false)
        e:K2_SetActorRelativeLocation({ X = opts.offset[1], Y = opts.offset[2], Z = opts.offset[3] }, false, {}, false)
    else
        e:K2_AttachToComponent(mesh, socket, KEEP_WORLD, KEEP_WORLD, KEEP_WORLD, false)
    end
end

--- Detach an entity or grid where it is. opts.unfreeze = true lets physics take
--- it again.
function entity.detach(e, opts)
    if not (e and e:IsValid()) then error("invalid entity", 2) end
    local carrier = BR.entity.attached_to(e)
    e:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD)
    if carrier and carrier.CapsuleComponent then carrier.CapsuleComponent:IgnoreActorWhenMoving(e, false) end
    -- clients don't learn where a detached grid ended up: they keep drawing it
    -- where it was, offset from the server's copy. A move to where it is now
    -- tells them.
    local t = e:GetTransform()
    local l, r = t.Translation, t.Rotation
    BR.brick.transaction(BR.player.server(), function(tx)
        tx.move_entity(e, { pos = { l.X, l.Y, l.Z }, rot = { r.X, r.Y, r.Z, r.W } })
    end)
    if opts and opts.unfreeze then BR.entity.set_frozen(e, false) end
end

--- The actor an entity or grid is attached to, or nil.
function entity.attached_to(e)
    if not (e and e:IsValid()) then return nil end
    local p = e:GetAttachParentActor()
    if p and p:IsValid() then return p end
end

return entity

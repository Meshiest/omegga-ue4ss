-- Brickadia helpers for UE4SS Lua on the Linux server.
--
-- Most of Brickadia's scripting UFunctions (BRLuau*Library) pass opaque structs
-- with no reflected fields (builder, brick handle, port ref, wire value), which
-- UE4SS's table marshalling drops. Those go through the native __raw_call: params
-- are packed into a byte buffer at the offsets reflection reports, and results
-- are read back out of the same buffer.
local M = {}

local SCRIPT = "/Script/Brickadia."

local function cdo(class)
    local obj = StaticFindObject(SCRIPT .. "Default__" .. class)
    assert(obj and obj:IsValid(), "no CDO for " .. class)
    return obj
end

local layouts = {}
local function layout(path)
    local l = layouts[path]
    if not l then
        l = __fn_layout(path)
        assert(l, "no UFunction " .. path)
        layouts[path] = l
    end
    return l
end

--- Call `Class:Function` on `target` with raw param bytes keyed by param name.
--- `class` is a Brickadia class name, or "Package.Class" for another script
--- package ("Engine.KismetStringLibrary"). Returns a table whose fields are the
--- raw bytes of each param after the call.
function M.call(target, class, fn, args)
    local path = (class:find(".", 1, true) and "/Script/" .. class or SCRIPT .. class) .. ":" .. fn
    local l = layout(path)
    local buf = string.rep("\0", l.size)
    for name, bytes in pairs(args or {}) do
        local p = l[name]
        assert(p, path .. " has no param " .. name)
        assert(#bytes <= p.size, string.format("%s.%s: %d bytes > %d", path, name, #bytes, p.size))
        buf = buf:sub(1, p.offset) .. bytes .. buf:sub(p.offset + #bytes + 1)
    end
    local out = __raw_call(target, path, buf)
    return setmetatable({}, {
        __index = function(_, name)
            local p = l[name]
            assert(p, path .. " has no param " .. name)
            return out:sub(p.offset + 1, p.offset + p.size)
        end,
    })
end

function M.ptr(obj) return string.pack("<I8", obj and __addr(obj) or 0) end
function M.obj(bytes)
    local a = string.unpack("<I8", bytes)
    return a ~= 0 and __obj(a) or nil
end
function M.bool(bytes) return string.byte(bytes, 1) ~= 0 end
function M.i32(bytes) return (string.unpack("<i4", bytes)) end
function M.ivec(x, y, z) return string.pack("<i4i4i4", x, y, z) end

-- EBrickOrientation: X+ 0..3, X- 4..7, Y+ 8..11, Y- 12..15, Z+ 16..19, Z- 20..23
M.Z_UP = 16
M.ALL_COLLISION = 0x7F

-- Calling a method on an invalid UObject (FindFirstOf found nothing, the world
-- isn't loaded yet) dereferences null inside UE4SS and kills the server; pcall
-- can't catch it. Everything below checks IsValid() first and raises a Lua error.
local function valid(obj, what)
    if not obj or not obj:IsValid() then error(what .. " is not available (is the world loaded? see BR.ready())", 3) end
    return obj
end

function M.game_mode() return valid(FindFirstOf("BRGameModeBase"), "the game mode") end
-- The BRLuau libraries want the UWorld itself as WorldContextObject (Place checks
-- IsA(UWorld) and then fetches its BRRegistry); an actor in that world makes them
-- fail. UE4SS's UObject:GetWorld() hands back a mis-wrapped object here, so the
-- world comes from the global grid's outer chain: grid -> PersistentLevel -> World.
function M.global_grid() return valid(FindFirstOf("GlobalBrickGridActor"), "the global brick grid") end
function M.world_context()
    local level = valid(M.global_grid():GetOuter(), "the grid's level")
    return valid(level:GetOuter(), "the world")
end

--- Whether the world is loaded enough for the helpers (the global grid exists).
function M.ready()
    local grid = FindFirstOf("GlobalBrickGridActor")
    return grid ~= nil and grid:IsValid()
end

function M.asset(name)
    local a = cdo("BRLuauWorldLibrary"):FindAsset(name)
    assert(a and a:IsValid(), "no brick asset " .. name)
    return a
end

--- EBrickMaterial, for BR.builder's `material` option.
M.MATERIAL = { Plastic = 0, Glass = 1, TranslucentPlastic = 2, Glow = 3, Metal = 4, Hologram = 5 }

--- A BRLuauBuilder as raw bytes. opts: asset (name), size {x,y,z} (procedural
--- bricks only), color {r,g,b,a}, material (a BR.MATERIAL name or number,
--- default Plastic), alpha (material alpha, default 5), grid (actor), owner
--- (brick owner index), visible, collision.
function M.builder(opts)
    local lib = cdo("BRLuauBuilderLibrary")
    local self = string.rep("\0", layout(SCRIPT .. "BRLuauBuilderLibrary:SetAsset").Self.size)
    local function set(fn, param, bytes, extra)
        local args = { Self = self, [param] = bytes }
        for k, v in pairs(extra or {}) do args[k] = v end
        self = M.call(lib, "BRLuauBuilderLibrary", fn, args).Self
    end
    local ctx = { WorldContextObject = M.ptr(M.world_context()) }
    set("SetAsset", "NewAsset", M.ptr(M.asset(opts.asset or "PB_DefaultBrick")))
    set("SetGrid", "NewGrid", M.ptr(opts.grid or M.global_grid()))
    if opts.size then set("SetSize", "NewSize", M.ivec(table.unpack(opts.size))) end
    local c = opts.color or { 255, 255, 255, 255 }
    -- FColor is stored B, G, R, A
    set("SetColor", "NewColor", string.pack("BBBB", c[3], c[2], c[1], c[4]))
    -- a builder that never had SetMaterial places bricks clients draw as
    -- nothing (the server still reports them visible)
    local material = opts.material or "Plastic"
    if type(material) == "string" then material = assert(M.MATERIAL[material], "no material " .. material) end
    set("SetMaterial", "NewMaterial", string.pack("B", material), ctx)
    set("SetMaterialAlpha", "NewMaterialAlpha", string.pack("<i4", opts.alpha or 5))
    set("SetCollision", "NewChannels", string.pack("B", opts.collision == false and 0 or M.ALL_COLLISION))
    set("SetVisible", "bNewVisible", string.pack("B", opts.visible == false and 0 or 1))
    if opts.owner then set("SetOwnerId", "NewOwnerId", string.pack("<i4", opts.owner), ctx) end
    return self
end

--- Place a builder at an integer position (brick units). Returns the BrickHandle
--- bytes, or nil when the grid refused it.
function M.place(builder, x, y, z, orientation)
    local r = M.call(cdo("BRLuauBuilderLibrary"), "BRLuauBuilderLibrary", "Place", {
        Self = builder,
        Position = M.ivec(x, y, z),
        Orientation = string.pack("B", orientation or M.Z_UP),
        WorldContextObject = M.ptr(M.world_context()),
    })
    if not M.bool(r.ReturnValue) then return nil end
    return r.OutBrick
end

local function raw_brick_call(fn, handle, args)
    args = args or {}
    args.Self = handle
    return M.call(cdo("BRLuauBrickLibrary"), "BRLuauBrickLibrary", fn, args)
end

--- Whether a brick handle still names a live brick. A null or stale handle
--- (deleted brick, a trace that hit no brick) is fine here.
function M.brick_valid(handle)
    return M.bool(raw_brick_call("IsValid", handle).ReturnValue)
end

-- Every other BRLuauBrickLibrary function aborts the server on an invalid
-- handle (a fatal check, not a Lua error), so they are only called after IsValid.
local function brick_call(fn, handle, args)
    if not M.brick_valid(handle) then error("invalid brick handle", 3) end
    return raw_brick_call(fn, handle, args)
end

function M.brick_info(handle)
    if not M.brick_valid(handle) then return { valid = false } end
    local x, y, z = string.unpack("<i4i4i4", brick_call("GetPosition", handle).ReturnValue)
    return {
        valid = true,
        asset = M.obj(brick_call("GetAsset", handle).ReturnValue),
        position = { x, y, z },
    }
end

--- The grid a brick is on: the world's global grid, or a dynamic grid entity
--- (a contraption, vehicle, prefab spawned as an entity).
function M.brick_grid(handle)
    return M.obj(brick_call("GetGrid", handle).ReturnValue)
end

--- Every dynamic brick grid entity in the world.
function M.grids() return FindAllOf("BrickGridDynamicActor") or {} end

function M.is_visible(handle) return M.bool(brick_call("IsVisible", handle).ReturnValue) end

function M.brick_id(handle) return brick_call("GetId", handle).ReturnValue end

function M.brick_count(grid)
    return cdo("BRLuauGridLibrary"):GetCount(grid or M.global_grid())
end

--- Every brick on a grid (default: the global grid) as BrickHandles. A
--- microchip's gates live on their own grid, a BP_MicrochipBrickGridDynamicActor_C.
function M.grid_bricks(grid)
    local raw = M.call(cdo("BRLuauGridLibrary"), "BRLuauGridLibrary", "GetBricks", { Self = M.ptr(grid or M.global_grid()) }).ReturnValue
    local data, num = string.unpack("<I8i4", raw)
    local out = {}
    for i = 0, num - 1 do out[i + 1] = __peek(data + i * 8, 8) end
    return out
end

--- Decode FString bytes {TCHAR* Data, int32 Num, int32 Max} from a param buffer.
--- Num counts the terminator. Non-ASCII UTF-16 code units come back as '?'.
function M.fstring(bytes)
    local data, num = string.unpack("<I8i4", bytes)
    if data == 0 or num <= 1 then return "" end
    local raw = __peek(data, (num - 1) * 2)
    local chars = {}
    for i = 1, #raw, 2 do
        local unit = string.unpack("<I2", raw, i)
        chars[#chars + 1] = unit < 0x80 and string.char(unit) or "?"
    end
    return table.concat(chars)
end

--- An FText's bytes (borrowed, 0x10) as a Lua string.
function M.ftext(bytes)
    local KT = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    return M.fstring(M.call(KT, "Engine.KismetTextLibrary", "Conv_TextToString", { InText = bytes }).ReturnValue)
end

function M.port_name(port)
    return M.fstring(M.call(cdo("BRLuauComponentLibrary"), "BRLuauComponentLibrary", "GetPortName", { Self = port }).ReturnValue)
end

-- WireValue: 0x20 bytes of payload, then an EWireKind tag byte at +0x20
local WIRE_SIZE_PAYLOAD = 0x20
local function wire(kind, payload)
    return payload .. string.rep("\0", WIRE_SIZE_PAYLOAD - #payload) .. string.pack("B", kind)
end
function M.wire_bool(v) return wire(0, string.pack("B", v and 1 or 0)) end
function M.wire_int(v) return wire(1, string.pack("<i8", v)) end
function M.wire_double(v) return wire(2, string.pack("<d", v)) end

-- WireString: a shared pointer, { object, controller }. The object is
-- { TArray<char> text (NUL-terminated), uint32 hash, uint32 hashed }, made with
-- MakeShared, so the controller ({ vtable, shared and weak counts }) sits 0x10
-- bytes before it in one allocation. The engine compares the text, and fills the
-- hash in on first use. Both blocks come from the game's heap because the engine
-- frees them when the last reference goes; ours is never released, so each
-- string leaks a few bytes.
local wirestring_vtable
local function wirestring(text)
    text = tostring(text)
    assert(not text:find("\0", 1, true), "a WireString can't contain NUL")
    if not wirestring_vtable then
        -- the controller vtable is build-specific, so it is read off a WireString the game made
        local sample = M.call(cdo("BRLuauAssetLibrary"), "BRLuauAssetLibrary", "GetAssetName", { Self = M.ptr(M.asset("PB_DefaultBrick")) }).ReturnValue
        local _, controller = string.unpack("<I8I8", sample)
        wirestring_vtable = string.unpack("<I8", __peek(controller, 8))
    end
    local data = __game_alloc(text .. "\0")
    local block = __game_alloc(string.pack("<I8I8I8i4i4I4I4", wirestring_vtable, 0x100000001, data, #text + 1, #text + 1, 0, 0))
    return string.pack("<I8I8", block + 0x10, block)
end
M.wirestring = wirestring

--- A String wire value (UTF-8 text), for string inputs: chat messages, bot names,
--- string gates, custom event data.
function M.wire_string(text) return wire(7, wirestring(text)) end

-- BrickTransactionReport: 34 int32 counters, then CustomReportLines (TArray)
local REPORT_FIELDS = {
    "BricksPlaced", "BricksDeleted", "BricksChanged", "BricksBlocked", "BricksSkipped", "BricksUntrusted",
    "BricksNotFound", "BricksInvalid", "ComponentsAttached", "ComponentsDetached", "ComponentsChanged",
    "ComponentsQuotaExceeded", "ComponentsUnattachable", "ComponentsUndetachable", "ComponentsSkipped",
    "ComponentsNotFound", "ComponentsInvalid", "ComponentsRestricted", "WiresConnected", "WiresDisconnected",
    "WiresUnconnectable", "WiresUndisconnectable", "WiresSkipped", "WiresNotFound", "WiresInvalid",
    "EntitiesPlaced", "EntitiesDeleted", "EntitiesChanged", "EntitiesBlocked", "EntitiesSkipped",
    "EntitiesUntrusted", "EntitiesNotFound", "EntitiesInvalid", "EntitiesOverQuota",
}

--- Run a transaction as `player` (see M.player): `record(tx)` appends actions,
--- then it executes once. Returns the TransactionReport counters by name.
---   tx.set(id, inputPort, wireValue)
---   tx.connect(sourceId, outputPort, targetId, inputPort)
---   tx.attach(id, componentType)        -- a component type object
---   tx.delete(id)
function M.transaction(player, record)
    local lib = cdo("BRLuauTransactionLibrary")
    local self = string.rep("\0", layout(SCRIPT .. "BRLuauTransactionLibrary:Execute").Self.size)
    local function rec(fn, args)
        args.Self = self
        self = M.call(lib, "BRLuauTransactionLibrary", fn, args).Self
    end
    local tx = {}
    function tx.set(id, port, value) rec("RecordSet", { ID = id, Port = port, Value = value }) end
    function tx.connect(source, output, target, input)
        rec("RecordConnect", { SourceId = source, Output = output, TargetId = target, Input = input })
    end
    function tx.attach(id, type) rec("RecordAttach", { ID = id, Type = M.ptr(type) }) end
    function tx.delete(id) rec("RecordDelete", { ID = id }) end
    record(tx)
    local r = M.call(lib, "BRLuauTransactionLibrary", "Execute", { Self = self, Player = M.ptr(player) }).ReturnValue
    local counts = { string.unpack("<" .. string.rep("i4", #REPORT_FIELDS), r) }
    local report = {}
    for i, n in ipairs(REPORT_FIELDS) do report[n] = counts[i] end
    -- refusals that have no counter (admin gates, for one) only show up here
    local data, num = string.unpack("<I8i4", r, #REPORT_FIELDS * 4 + 1)
    local lines = {}
    for i = 0, num - 1 do lines[#lines + 1] = M.ftext(__peek(data + i * 0x10, 0x10)) end
    report.lines = lines
    return report
end

--- Only the non-zero counters of a report, for printing.
function M.changes(report)
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

--- Spawn an actor of `class` (a UClass) in the game world, at the origin.
function M.spawn(class)
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local actor = GS:BeginDeferredActorSpawnFromClass(M.world_context(), class, xf, 1, nil, 0)
    assert(actor and actor:IsValid(), "spawn failed")
    GS:FinishSpawningActor(actor, xf, 0)
    return actor
end

--- The PlayerState Lua acts as: transactions, admin gates, brick ownership.
---
--- Execute discards every action unless the PlayerState's Owner is a
--- BRPlayerController, and a server with nobody connected has neither, so a
--- controller is spawned once; it creates its own PlayerState, which is the one
--- the game reads permissions through (a second PlayerState merely owned by the
--- controller passes Execute but has no permissions, so admin gates are refused
--- with only a report line). It is marked as the server owner, so it holds every
--- permission whatever the server's roles grant. Edits are also trust-checked
--- against the brick's owner, so the controller is registered in the brick owner
--- table, and bricks this player should edit are placed with that owner index
--- (`BR.builder({ owner = BR.owner_index() })`).
---
--- It is not a connected player: it is left out of BR.players().
function M.player()
    local ps = _G.BR_PLAYER
    if ps and ps:IsValid() and _G.BR_OWNER_INDEX then return ps end
    local pc = M.spawn(StaticFindObject("/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"))
    ps = pc.PlayerState
    assert(ps and ps:IsValid(), "the spawned controller has no PlayerState")
    ps.bIsOwner = true
    _G.BR_PLAYER_CONTROLLER = pc
    _G.BR_PLAYER = ps
    _G.BR_OWNER_INDEX = FindFirstOf("BRGameStateBase"):IdOrRegisterBrickOwner(pc)
    return ps
end

function M.owner_index()
    M.player()
    return _G.BR_OWNER_INDEX
end

local function struct_size(path)
    local st = StaticFindObject(path)
    assert(st and st:IsValid(), "no struct " .. path)
    -- UStruct::PropertiesSize at +0x58
    return string.unpack("<i4", __peek(__addr(st) + 0x58, 4))
end

local function port_names(type_object, offset, descriptor)
    -- a sorted map: TArray of {FName key, descriptor}, at `offset` in the type
    local data, num = string.unpack("<I8i4", __peek(__addr(type_object) + offset, 0x10))
    local stride = 8 + struct_size("/Script/Brickadia." .. descriptor)
    local KS = StaticFindObject("/Script/Engine.Default__KismetStringLibrary")
    local names = {}
    for i = 0, num - 1 do
        local key = __peek(data + i * stride, 8)
        names[#names + 1] = M.fstring(M.call(KS, "Engine.KismetStringLibrary", "Conv_NameToString", { InName = key }).ReturnValue)
    end
    return names
end

--- Port names of a component type (e.g. "BrickComponentType_Expr_LogicalAND"):
--- the FNames that port refs use, which are the property names (`bInputA`).
--- Every registered component type object (native ones are named like their
--- class, `BrickComponentType_Expr_LogicalAND`; Blueprint ones after theirs).
function M.component_types()
    local bcs = StaticFindObject("/Script/Brickadia.Default__BCSLibrary")
    local r = M.call(bcs, "BCSLibrary", "GetAllRegisteredComponentTypes", { WorldContextObject = M.ptr(M.world_context()) })
    local data, num = string.unpack("<I8i4", r.OutComponentTypes)
    local raw = num > 0 and __peek(data, num * 8) or ""
    local types = {}
    for i = 0, num - 1 do
        local t = __obj(string.unpack("<I8", raw, i * 8 + 1))
        if t and t:IsValid() then types[#types + 1] = t end
    end
    return types
end

--- A component type object by name: the transient name of a native type, or
--- any part of a Blueprint type's name ("BotSpawn").
function M.component_type(name)
    local t = StaticFindObject("/Engine/Transient." .. name)
    if t and t:IsValid() then return t end
    for _, c in ipairs(M.component_types()) do
        if c:GetFName():ToString():find(name, 1, true) then return c end
    end
    error("no component type " .. name)
end

function M.ports(type)
    local t = M.component_type(type)
    return {
        inputs = port_names(t, 0x180, "BCSWireInputDescriptor"),
        outputs = port_names(t, 0x190, "BCSWirePortDescriptor"),
    }
end

--- A BRLuauPortRef for input `port` (its property FName, e.g. "bInputA") of the
--- component type `type` (e.g. "BrickComponentType_Expr_LogicalAND"). The ref
--- covers that one type: {name, FirstTypeIndex = the type's u16 index at +0x40, TypeCount = 1}.
function M.input_port(type, port)
    local t = M.component_type(type)
    local index = string.unpack("<I2", __peek(__addr(t) + 0x40, 2))
    return string.pack("<I4I2I2", __fname(port) & 0x7FFFFFFF, index, 1)
end

--- A BRLuauPortRef for output `port` of component type `type` (bit 31 set).
function M.output_port(type, port)
    local ref = M.input_port(type, port)
    local name, first, count = string.unpack("<I4I2I2", ref)
    return string.pack("<I4I2I2", name | 0x80000000, first, count)
end

--- Set a component input on a brick (BrickHandle bytes) through a transaction.
--- Returns the TransactionReport counters.
function M.set_input(handle, type, port, value)
    local id = M.brick_id(handle)
    return M.transaction(M.player(), function(tx) tx.set(id, M.input_port(type, port), value) end)
end

--- Whether a component input currently holds `value`, read through the
--- transaction report: setting an input to the value it already has is skipped
--- (ComponentsSkipped 1), any other value is applied (ComponentsChanged 1). So a
--- false answer has also just set the input to `value`. Any other report (an
--- untrusted brick, a missing component) says nothing about the value and is an
--- error.
function M.input_is(handle, type, port, value)
    local report = M.set_input(handle, type, port, value)
    local skipped, changed = report.ComponentsSkipped, report.ComponentsChanged
    for key, count in pairs(report) do
        if key ~= "lines" and count ~= 0 and key ~= "ComponentsSkipped" and key ~= "ComponentsChanged" then
            error(string.format("input_is: Set was not applied (%s %d)", key, count))
        end
    end
    if skipped + changed ~= 1 then
        error(string.format("input_is: unexpected report (skipped %d, changed %d)", skipped, changed))
    end
    return skipped == 1
end

function M.bots() return FindAllOf("BP_FigureV2_Bot_C") or {} end

--- Teleport an actor (bot, entity) to a world location in UE units.
function M.teleport(actor, x, y, z)
    return actor:K2_TeleportTo({ X = x, Y = y, Z = z }, actor:K2_GetActorRotation())
end

function M.chat(message) M.game_mode():PushChatMessage(message) end

function M.console(command)
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(M.game_mode(), command, nil)
end

--- Orientation 16 (Z+ facing, no rotation) leaves a prefab as it was saved;
--- 0 is X+ facing and turns it on its side.
M.ORIENTATION_IDENTITY = 16

--- Load a prefab bundle into the live world, added to what's there: bricks,
--- components, wires and entities in one synchronous load (10,000 bricks in
--- ~20 ms, against ~70 ms per brick for a fresh builder). `name` is a bundle
--- ref under Saved/Prefabs without ".brz" ("ttt/map", or "Prefabs/Uploads/<hash>.brz"
--- for an uploaded one). The prefab's bounds corner lands at (x, y, z), in world
--- units. Owners come from the file. Returns the brick count added; bricks that
--- would overlap existing ones are skipped (and logged by the game).
function M.load_prefab(name, x, y, z, orientation)
    assert(type(name) == "string" and not name:find('["\r\n]'), "bad prefab name")
    local before = M.brick_count()
    M.console(string.format('br.Prefab.Load "%s" %d %d %d 0 %d', name, math.floor(x or 0), math.floor(y or 0), math.floor(z or 0),
        orientation or M.ORIENTATION_IDENTITY))
    return M.brick_count() - before
end

--- The last `n` lines of the server log that contain `pattern` (plain text).
function M.log_tail(n, pattern)
    local saved = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString()
    local f = assert(io.open(saved .. "Logs/Brickadia.log", "rb"))
    local lines = {}
    for line in f:lines() do
        if not pattern or line:find(pattern, 1, true) then
            lines[#lines + 1] = (line:gsub("\r$", ""))
            if #lines > n then table.remove(lines, 1) end
        end
    end
    f:close()
    return lines
end

function M.roles()
    local pm = FindFirstOf("BRPermissionsManager")
    local roles = { pm.OwnerRole.Name:ToString(), pm.DefaultRole.Name:ToString() }
    pm.CustomRoles:ForEach(function(_, role) roles[#roles + 1] = role:get().Name:ToString() end)
    return roles
end

-- Players and teams. A PlayerState (`ps`) is the handle for a player; its
-- character and controller come from it.

local function str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    return v:ToString()
end

--- The controller of a PlayerState, or nil.
function M.controller(ps)
    local pc = ps:GetOwnerBRPlayerController()
    if pc and pc:IsValid() then return pc end
end

--- Whether a PlayerState belongs to a connected client. Spawned controllers
--- (BR.player's, tests) have no NetConnection.
function M.connected(ps)
    local pc = M.controller(ps)
    return pc ~= nil and pc.NetConnection ~= nil and pc.NetConnection:IsValid()
end

--- PlayerStates of the connected players.
function M.players()
    local out = {}
    FindFirstOf("BRGameStateBase").PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if ps:IsValid() and M.connected(ps) then out[#out + 1] = ps end
    end)
    return out
end

--- A connected player's PlayerState by user name or display name, or nil.
function M.find_player(name)
    local ps = FindFirstOf("BRGameStateBase"):FindClientState(name)
    if ps and ps:IsValid() then return ps end
end

--- BRGuid {A, B, C, D} as the usual 8-4-4-4-12 hex id.
local function guid(g)
    return string.format("%08x-%04x-%04x-%04x-%04x%08x", g.A, g.B >> 16, g.B & 0xFFFF, g.C >> 16, g.C & 0xFFFF, g.D)
end

local function player_lib(fn, obj)
    return M.call(cdo("BRLuauPlayerLibrary"), "BRLuauPlayerLibrary", fn, { Self = M.ptr(obj) }).ReturnValue
end

--- The living character of a PlayerState, or nil.
function M.character(ps)
    if not ps:HasLivingCharacter() then return nil end
    local ch = M.obj(player_lib("GetStatePlayer", ps))
    if ch and ch:IsValid() then return ch end
end

--- The team a PlayerState is on, or nil.
function M.team(ps)
    local t = M.obj(player_lib("GetStateTeam", ps))
    if t and t:IsValid() then return t end
end

--- Name, id, team and health of a player, as plain values.
function M.player_info(ps)
    local team = M.team(ps)
    local ch = M.character(ps)
    local info = {
        name = str(ps:GetUserName()),
        display_name = M.fstring(player_lib("GetStateDisplayName", ps)),
        id = guid(ps:GetUserId()),
        owner = ps:GetIsOwner(),
        connected = M.connected(ps),
        team = team and M.team_info(team).name,
        alive = ch ~= nil,
    }
    if ch then info.health, info.max_health = M.health(ch) end
    return info
end

--- Every team, unaffiliated (id -1) first, then the game mode's teams by id.
function M.teams()
    local gs = FindFirstOf("BRGameStateBase")
    local out = { gs:GetUnaffiliatedTeam() }
    for i = 0, gs:GetNumTeams() - 1 do
        local t = gs:GetTeam(i)
        if t and t:IsValid() then out[#out + 1] = t end
    end
    return out
end

function M.team_info(team)
    local c = team:GetTeamDisplayColor()
    local members = {}
    for i = 0, team:GetNumMembers() - 1 do
        local m = team:GetMember(i)
        if m and m:IsValid() then members[#members + 1] = str(m:GetUserName()) end
    end
    return {
        id = FindFirstOf("BRGameStateBase"):GetTeamId(team),
        name = M.fstring(player_lib("GetTeamName", team)),
        color = { c.R, c.G, c.B, c.A },
        members = members,
    }
end

--- Move a player to the team with `id` (-1: unaffiliated). `respawn` respawns
--- them on it; without it they keep their current character.
function M.join_team(ps, id, respawn)
    local pc = assert(M.controller(ps), "no controller")
    pc:JoinGameModeTeam(id, respawn and true or false, false)
end

-- Health. Brickadia stores damage taken against a limit, so health is
-- limit - damage and a character dies when damage reaches the limit.

--- Current and maximum health of a character.
function M.health(ch)
    local limit = ch:GetDamageLimit()
    return limit - ch:GetDamage(), limit
end

--- Set a character's health (clamped to 0..max); 0 kills it. `max` also
--- changes the maximum.
function M.set_health(ch, hp, max)
    if max then ch:SetDamageLimit(max) end
    local limit = ch:GetDamageLimit()
    ch:SetDamage(limit - math.max(0, math.min(hp, limit)))
end

function M.kill(ch) M.set_health(ch, 0) end

--- Respawn a player (their old character is removed).
function M.respawn(ps)
    assert(M.controller(ps), "no controller"):RestartPlayer(true)
end

-- Leaderboard values are Int64s by name, on a PlayerState or a team.

function M.leaderboard(target, name) return target:GetLeaderboardValue(FName(name)) end
function M.set_leaderboard(target, name, value) target:SetLeaderboardValue(FName(name), value) end
function M.add_leaderboard(target, name, delta) target:IncLeaderboardValue(FName(name), delta) end

-- Inventory: a character's slots hold items (weapons, tools) by class.

--- An item class by its class name ("Weapon_Knife_C" or "Weapon_Knife") or
--- full path, or nil.
function M.item_class(name)
    if name:sub(1, 1) == "/" then
        local c = StaticFindObject(name)
        return c and c:IsValid() and c or nil
    end
    if not name:find("_C$") then name = name .. "_C" end
    local c = FindObject("BlueprintGeneratedClass", name)
    if c and c:IsValid() then return c end
end

--- A character's slots: { slot, count, item = class name or nil }, 0-based.
function M.inventory(ch)
    local inv = ch:GetCharacterInventory()
    local out = {}
    for i = 0, inv:Num() - 1 do
        local e = inv:GetSlotEntry(i)
        local item = e.ItemInstance
        out[#out + 1] = {
            slot = i,
            count = e.Count,
            item = item and item:IsValid() and item:GetClass():GetFName():ToString() or nil,
        }
    end
    return out
end

--- Put an item (a class, or a name for BR.item_class) in a player's slot.
function M.give(ps, slot, item, count)
    local class = type(item) == "string" and assert(M.item_class(item), "no item class " .. item) or item
    assert(M.controller(ps), "no controller"):ServerSetInventorySlot(slot, { Count = count or 1, bIsPlaceable = false, ItemClass = class })
end

function M.clear_slot(ps, slot) assert(M.controller(ps), "no controller"):ServerClearInventorySlot(slot) end

-- Messages and on-screen text for one player. These are client RPCs, which on a
-- controller without a connection would run the client's UI code on the server,
-- so they refuse anything but a connected player.

local function client(ps)
    assert(M.connected(ps), "not a connected player")
    return M.controller(ps)
end

--- A chat line only this player sees.
function M.whisper(ps, message) client(ps):ClientPushChatMessage(message) end

--- The status line above the hotbar. `flash` flashes it if unchanged; it clears
--- itself unless `keep`.
function M.status(ps, message, flash, keep)
    client(ps):ClientPushStatusMessage(message, flash and true or false, not keep)
end

function M.message_box(ps, title, message) client(ps):ClientShowMessageBoxDialog(FText(title), FText(message)) end

--- Show text on a player's screen: what the Controller Display Text gate does.
--- `params` are BRDisplayTextParams fields (Text, PersistentId, Position = { X, Y },
--- Anchor, Pivot, FontSize, FontColor = { R, G, B, A }, Lifetime, ...); the same
--- PersistentId replaces earlier text, and BR.remove_text removes it.
function M.display_text(ps, params)
    local p = { PersistentId = 0, FontSize = 24, Scale = { X = 1, Y = 1 }, FontColor = { R = 255, G = 255, B = 255, A = 255 } }
    for k, v in pairs(params) do p[k] = v end
    client(ps):ClientDisplayText(p)
end

function M.remove_text(ps, id) client(ps):ClientRemoveDisplayText(id) end

-- Entities (physics objects: balls, wheels, vehicles) are BREntityActor actors.

function M.entities() return FindAllOf("BREntityActor") or {} end

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
function M.entity_tag(actor)
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
function M.set_entity_tag(actor, text)
    local path = assert(tag_class(actor), "not an entity or dynamic grid")
    local class = path:match("%.(%w+)$")
    M.call(actor, class, "SetEntityTag", { Tag = wirestring(text) })
end

--- Entities and dynamic grids whose tag is `tag` (all tagged ones when nil).
function M.find_entities(tag)
    local out = {}
    for _, path in ipairs(TAGGED) do
        for _, a in ipairs(FindAllOf(path:match("%.(%w+)$")) or {}) do
            if a:IsValid() then
                local t = M.entity_tag(a)
                if t and (tag == nil or t == tag) then out[#out + 1] = a end
            end
        end
    end
    return out
end

local function entity_lib(fn, ...) return cdo("BRLuauEntityLibrary")[fn](cdo("BRLuauEntityLibrary"), ...) end

--- Spawn an entity of `class` (a UClass, e.g. /Game/Entities/Entity_Ball.Entity_Ball_C)
--- at a world location. opts: frozen, owner (owner index, default BR.owner_index()).
function M.spawn_entity(class, x, y, z, opts)
    opts = opts or {}
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local e = cdo("BRLuauWorldLibrary"):SpawnEntity(M.world_context(), class, xf, opts.frozen and true or false, opts.owner or M.owner_index(), {})
    assert(e and e:IsValid(), "spawn failed")
    return e
end

function M.entity_color(e, slot, r, g, b, a) return entity_lib("SetEntityColor", e, slot, { R = r, G = g, B = b, A = a or 255 }) end
function M.frozen(e) return entity_lib("GetFrozen", e) end
function M.set_frozen(e, frozen) return entity_lib("SetFrozen", e, frozen) end
function M.entity_visible(e) return entity_lib("GetVisible", e) end
function M.set_entity_visible(e, visible) return entity_lib("SetVisible", e, visible) end
function M.entity_owner(e) return entity_lib("GetOwnerId", e) end
function M.delete_entity(e) return entity_lib("DeleteEntity", e) end

-- Component data: any field of a component, ports or not (custom event names,
-- bot settings, button labels), written with the engine's property changelists
-- (BCSLibrary:ApplyChangelist). A changelist is a TArray of 32-byte tokens: a
-- 0x18-byte payload and a type tag at +0x18. The tags used here:
--   2  PushField  { FName }      enter a field of the current struct
--   3  Pop                       leave it
--   28..42 SetLeafValue          set the current field; the tag is 27 + the value's
--                                type (bool 1, int8..uint64 2..9, float 10, double 11,
--                                WireString 15) and must match the field exactly
-- The executor refuses a type mismatch (logged under LogBRPropertyChange) and
-- leaves the field unchanged.

local LEAF = {
    BoolProperty = { 28, function(v) return string.pack("B", v and 1 or 0) end },
    Int8Property = { 29, function(v) return string.pack("<i1", math.tointeger(v)) end },
    ByteProperty = { 30, function(v) return string.pack("<I1", math.tointeger(v)) end },
    Int16Property = { 31, function(v) return string.pack("<i2", math.tointeger(v)) end },
    UInt16Property = { 32, function(v) return string.pack("<I2", math.tointeger(v)) end },
    IntProperty = { 33, function(v) return string.pack("<i4", math.tointeger(v)) end },
    UInt32Property = { 34, function(v) return string.pack("<I4", math.tointeger(v)) end },
    Int64Property = { 35, function(v) return string.pack("<i8", math.tointeger(v)) end },
    UInt64Property = { 36, function(v) return string.pack("<I8", math.tointeger(v)) end },
    FloatProperty = { 37, function(v) return string.pack("<f", v) end },
    DoubleProperty = { 38, function(v) return string.pack("<d", v) end },
    WireString = { 42, wirestring },
    -- the component enums are all uint8-backed; written as their byte value
    EnumProperty = { 30, function(v) return string.pack("<I1", math.tointeger(v)) end },
    -- a weak object reference, { object index, serial }: the payload BRPropertyValue
    -- uses for objects, built by the engine so the serial is right
    WeakObjectProperty = { 41, function(v)
        assert(v and v:IsValid(), "an object field needs a valid UObject")
        return M.call(cdo("BRPropertyValueLibrary"), "BRPropertyValueLibrary", "PropertyValue_MakeObject", { Value = M.ptr(v) }).ReturnValue:sub(1, 16)
    end },
}

local function token(tag, payload)
    payload = payload or ""
    return payload .. string.rep("\0", 0x18 - #payload) .. string.pack("B", tag) .. string.rep("\0", 7)
end

--- The UScriptStruct holding a component type's data (each type object points
--- at it at +0x38).
function M.component_struct(ctype)
    local t = type(ctype) == "string" and M.component_type(ctype) or ctype
    local st = __obj(string.unpack("<I8", __peek(__addr(t) + 0x38, 8)))
    assert(st and st:IsValid(), "no data struct for this component type")
    return st
end

local function field_kind(prop)
    local cls = prop:GetClass():GetFName():ToString()
    if cls == "StructProperty" then return "Struct<" .. prop:GetStruct():GetFName():ToString() .. ">", prop:GetStruct() end
    return cls
end

-- ForEachProperty only lists a struct's own properties; component data structs
-- inherit fields (Interact's PromptCustomLabel lives on InteractableBase)
local function each_field(struct, fn)
    local s = struct
    while s and s:IsValid() do
        s:ForEachProperty(fn)
        s = s:GetSuperStruct()
    end
end

local function find_field(struct, name)
    local found
    each_field(struct, function(prop)
        if not found and prop:GetFName():ToString() == name then found = prop end
    end)
    return found
end

--- A component type's fields, inherited ones included: { { name, type } }, `type`
--- being the property class (`FloatProperty`, `Struct<WireString>`, ...). Writable
--- leaf types are listed in docs/lua-api.md.
function M.component_fields(ctype)
    local out = {}
    each_field(M.component_struct(ctype), function(prop)
        out[#out + 1] = { name = prop:GetFName():ToString(), type = (field_kind(prop)) }
    end)
    return out
end

-- tokens for `path` ("Field" or "Struct.Field") = value
local function field_tokens(struct, path, value)
    local tokens, depth = {}, 0
    local current = struct
    local segments = {}
    for seg in path:gmatch("[^%.]+") do segments[#segments + 1] = seg end
    for i, seg in ipairs(segments) do
        local prop = find_field(current, seg)
        if not prop then error(string.format("no field %s in %s", seg, current:GetFName():ToString()), 3) end
        local kind, inner = field_kind(prop)
        tokens[#tokens + 1] = token(2, string.pack("<I8", __fname(seg)))
        depth = depth + 1
        local leaf = LEAF[kind] or (kind == "Struct<WireString>" and LEAF.WireString)
        if i == #segments then
            if not leaf then error(string.format("%s is a %s, which BR.set_component can't write", path, kind), 3) end
            tokens[#tokens + 1] = token(leaf[1], leaf[2](value))
        else
            if not inner then error(string.format("%s in %s is not a struct", seg, path), 3) end
            current = inner
        end
    end
    for _ = 1, depth do tokens[#tokens + 1] = token(3) end
    return tokens
end

--- Set fields of a brick's component: `values` maps field paths to values,
--- `{ GunSkill = 0.5, bActiveBot = false, BotName = "Bob", ["MoveTarget.X"] = 100 }`;
--- a struct field can also take a table of its fields (`Color = { R = 20, G = 20 }`),
--- and an enum field takes its numeric value.
--- Field types come from reflection, so numbers are converted to the field's own
--- type (an integer field needs an integer). Raises a Lua error for an unknown
--- field or a type it can't write; applies directly, without a transaction or
--- trust check (like BR.place).
function M.set_component(handle, ctype, values)
    local t = type(ctype) == "string" and M.component_type(ctype) or ctype
    local struct = M.component_struct(t)
    local tokens = {}
    -- a table value for a struct field is its fields: Color = { R = 20 } is Color.R
    local flat = {}
    local function flatten(prefix, v)
        if type(v) == "table" then
            for k, inner in pairs(v) do flatten(prefix .. "." .. k, inner) end
        else
            flat[prefix] = v
        end
    end
    for path, value in pairs(values) do flatten(path, value) end
    for path, value in pairs(flat) do
        for _, tk in ipairs(field_tokens(struct, path, value)) do tokens[#tokens + 1] = tk end
    end
    if #tokens == 0 then return end
    if not M.brick_valid(handle) then error("invalid brick handle", 2) end
    local data = table.concat(tokens)
    local addr = __alloc(data)
    M.call(cdo("BCSLibrary"), "BCSLibrary", "ApplyChangelist", {
        WorldContextObject = M.ptr(M.world_context()),
        BrickHandle = handle,
        ComponentType = M.ptr(t),
        Changelist = string.pack("<I8i4i4", addr, #tokens, #tokens),
    })
    __free(addr)
end

-- Reading component data: a brick's component handle resolves (natively, with the
-- game's own validity checks) to the address of its data struct, and fields are
-- read at their reflected offsets.

local function read_wirestring(addr)
    local object = string.unpack("<I8", __peek(addr, 8))
    if object == 0 then return "" end
    local data, num = string.unpack("<I8i4", __peek(object, 12))
    if data == 0 or num <= 1 then return "" end
    return __peek(data, num - 1)
end

-- WireValue: payload at +0, EWireKind at +0x20
local WIRE_READERS = {
    [0] = function(a) return string.byte(__peek(a, 1)) ~= 0 end,
    [1] = function(a) return (string.unpack("<i8", __peek(a, 8))) end,
    [2] = function(a) return (string.unpack("<d", __peek(a, 8))) end,
    [4] = function(a) return { string.unpack("<ddd", __peek(a, 24)) } end,
    [7] = read_wirestring,
    [13] = function(a) return (string.unpack("<f", __peek(a, 4))) end,
    [14] = function(a) return (string.unpack("<i1", __peek(a, 1))) end,
    [15] = function(a) return (string.unpack("<i2", __peek(a, 2))) end,
    [16] = function(a) return (string.unpack("<i4", __peek(a, 4))) end,
    [17] = function(a) return (string.unpack("<I1", __peek(a, 1))) end,
    [18] = function(a) return (string.unpack("<I2", __peek(a, 2))) end,
    [19] = function(a) return (string.unpack("<I4", __peek(a, 4))) end,
    [20] = function(a) return (string.unpack("<I8", __peek(a, 8))) end,
}

--- A WireValue at `addr` as a Lua value: booleans, numbers, strings and vectors
--- ({x, y, z}); nil for none and exec; { kind = n } for kinds not decoded yet.
local function read_wirevalue(addr)
    local kind = string.byte(__peek(addr + 0x20, 1))
    if kind == 29 or kind == 12 then return nil end
    local reader = WIRE_READERS[kind]
    if reader then return reader(addr) end
    return { kind = kind }
end
M.read_wirevalue = read_wirevalue

local SCALAR_READ = {
    Int8Property = "<i1", ByteProperty = "<I1", Int16Property = "<i2", UInt16Property = "<I2",
    IntProperty = "<i4", UInt32Property = "<I4", Int64Property = "<i8", UInt64Property = "<I8",
    FloatProperty = "<f", DoubleProperty = "<d", EnumProperty = "<I1",
}

local function read_field(addr, prop, depth)
    local kind, inner = field_kind(prop)
    local at = addr + prop:GetOffset_Internal()
    if kind == "BoolProperty" then return string.byte(__peek(at, 1)) ~= 0 end
    local fmt = SCALAR_READ[kind]
    if fmt then return (string.unpack(fmt, __peek(at, 8))) end
    if kind == "Struct<WireString>" then return read_wirestring(at) end
    if kind == "Struct<WireValue>" then return read_wirevalue(at) end
    if inner and depth < 3 then
        local out = {}
        inner:ForEachProperty(function(p) out[p:GetFName():ToString()] = read_field(at, p, depth + 1) end)
        return out
    end
    return nil
end

--- The address of a brick's component data, or nil if the brick has no such
--- component.
function M.component_address(handle, ctype)
    if not M.brick_valid(handle) then error("invalid brick handle", 2) end
    local t = type(ctype) == "string" and M.component_type(ctype) or ctype
    local r = M.call(cdo("BRLuauComponentLibrary"), "BRLuauComponentLibrary", "Get", { Self = M.ptr(t), Brick = handle })
    if not M.bool(r.ReturnValue) then return nil end
    return __component_data(r.OutComponent)
end

--- One field of a brick's component ("GunSkill", "MoveTarget.X"): booleans,
--- numbers, strings (WireString), wire values and structs (as tables). Fields of
--- other types (object references, arrays) read as nil.
function M.get_component(handle, ctype, path)
    local t = type(ctype) == "string" and M.component_type(ctype) or ctype
    local addr = M.component_address(handle, t)
    if not addr then return nil end
    local struct = M.component_struct(t)
    local segments = {}
    for seg in path:gmatch("[^%.]+") do segments[#segments + 1] = seg end
    for i, seg in ipairs(segments) do
        local prop = find_field(struct, seg)
        if not prop then error(string.format("no field %s in %s", seg, struct:GetFName():ToString()), 2) end
        if i == #segments then return read_field(addr, prop, 0) end
        local _, inner = field_kind(prop)
        if not inner then error(string.format("%s in %s is not a struct", seg, path), 2) end
        addr = addr + prop:GetOffset_Internal()
        struct = inner
    end
end

--- Every readable field of a brick's component as a table (wire dispatch
--- bookkeeping left out), or nil if the brick has no such component.
function M.component_data(handle, ctype)
    local t = type(ctype) == "string" and M.component_type(ctype) or ctype
    local addr = M.component_address(handle, t)
    if not addr then return nil end
    local out = {}
    M.component_struct(t):ForEachProperty(function(prop)
        local name = prop:GetFName():ToString()
        if not name:find("^Dispatch_") then out[name] = read_field(addr, prop, 0) end
    end)
    return out
end

-- Array and map variable gates. Their Value has no reflected fields; the layouts
-- were read off live gates:
--   BRDynamicArray (48 bytes): Data, Num (i32), Max (i32), the element's
--     UBRReflectionPropertyInfo, two per-type ops pointers, ElementSize (i64).
--     Elements are packed: Int64 and Double 8 bytes, WireString 16.
--   BRDynamicMap (72 bytes): Data, Num, Max, key info, value info, a hash index,
--     key ops, value ops, KeySize (i32), EntrySize (i32), ValueSize (i64).
--     Entries are packed {key, value} pairs; lookups go through the hash index,
--     so only values can be changed in place, not keys.
-- The type of a collection is fixed by the gate (or the circuit that declared
-- it), so writes encode values in the type the collection already holds.

local ARRAY_VAR, MAP_VAR = "BrickComponentType_ArrayVar", "BrickComponentType_MapVar"

local ELEMENT_CODECS = {
    BRReflectionPropertyInfo_Int64 = {
        read = function(a) return (string.unpack("<i8", __peek(a, 8))) end,
        encode = function(v) return string.pack("<i8", math.tointeger(v) or error("not an integer: " .. tostring(v), 3)) end,
    },
    BRReflectionPropertyInfo_Double = {
        read = function(a) return (string.unpack("<d", __peek(a, 8))) end,
        encode = function(v) return string.pack("<d", assert(tonumber(v), "not a number")) end,
    },
    BRReflectionPropertyInfo_WireString = {
        read = function(a) return read_wirestring(a) end,
        encode = function(v) return wirestring(tostring(v)) end,
    },
}

-- type info objects by address; a miss rescans, since the game makes new ones
local info_names = {}
local function info_name(addr)
    if info_names[addr] == nil then
        for _, o in ipairs(FindAllOf("BRReflectionPropertyInfo") or {}) do
            info_names[__addr(o)] = o:GetClass():GetFName():ToString()
        end
        info_names[addr] = info_names[addr] or false
    end
    return info_names[addr] or nil
end

local function codec(info)
    local name = info_name(info)
    local c = name and ELEMENT_CODECS[name]
    if not c then error("unsupported element type " .. tostring(name or string.format("%x", info)), 3) end
    return c, name
end

local function collection(handle, ctype)
    local t = M.component_type(ctype)
    local addr = M.component_address(handle, t)
    if not addr then error("the brick has no " .. ctype, 3) end
    local struct = M.component_struct(t)
    return addr, addr + find_field(struct, "Value"):GetOffset_Internal(), addr + find_field(struct, "MutationVersion"):GetOffset_Internal()
end

local function bump(version_addr)
    __poke(version_addr, string.pack("<I8", string.unpack("<I8", __peek(version_addr, 8)) + 1))
end

--- An Array Variable gate's elements as a Lua list, and the element type's name
--- (BRReflectionPropertyInfo_Int64 / _Double / _WireString).
function M.read_array(handle)
    local _, value = collection(handle, ARRAY_VAR)
    local data, num, _, info, _, _, size = string.unpack("<I8i4i4I8I8I8I8", __peek(value, 48))
    local c, name = codec(info)
    local out = {}
    for i = 0, num - 1 do out[i + 1] = c.read(data + i * size) end
    return out, name
end

--- Replace an Array Variable gate's elements with `values`, converted to the
--- array's element type. Gates that read the array see the new elements on their
--- next run; gates that only react to changes made through array gates are not
--- told. Replaced strings are not released (a few bytes each).
function M.write_array(handle, values)
    local _, value, version = collection(handle, ARRAY_VAR)
    local data, _, max, info, _, _, size = string.unpack("<I8i4i4I8I8I8I8", __peek(value, 48))
    local c = codec(info)
    local parts = {}
    for i, v in ipairs(values) do parts[i] = c.encode(v) end
    local bytes, n = table.concat(parts), #values
    assert(#bytes == n * size, "element size mismatch")
    if n <= max and data ~= 0 then
        if n > 0 then __poke(data, bytes) end
        __poke(value + 8, string.pack("<i4", n))
    else
        -- a bigger buffer from the engine's heap, which the array later grows or
        -- frees itself
        local mem = __game_alloc(bytes)
        __poke(value, string.pack("<I8i4i4", mem, n, n))
        if data ~= 0 then __game_free(data) end
    end
    bump(version)
end

--- A Map Variable gate's entries as a list of { key, value }, and the key and
--- value type names.
function M.read_map(handle)
    local _, value = collection(handle, MAP_VAR)
    local data, num, _, kinfo, vinfo, _, _, _, ksize, stride = string.unpack("<I8i4i4I8I8I8I8I8i4i4", __peek(value, 72))
    local kc, kname = codec(kinfo)
    local vc, vname = codec(vinfo)
    local out = {}
    for i = 0, num - 1 do
        local e = data + i * stride
        out[i + 1] = { kc.read(e), vc.read(e + ksize) }
    end
    return out, kname, vname
end

--- Change the value stored under an existing key of a Map Variable gate.
--- Returns false when the key isn't there: adding keys needs the map's hash
--- index, so new keys go through a Set gate.
function M.set_map_value(handle, key, v)
    local _, value, version = collection(handle, MAP_VAR)
    local data, num, _, kinfo, vinfo, _, _, _, ksize, stride = string.unpack("<I8i4i4I8I8I8I8I8i4i4", __peek(value, 72))
    local kc, vc = codec(kinfo), codec(vinfo)
    for i = 0, num - 1 do
        local e = data + i * stride
        if kc.read(e) == key then
            __poke(e + ksize, vc.encode(v))
            bump(version)
            return true
        end
    end
    return false
end

-- Change events for variable gates. Gates change these in the engine's own wire
-- code, which no UFunction sees, so each watched gate is checked once a tick:
-- arrays and maps by their MutationVersion counter, plain variables by their
-- 33 value bytes. A handful of bytes per gate per tick.

local VAR = "BrickComponentType_Var"
local WIRE_VALUE_SIZE = 0x21

-- the gates of `ctype` named by `target`: one handle, a list of them, or a grid
-- (every such gate on it now; gates added later are not picked up)
local function watch_targets(target, ctype)
    local list
    if type(target) == "string" then
        list = { target }
    elseif type(target) == "table" then
        list = target
    else
        list = M.grid_bricks(target)
    end
    local out = {}
    for _, h in ipairs(list) do
        if M.brick_valid(h) and M.component_address(h, ctype) then out[#out + 1] = h end
    end
    return out
end

local function watch(target, ctype, field, size, decode, fn)
    local t = M.component_type(ctype)
    local offset = find_field(M.component_struct(t), field):GetOffset_Internal()
    local gates = {}
    for _, h in ipairs(watch_targets(target, ctype)) do
        local addr = M.component_address(h, t)
        gates[#gates + 1] = { handle = h, addr = addr, last = __peek(addr + offset, size), value = decode(h, addr + offset) }
    end
    local stop
    stop = M.on_tick(function()
        for i = #gates, 1, -1 do
            local g = gates[i]
            -- a deleted gate's storage slot can be reused by another component
            if not M.brick_valid(g.handle) or M.component_address(g.handle, t) ~= g.addr then
                table.remove(gates, i)
            else
                local now = __peek(g.addr + offset, size)
                if now ~= g.last then
                    g.last = now
                    local value = decode(g.handle, g.addr + offset)
                    -- a string's bytes are a pointer to its text, so setting an
                    -- equal string changes them without changing the value
                    if type(value) ~= "string" or value ~= g.value then
                        g.value = value
                        fn(value, g.handle)
                    end
                end
            end
        end
        if #gates == 0 then stop() end
    end)
    return stop, #gates
end

--- Call fn(value, handle) whenever a Variable gate's value changes. `target` is a
--- gate's handle, a list of them, or a grid (a microchip's grid, say), which
--- watches every Variable gate on it at the time of the call. Returns a function
--- that stops watching, and how many gates are watched.
function M.on_var_changed(target, fn)
    return watch(target, VAR, "Value", WIRE_VALUE_SIZE, function(_, at) return read_wirevalue(at) end, fn)
end

--- Like BR.on_var_changed for Array Variable gates: fn(elements, handle) after
--- each change (pushes, sets, BR.write_array).
function M.on_array_changed(target, fn)
    return watch(target, ARRAY_VAR, "MutationVersion", 8, function(h) return (M.read_array(h)) end, fn)
end

--- Like BR.on_var_changed for Map Variable gates: fn(entries, handle), entries as
--- BR.read_map gives them.
function M.on_map_changed(target, fn)
    return watch(target, MAP_VAR, "MutationVersion", 8, function(h) return (M.read_map(h)) end, fn)
end

-- Ticks: one native tick listener per Lua state runs every BR.on_tick callback.
local tick_fns = {}
local ticking = false

--- Run fn(deltaSeconds) at the start of every engine tick, on the game thread.
--- Returns a function that stops it.
function M.on_tick(fn)
    if not ticking then
        ticking = true
        __on_tick(function(dt)
            for i = #tick_fns, 1, -1 do
                local f = tick_fns[i]
                local ok, err = pcall(f, dt)
                if not ok then print("[BR.on_tick] " .. tostring(err) .. "\n") end
            end
        end)
    end
    tick_fns[#tick_fns + 1] = fn
    return function()
        for i, f in ipairs(tick_fns) do if f == fn then table.remove(tick_fns, i) break end end
    end
end

-- Custom events. Send Custom Event gates reach receivers (Event_Custom gates)
-- whose EventName matches; the global variants reach every receiver in the world.

-- where BR places the gates it needs when no position is given: the first free
-- row high above a corner of the map. It looks rather than counts, because each
-- Lua state (and every reload of this module) starts counting afresh.
local function helper_position()
    local lib = cdo("BRLuauGridLibrary")
    local grid = M.ptr(M.global_grid())
    for i = 0, 2000 do
        local x, y, z = -60000 + (i % 50) * 200, -60000 + (i // 50) * 200, 30000
        local busy = M.bool(M.call(lib, "BRLuauGridLibrary", "AnyInBox", {
            Self = grid, Min = M.ivec(x - 20, y - 20, z - 10), Max = M.ivec(x + 120, y + 60, z + 10),
        }).ReturnValue)
        if not busy then return x, y, z end
    end
    error("no free space for helper gates", 3)
end

-- Gates BR places on someone else's grid (a custom event's target) go in the first
-- empty spot near the grid's origin, hidden and without collision, so they don't
-- disturb the build.
local function free_spot(grid)
    local lib = cdo("BRLuauGridLibrary")
    for ring = 0, 30 do
        for dx = -ring, ring do
            for dy = -ring, ring do
                if math.max(math.abs(dx), math.abs(dy)) == ring then
                    local x, y, z = dx * 20, dy * 20, 6
                    local busy = M.bool(M.call(lib, "BRLuauGridLibrary", "AnyInBox", {
                        Self = M.ptr(grid), Min = M.ivec(x - 10, y - 10, z - 6), Max = M.ivec(x + 10, y + 10, z + 6),
                    }).ReturnValue)
                    if not busy then return x, y, z end
                end
            end
        end
    end
    error("no free spot on the target grid", 3)
end

local function place_helper(asset, x, y, z, grid)
    local b = M.place(M.builder({ asset = asset, owner = M.owner_index(), grid = grid, visible = false, collision = false }), x, y, z)
    return assert(b, "could not place " .. asset)
end

-- ticks between two deliveries of one custom event sender
local SEND_GAP = 2

local function opts_position(opts)
    if opts and opts.at then return opts.at[1], opts.at[2], opts.at[3] end
    return helper_position()
end

--- Place a Send Custom Event gate named `name` (with the trigger that fires it) and
--- return `ev`: `ev.send(...)` fires the event with up to 8 data values (wire
--- values: BR.wire_bool / int / double / string). Like BR.trigger, send from a
--- later call than the one that placed it. Every send is delivered: sends made
--- faster than the gate can fire are queued and go out a couple of ticks apart,
--- in order. `send` returns how many are still waiting.
---
--- opts.at = {x, y, z} places it there (default: out of the way above the map).
--- opts.target = a brick grid entity (BR.grids(), BR.brick_grid(brick)) sends the
--- event to that entity only, reaching receivers on it that listen for object
--- events; without it the event is global.
function M.custom_event(name, opts)
    opts = opts or {}
    local x, y, z = opts_position(opts)
    local targeted = opts.target ~= nil
    local SEND = M.component_type(targeted and "BrickComponentType_Exec_SendCustomEvent" or "SendCustomEventGlobal")
    local SN = SEND:GetFName():ToString()
    local sender = place_helper(targeted and "PB_Gate_Exec_SendCustomEvent" or "PB_Gate_Exec_SendCustomEventGlobal", x, y, z)
    M.set_component(sender, SEND, { EventName = name })
    if targeted then
        -- a transaction can't set an object value, so the target arrives by wire:
        -- a grid reader on the target grid reports that grid
        local READ = M.component_type("Internal_ReadBrickGrid")
        local gx, gy, gz = free_spot(opts.target)
        local reader = place_helper("B_1x1_Gate_Internal_ReadBrickGrid", gx, gy, gz, opts.target)
        M.transaction(M.player(), function(tx)
            tx.connect(M.brick_id(reader), M.output_port(READ:GetFName():ToString(), "BrickGrid"), M.brick_id(sender), M.input_port(SN, "Target"))
        end)
    end
    local trigger = M.trigger(x, y + 40, z)
    trigger.connect(sender, SN, "ExecIn")
    local ev = { brick = sender, trigger = trigger }
    -- The trigger fires the sender a tick after it is bumped, and the sender
    -- reads its data inputs then, so a second send before that would overwrite
    -- the first one's data and the trigger would fire once. Sends wait in a
    -- queue and go out SEND_GAP ticks apart.
    local queue, wait, stop = {}, 0, nil
    local function deliver(data)
        if data.n > 0 then
            M.transaction(M.player(), function(tx)
                for i = 1, math.min(data.n, 8) do
                    tx.set(M.brick_id(sender), M.input_port(SN, "DataIn" .. i), data[i])
                end
            end)
        end
        trigger.fire()
        wait = SEND_GAP
    end
    function ev.send(...)
        local data = table.pack(...)
        if wait == 0 and #queue == 0 then
            deliver(data)
        else
            queue[#queue + 1] = data
        end
        stop = stop or M.on_tick(function()
            if wait > 0 then wait = wait - 1 end
            if wait > 0 then return end
            if #queue > 0 then return deliver(table.remove(queue, 1)) end
            stop()
            stop = nil
        end)
        return #queue
    end
    return ev
end

--- Call fn(data, count) whenever the custom event `name` fires, from a Send Custom
--- Event gate built in game or BR.custom_event. `data` holds the event's
--- DataOut1..8 values (booleans, numbers, strings, vectors); `count` is how many
--- times it fired since the last tick (data is the latest). Runs on the game
--- thread, a tick or two after the event. Returns a function that stops it.
---
--- opts.entity = a brick grid entity listens for events sent to that entity
--- (targeted sends); without it, global events. opts.at = {x, y, z} places the
--- counting gates (default: out of the way above the map).
---
--- Exec signals never pass through anything Lua can hook, so BR places a small
--- circuit: a receiver named `name` (on the entity's grid when there is one,
--- hidden) whose ExecOut increments a variable, and reads the variable each tick.
function M.on_custom_event(name, fn, opts)
    opts = opts or {}
    local x, y, z = opts_position(opts)
    local ps = M.player()
    local RECV = M.component_type(opts.entity and "BrickComponentType_Event_Custom" or "Event_CustomGlobal")
    local VAR = M.component_type("BrickComponentType_Var")
    local INC = M.component_type("Exec_Var_Increment")
    local recv
    if opts.entity then
        local gx, gy, gz = free_spot(opts.entity)
        recv = place_helper("PB_Gate_Event_Custom", gx, gy, gz, opts.entity)
        M.set_component(recv, RECV, { EventName = name, bIsObjectEvent = true })
    else
        recv = place_helper("PB_Gate_Event_CustomGlobal", x, y, z)
        M.set_component(recv, RECV, { EventName = name })
    end
    local inc = place_helper("B_1x1_Gate_Exec_Var_Increment", x + 40, y, z)
    local var = place_helper("B_1x1_Gate_Variable", x + 80, y, z)
    local RN, IN, VN = RECV:GetFName():ToString(), INC:GetFName():ToString(), VAR:GetFName():ToString()
    M.transaction(ps, function(tx)
        tx.connect(M.brick_id(recv), M.output_port(RN, "ExecOut"), M.brick_id(inc), M.input_port(IN, "Exec"))
        tx.connect(M.brick_id(var), M.output_port(VN, "VarRef"), M.brick_id(inc), M.input_port(IN, "VarRef"))
        tx.set(M.brick_id(inc), M.input_port(IN, "Value"), M.wire_int(1))
    end)
    local value_offset = find_field(M.component_struct(VAR), "Value"):GetOffset_Internal()
    local data_offsets = {}
    for i = 1, 8 do data_offsets[i] = find_field(M.component_struct(RECV), "DataOut" .. i):GetOffset_Internal() end
    local var_addr, recv_addr, last
    local stop
    stop = M.on_tick(function()
        if not M.brick_valid(var) or not M.brick_valid(recv) then return stop() end
        var_addr = var_addr or M.component_address(var, VAR)
        recv_addr = recv_addr or M.component_address(recv, RECV)
        if not var_addr or not recv_addr then return end
        local value = read_wirevalue(var_addr + value_offset)
        local count = type(value) == "number" and math.tointeger(value) or 0
        if last == nil then last = count return end
        if count == last then return end
        local fired = count - last
        last = count
        local data = {}
        for i = 1, 8 do data[i] = read_wirevalue(recv_addr + data_offsets[i]) end
        fn(data, fired)
    end)
    return stop
end

-- Calls into the game: UE4SS's RegisterHook hands over reflected parameters only,
-- so a parameter like a BrickHandle arrives empty. BR.on_call gets the raw bytes.

--- Run fn(self, params) before every call of the UFunction `path`
--- ("/Script/Brickadia.Class:Function"), on the game thread. `params` is the
--- parameter buffer as bytes (offsets from __fn_layout). Calls a client makes to
--- the server (RPCs) arrive this way too. Hooks last until the mod stops.
function M.on_call(path, fn)
    __on_call(path, function(self, params)
        local ok, err = pcall(fn, self, params)
        if not ok then print("[BR.on_call] " .. path .. ": " .. tostring(err) .. "\n") end
    end)
end

--- fn(character, brick, nearby) whenever a character starts interacting with a
--- brick: BR.on("interact") with the character first.
function M.on_interact(fn)
    return M.on("interact", function(_, info) fn(info.character, info.brick, info.nearby) end)
end

--- fn(character) when a character lets go (releases a held button).
function M.on_interact_end(fn)
    return M.on("interact_end", function(_, info) fn(info.character) end)
end

--- Call fn(player, manager) when a player saves an avatar in the editor.
--- `manager` is their BRPlayerAvatarManagerComponent. The change goes through
--- regardless; to enforce a look (team uniforms), set it again on a later tick.
--- Returns a function that stops it.
function M.on_avatar_change(fn)
    return M.on("avatar", function(player, info) fn(player, info.manager) end)
end

--- Interact with a brick as `character`, as if its player clicked it (a button
--- stays held until BR.stop_interact).
function M.interact(character, brick, nearby)
    if not M.brick_valid(brick) then error("invalid brick handle", 2) end
    M.call(character, "BRCharacter", "ServerMaybeStartInteract", {
        BrickHandle = brick, AnimType = "\0", bIsNearbyInteraction = nearby == false and "\0" or "\1",
    })
end

function M.stop_interact(character)
    character:ServerStopAnyInteract()
end

-- Player events. Each is a UFunction the action passes through on the server: an
-- RPC the client sends (chat, tools, emotes), an RPC the server multicasts
-- (death), or a Blueprint event (login, damage). BR.on hooks it with BR.on_call
-- and hands the handler the PlayerState behind it and the event's details.

local function class_of(name) return StaticFindObject(SCRIPT .. name) end

--- The PlayerState behind an object (a controller, character, tool, weapon or a
--- tool's control mode), or nil (bots, the world).
function M.player_of(obj)
    local PS, PC, CH, ACTOR = class_of("BRPlayerState"), class_of("BRPlayerController"), class_of("BRCharacter"), StaticFindObject("/Script/Engine.Actor")
    for _ = 1, 8 do
        if not obj or not obj:IsValid() then return nil end
        if obj:IsA(PS) then return obj end
        if obj:IsA(PC) then
            local ps = obj.PlayerState
            return ps and ps:IsValid() and ps or nil
        end
        if obj:IsA(CH) then
            local ps = obj:GetBRPlayerState()
            return ps and ps:IsValid() and ps or nil
        end
        if obj:IsA(ACTOR) then obj = obj:GetOwner() else obj = obj:GetOuter() end
    end
end

local function brick_at(params, offset)
    local h = params:sub(offset + 1, offset + 8)
    return M.brick_valid(h) and h or nil
end
local function object_at(params, offset)
    local o = M.obj(params:sub(offset + 1, offset + 8))
    return o and o:IsValid() and o or nil
end
local function fstring_at(params, offset) return M.fstring(params:sub(offset + 1, offset + 16)) end
local function name_of(o) return o and o:IsValid() and o:GetFName():ToString() or nil end
local function ivec_at(params, offset) return { string.unpack("<i4i4i4", params, offset + 1) } end
local function vec_at(params, offset) return { string.unpack("<ddd", params, offset + 1) } end
local function fname_at(params, offset)
    local s = M.fstring(M.call(StaticFindObject("/Script/Engine.Default__KismetStringLibrary"), "Engine.KismetStringLibrary",
        "Conv_NameToString", { InName = params:sub(offset + 1, offset + 8) }).ReturnValue)
    return s ~= "None" and s or nil
end

-- What a projectile stopped against. FHitResult names the actor only through a
-- weak handle Lua can't resolve, so a brick or entity is found by tracing a few
-- units into the surface, and a character from the bone it hit plus being the
-- nearest one to the point.
local function projectile_target(pos, normal, bone)
    if bone then
        local best, best_d
        for _, ch in ipairs(FindAllOf("BRCharacter") or {}) do
            if ch:IsValid() then
                local l = ch:K2_GetActorLocation()
                local d = (l.X - pos[1]) ^ 2 + (l.Y - pos[2]) ^ 2 + (l.Z - pos[3]) ^ 2
                if not best_d or d < best_d then best, best_d = ch, d end
            end
        end
        if best and best_d < 300 ^ 2 then return { character = best, player = M.player_of(best) } end
    end
    local from = { pos[1] + normal[1] * 4, pos[2] + normal[2] * 4, pos[3] + normal[3] * 4 }
    local hit = M.raycast(from, { -normal[1], -normal[2], -normal[3] }, { distance = 12 })
    if hit and hit.brick then return { brick = hit.brick } end
    if hit and hit.entity then return { entity = hit.entity } end
    return {}
end

-- event -> list of { UFunction path, decode(self, params) -> player, info }
local EVENTS = {
    join = { { "/Script/Engine.GameModeBase:K2_PostLogin", function(_, p)
        local pc = object_at(p, 0)
        return M.player_of(pc), { controller = pc }
    end } },
    leave = { { "/Script/Engine.GameModeBase:K2_OnLogout", function(_, p)
        local pc = object_at(p, 0)
        return M.player_of(pc), { controller = pc }
    end } },
    chat = { { SCRIPT .. "BRPlayerController:ServerPushChatMessage", function(self, p)
        return M.player_of(self), { message = fstring_at(p, 0) }
    end } },
    typing = { { SCRIPT .. "BRPlayerController:ServerSetTyping", function(self, p)
        return M.player_of(self), { typing = p:byte(1) ~= 0 }
    end } },
    death = { { SCRIPT .. "BRCharacter:MulticastHandleDeath", function(self, p)
        local killer = object_at(p, 0x10)
        return M.player_of(self), {
            character = self, damage = (string.unpack("<f", p, 1)), killer = killer,
            damage_type = name_of(object_at(p, 0x08)), cause = object_at(p, 0x18),
        }
    end } },
    -- Brickadia's damage doesn't go through the engine's ReceiveAnyDamage; every
    -- character that is hurt plays a pain sound for everyone, which carries the amount
    damage = { { SCRIPT .. "BRCharacter:MulticastPlayPainSound", function(self, p)
        return M.player_of(self), { character = self, damage = (string.unpack("<f", p, 1)) }
    end } },
    emote = { { SCRIPT .. "BRCharacter:ServerStartEmoting", function(self, p)
        return M.player_of(self), { character = self, emote = name_of(object_at(p, 0)) }
    end } },
    emote_end = { { SCRIPT .. "BRCharacter:ServerStopEmoting", function(self)
        return M.player_of(self), { character = self }
    end } },
    interact = { { SCRIPT .. "BRCharacter:ServerMaybeStartInteract", function(self, p)
        return M.player_of(self), { character = self, brick = brick_at(p, 0), nearby = p:byte(10) ~= 0 }
    end } },
    interact_end = { { SCRIPT .. "BRCharacter:ServerStopAnyInteract", function(self)
        return M.player_of(self), { character = self }
    end } },
    -- a melee weapon's hit as the attacking client reports it: event struct with
    -- HitLocation 0x08, HitActor 0x20, HitBrick 0x28, ClientDamage 0x30, backstab 0x34
    melee_hit = { { SCRIPT .. "BRWeaponBase:ServerApplyMeleePredictedDamage", function(self, p)
        local actor = object_at(p, 0x20)
        local info = { weapon = name_of(self:GetClass()), position = vec_at(p, 0x08), damage = (string.unpack("<f", p, 0x31)),
            backstab = p:byte(0x35) ~= 0, actor = actor, brick = brick_at(p, 0x28) }
        if actor and actor:IsA(StaticFindObject(SCRIPT .. "BRCharacter")) then
            info.character, info.player = actor, M.player_of(actor)
        end
        return M.player_of(self), info
    end } },
    -- a player saving their avatar in the editor; the change can't be refused
    -- here, but the manager can be given another avatar on the next tick
    avatar = { { SCRIPT .. "BRPlayerAvatarManagerComponent:ServerUpdatePlayerAvatar", function(self)
        return M.player_of(self), { manager = self }
    end } },
    -- a projectile stopping against something: the hit result is the whole
    -- parameter block (Location 0x10, ImpactPoint 0x28, ImpactNormal 0x58,
    -- BoneName 0xE0); bounces don't count
    projectile_hit = { { SCRIPT .. "BRWeaponProjectile:ProcessStop", function(self, p)
        local pos, normal, bone = vec_at(p, 0x28), vec_at(p, 0x58), fname_at(p, 0xE0)
        local info = { projectile = name_of(self:GetClass()), position = pos, normal = normal, bone = bone }
        for k, v in pairs(projectile_target(pos, normal, bone)) do info[k] = v end
        local by = self.InstigatorState
        return (by and by:IsValid()) and by or M.player_of(self), info
    end } },
    shoot = { { SCRIPT .. "BRWeaponBase:MulticastReplicateAcceleratedProjectiles", function(self)
        return M.player_of(self), { weapon = name_of(self:GetClass()) }
    end }, { SCRIPT .. "BRWeaponBase:MulticastReplicateAcceleratedProjectilesWithSeed", function(self)
        return M.player_of(self), { weapon = name_of(self:GetClass()) }
    end } },
    place = {
        { SCRIPT .. "BRTool_Placer:ServerPlaceSimpleBrickVolume", function(self, p)
            local b, g, r, a = string.byte(p, 0x91, 0x94)
            return M.player_of(self), { kind = "brick", position = ivec_at(p, 0x98), orientation = p:byte(0xC1), color = { r, g, b, a } }
        end },
        { SCRIPT .. "BRTool_Placer:ServerPlaceSimpleEntityVolume", function(self, p)
            return M.player_of(self), { kind = "entity", entity = name_of(object_at(p, 0x78)), position = ivec_at(p, 0x84) }
        end },
        { SCRIPT .. "BRTool_Placer:ServerPlaceCurrentPrefab", function(self, p)
            return M.player_of(self), { kind = "prefab", position = ivec_at(p, 0x78) }
        end },
    },
    delete = {
        { SCRIPT .. "BRTool_Hammer:ServerHammerBrick", function(self, p)
            return M.player_of(self), { kind = "hammer", brick = brick_at(p, 0) }
        end },
        { SCRIPT .. "BRPlacerControlMode_Delete:ServerHammerBrick", function(self, p)
            return M.player_of(self), { kind = "placer", brick = brick_at(p, 0) }
        end },
        { SCRIPT .. "BRTool_Selector:ServerDeleteSelection", function(self)
            return M.player_of(self), { kind = "selection" }
        end },
    },
    change = {
        { SCRIPT .. "BRTool_Painter:ServerPaintBrick", function(self, p) return M.player_of(self), { kind = "paint", brick = brick_at(p, 0) } end },
        { SCRIPT .. "BRTool_Painter:ServerFillPaint", function(self, p) return M.player_of(self), { kind = "fill", brick = brick_at(p, 0) } end },
        { SCRIPT .. "BRTool_Applicator:ServerApplyBrickState", function(self, p) return M.player_of(self), { kind = "apply", brick = brick_at(p, 0) } end },
        { SCRIPT .. "BRTool_Applicator:ServerPasteBrick", function(self, p) return M.player_of(self), { kind = "paste", brick = brick_at(p, 0) } end },
        { SCRIPT .. "BRTool_Applicator:ServerResetBrickState", function(self, p) return M.player_of(self), { kind = "reset", brick = brick_at(p, 0) } end },
        { SCRIPT .. "BRTool_Applicator:ServerRemoveComponent", function(self, p) return M.player_of(self), { kind = "remove_component", brick = brick_at(p, 0) } end },
        { SCRIPT .. "BRTool_Resizer:ServerApplyBrickTransform", function(self, p) return M.player_of(self), { kind = "resize", brick = brick_at(p, 0) } end },
        { SCRIPT .. "BRTool_Resizer:ServerApplyBrickRotation", function(self, p) return M.player_of(self), { kind = "rotate", brick = brick_at(p, 0) } end },
        { SCRIPT .. "BRTool_Resizer:ServerApplyBrickDirection", function(self, p) return M.player_of(self), { kind = "direction", brick = brick_at(p, 0) } end },
    },
}
M.EVENTS = {}
for name in pairs(EVENTS) do M.EVENTS[#M.EVENTS + 1] = name end
table.sort(M.EVENTS)

local handlers = {}

--- Call fn(player, info) when a player does `event` (BR.EVENTS lists them):
--- join, leave, chat, typing, death, damage, emote, emote_end, interact,
--- interact_end, shoot, projectile_hit, melee_hit, avatar, place, delete, change. `player` is their PlayerState
--- (nil for bots); `info` holds the event's details (docs/lua-api.md). Handlers
--- run on the game thread before the game handles the action, so a brick being
--- deleted can still be read. Returns a function that stops it.
function M.on(event, fn)
    local sources = EVENTS[event]
    if not sources then error("no event " .. tostring(event) .. " (see BR.EVENTS)", 2) end
    if not handlers[event] then
        handlers[event] = {}
        for _, source in ipairs(sources) do
            local path, decode = source[1], source[2]
            M.on_call(path, function(self, params)
                local list = handlers[event]
                if #list == 0 then return end
                local player, info = decode(self, params)
                for i = #list, 1, -1 do
                    local ok, err = pcall(list[i], player, info)
                    if not ok then print("[BR.on " .. event .. "] " .. tostring(err) .. "\n") end
                end
            end)
        end
    end
    table.insert(handlers[event], fn)
    return function()
        for i, f in ipairs(handlers[event]) do if f == fn then table.remove(handlers[event], i) break end end
    end
end

-- Exec triggers: firing exec gates (Send Custom Event, Broadcast Chat Message,
-- any exec input) from Lua. Lua can only set component inputs, so a Change
-- Detector gate does the firing: every new value set on its input fires its
-- OnChanged exec output on the next tick.

local DETECTOR = "B_1x1_Gate_Expr_ChangeDetectorExec"

--- Place a trigger gate at grid position (x, y, z) and return
--- { brick, connect(target, type, port), fire() }. A wire made in the same
--- tick as a fire is not live yet, so connect, then fire from a later call.
function M.trigger(x, y, z)
    local ps = M.player()
    local brick = assert(M.place(M.builder({ asset = DETECTOR, owner = M.owner_index() }), x, y, z), "the trigger could not be placed")
    local det = M.component_type("ChangeDetectorExec"):GetFName():ToString()
    -- a reload starts a fresh counter while the gate keeps its old value, and an
    -- equal value would not fire
    local n = os.time() % 1000000 * 1000
    local t = { brick = brick }
    function t.connect(target, type, port)
        return M.changes(M.transaction(ps, function(tx)
            tx.connect(M.brick_id(brick), M.output_port(det, "OnChanged"), M.brick_id(target), M.input_port(type, port))
        end))
    end
    function t.fire()
        n = n + 1
        return M.set_input(brick, det, "Input", M.wire_int(n))
    end
    -- the detector's first value only sets its baseline, so spend it here
    t.fire()
    return t
end

-- Traces. Channels are EBRLuauTraceChannel (what the ray collides as) and targets
-- EBRLuauTraceTargets bits (what it may hit).

M.TRACE_CHANNEL = {
    Brick = 1, BrickComponent = 2, BrickInteractive = 3, BrickJoint = 4, BrickTouch = 5, Interaction = 6,
    Player1 = 7, Player2 = 8, Player3 = 9, Player4 = 10, Projectile = 11, RadialDamage = 12, Tool = 13,
    Visibility = 14, Weather = 15,
}
M.TRACE_TARGETS = {
    Brick = 1, PhysicsBody = 2, Pickup = 4, Player1 = 8, Player2 = 16, Player3 = 32, Player4 = 64,
    Projectile = 128, Water = 256, WorldDynamic = 512, WorldStatic = 1024, All = 2047,
}

-- BRLuauTraceHit: Entity (UObject*) +0, Brick (BrickHandle) +8, Position +0x10,
-- Normal +0x28 (FVector, doubles), Distance +0x40
local function trace_hit(bytes)
    local entity = M.obj(bytes:sub(1, 8))
    local brick = bytes:sub(9, 16)
    local px, py, pz = string.unpack("<ddd", bytes, 0x10 + 1)
    local nx, ny, nz = string.unpack("<ddd", bytes, 0x28 + 1)
    return {
        position = { px, py, pz },
        normal = { nx, ny, nz },
        distance = (string.unpack("<d", bytes, 0x40 + 1)),
        brick = M.brick_valid(brick) and brick or nil,
        entity = entity and entity:IsValid() and entity or nil,
    }
end

local function trace_opts(opts)
    opts = opts or {}
    local channel = opts.channel or "Visibility"
    local targets = opts.targets or "All"
    if type(channel) == "string" then channel = assert(M.TRACE_CHANNEL[channel], "no trace channel " .. channel) end
    if type(targets) == "string" then targets = assert(M.TRACE_TARGETS[targets], "no trace targets " .. targets) end
    return channel, targets, opts.distance or 100000, opts.complex and "\1" or "\0"
end

--- Cast a ray from `origin` along `direction` ({x, y, z}, world units; the
--- direction need not be normalised). opts: distance (default 100000), channel
--- and targets (names from BR.TRACE_CHANNEL / BR.TRACE_TARGETS or numbers;
--- default Visibility / All), complex. Returns nil for no hit, or { position,
--- normal, distance, brick = handle or nil, entity = actor or nil }.
function M.raycast(origin, direction, opts)
    local channel, targets, distance, complex = trace_opts(opts)
    local r = M.call(cdo("BRLuauWorldLibrary"), "BRLuauWorldLibrary", "Raycast", {
        Origin = string.pack("<ddd", origin[1], origin[2], origin[3]),
        Direction = string.pack("<ddd", direction[1], direction[2], direction[3]),
        WorldContextObject = M.ptr(M.world_context()),
        MaxDistance = string.pack("<d", distance),
        Channel = string.pack("B", channel),
        Targets = string.pack("<I4", targets),
        bComplex = complex,
    })
    if not M.bool(r.ReturnValue) then return nil end
    return trace_hit(r.OutHit)
end

--- Like BR.raycast with a sphere of `radius` swept along the ray.
function M.sweep(origin, direction, radius, opts)
    local channel, targets, distance, complex = trace_opts(opts)
    local r = M.call(cdo("BRLuauWorldLibrary"), "BRLuauWorldLibrary", "Sweep", {
        Origin = string.pack("<ddd", origin[1], origin[2], origin[3]),
        Direction = string.pack("<ddd", direction[1], direction[2], direction[3]),
        Radius = string.pack("<d", radius),
        WorldContextObject = M.ptr(M.world_context()),
        MaxDistance = string.pack("<d", distance),
        Channel = string.pack("B", channel),
        Targets = string.pack("<I4", targets),
        bComplex = complex,
    })
    if not M.bool(r.ReturnValue) then return nil end
    return trace_hit(r.OutHit)
end

return M

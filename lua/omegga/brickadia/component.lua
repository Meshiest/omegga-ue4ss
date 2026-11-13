-- BR.component: Brick components (gates and the rest): types, ports, inputs and data.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local cdo, valid, wirestring, each_field, find_field, read_wirestring, read_wirevalue = I.cdo, I.valid, I.wirestring, I.each_field, I.find_field, I.read_wirestring, I.read_wirevalue
local component = {}

function component.port_name(port)
    return BR.raw.fstring(BR.raw.call(cdo("BRLuauComponentLibrary"), "BRLuauComponentLibrary", "GetPortName", { Self = port }).ReturnValue)
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
        names[#names + 1] = BR.raw.fstring(BR.raw.call(KS, "Engine.KismetStringLibrary", "Conv_NameToString", { InName = key }).ReturnValue)
    end
    return names
end

--- Port names of a component type (e.g. "BrickComponentType_Expr_LogicalAND"):
--- the FNames that port refs use, which are the property names (`bInputA`).
--- Every registered component type object (native ones are named like their
--- class, `BrickComponentType_Expr_LogicalAND`; Blueprint ones after theirs).
function component.types()
    local bcs = StaticFindObject("/Script/Brickadia.Default__BCSLibrary")
    local r = BR.raw.call(bcs, "BCSLibrary", "GetAllRegisteredComponentTypes", { WorldContextObject = BR.raw.ptr(BR.world.context()) })
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
function component.type(name)
    local t = StaticFindObject("/Engine/Transient." .. name)
    if t and t:IsValid() then return t end
    for _, c in ipairs(BR.component.types()) do
        if c:GetFName():ToString():find(name, 1, true) then return c end
    end
    error("no component type " .. name)
end

function component.ports(type)
    local t = BR.component.type(type)
    return {
        inputs = port_names(t, 0x180, "BCSWireInputDescriptor"),
        outputs = port_names(t, 0x190, "BCSWirePortDescriptor"),
    }
end

--- A BRLuauPortRef for input `port` (its property FName, e.g. "bInputA") of the
--- component type `type` (e.g. "BrickComponentType_Expr_LogicalAND"). The ref
--- covers that one type: {name, FirstTypeIndex = the type's u16 index at +0x40, TypeCount = 1}.
function component.input_port(type, port)
    local t = BR.component.type(type)
    local index = string.unpack("<I2", __peek(__addr(t) + 0x40, 2))
    return string.pack("<I4I2I2", __fname(port) & 0x7FFFFFFF, index, 1)
end

--- A BRLuauPortRef for output `port` of component type `type` (bit 31 set).
function component.output_port(type, port)
    local ref = BR.component.input_port(type, port)
    local name, first, count = string.unpack("<I4I2I2", ref)
    return string.pack("<I4I2I2", name | 0x80000000, first, count)
end

--- Set a component input on a brick (BrickHandle bytes) through a transaction.
--- Returns the TransactionReport counters.
function component.set_input(handle, type, port, value)
    local id = BR.brick.id(handle)
    return BR.brick.transaction(BR.player.server(), function(tx) tx.set(id, BR.component.input_port(type, port), value) end)
end

--- Whether a component input currently holds `value`, read through the
--- transaction report: setting an input to the value it already has is skipped
--- (ComponentsSkipped 1), any other value is applied (ComponentsChanged 1). So a
--- false answer has also just set the input to `value`. Any other report (an
--- untrusted brick, a missing component) says nothing about the value and is an
--- error.
function component.input_is(handle, type, port, value)
    local report = BR.component.set_input(handle, type, port, value)
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
        return BR.raw.call(cdo("BRPropertyValueLibrary"), "BRPropertyValueLibrary", "PropertyValue_MakeObject", { Value = BR.raw.ptr(v) }).ReturnValue:sub(1, 16)
    end },
}

local function token(tag, payload)
    payload = payload or ""
    return payload .. string.rep("\0", 0x18 - #payload) .. string.pack("B", tag) .. string.rep("\0", 7)
end

--- The UScriptStruct holding a component type's data (each type object points
--- at it at +0x38).
function component.struct(ctype)
    local t = type(ctype) == "string" and BR.component.type(ctype) or ctype
    local st = __obj(string.unpack("<I8", __peek(__addr(t) + 0x38, 8)))
    assert(st and st:IsValid(), "no data struct for this component type")
    return st
end

local function field_kind(prop)
    local cls = prop:GetClass():GetFName():ToString()
    if cls == "StructProperty" then return "Struct<" .. prop:GetStruct():GetFName():ToString() .. ">", prop:GetStruct() end
    return cls
end

--- A component type's fields, inherited ones included: { { name, type } }, `type`
--- being the property class (`FloatProperty`, `Struct<WireString>`, ...). Writable
--- leaf types are listed in docs/lua-api.md.
function component.fields(ctype)
    local out = {}
    each_field(BR.component.struct(ctype), function(prop)
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
            if not leaf then error(string.format("%s is a %s, which BR.component.set can't write", path, kind), 3) end
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
--- trust check (like BR.brick.place).
function component.set(handle, ctype, values)
    local t = type(ctype) == "string" and BR.component.type(ctype) or ctype
    local struct = BR.component.struct(t)
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
    if not BR.brick.valid(handle) then error("invalid brick handle", 2) end
    local data = table.concat(tokens)
    local addr = __alloc(data)
    BR.raw.call(cdo("BCSLibrary"), "BCSLibrary", "ApplyChangelist", {
        WorldContextObject = BR.raw.ptr(BR.world.context()),
        BrickHandle = handle,
        ComponentType = BR.raw.ptr(t),
        Changelist = string.pack("<I8i4i4", addr, #tokens, #tokens),
    })
    __free(addr)
end

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

--- A brick's component of type `ctype` as its 8-byte BCSComponentHandle (the
--- component's own id, which wires and the Connector address), or nil if the
--- brick has no such component.
function component.handle(handle, ctype)
    if not BR.brick.valid(handle) then error("invalid brick handle", 2) end
    local t = type(ctype) == "string" and BR.component.type(ctype) or ctype
    local r = BR.raw.call(cdo("BRLuauComponentLibrary"), "BRLuauComponentLibrary", "Get", { Self = BR.raw.ptr(t), Brick = handle })
    if not BR.raw.bool(r.ReturnValue) then return nil end
    return r.OutComponent
end

--- The address of a brick's component data, or nil if the brick has no such
--- component.
function component.address(handle, ctype)
    if not BR.brick.valid(handle) then error("invalid brick handle", 2) end
    local c = BR.component.handle(handle, ctype)
    return c and __component_data(c)
end

--- One field of a brick's component ("GunSkill", "MoveTarget.X"): booleans,
--- numbers, strings (WireString), wire values and structs (as tables). Fields of
--- other types (object references, arrays) read as nil.
function component.get(handle, ctype, path)
    local t = type(ctype) == "string" and BR.component.type(ctype) or ctype
    local addr = BR.component.address(handle, t)
    if not addr then return nil end
    local struct = BR.component.struct(t)
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
function component.data(handle, ctype)
    local t = type(ctype) == "string" and BR.component.type(ctype) or ctype
    local addr = BR.component.address(handle, t)
    if not addr then return nil end
    local out = {}
    BR.component.struct(t):ForEachProperty(function(prop)
        local name = prop:GetFName():ToString()
        if not name:find("^Dispatch_") then out[name] = read_field(addr, prop, 0) end
    end)
    return out
end

return component

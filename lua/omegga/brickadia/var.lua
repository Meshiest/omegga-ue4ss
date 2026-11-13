-- BR.var: Variable, array and map gates: reading, writing and watching them.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local wirestring, find_field, read_wirestring, read_wirevalue, VAR = I.wirestring, I.find_field, I.read_wirestring, I.read_wirevalue, I.VAR
local var = {}

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
    local t = BR.component.type(ctype)
    local addr = BR.component.address(handle, t)
    if not addr then error("the brick has no " .. ctype, 3) end
    local struct = BR.component.struct(t)
    return addr, addr + find_field(struct, "Value"):GetOffset_Internal(), addr + find_field(struct, "MutationVersion"):GetOffset_Internal()
end

local function bump(version_addr)
    __poke(version_addr, string.pack("<I8", string.unpack("<I8", __peek(version_addr, 8)) + 1))
end

--- An Array Variable gate's elements as a Lua list, and the element type's name
--- (BRReflectionPropertyInfo_Int64 / _Double / _WireString).
function var.read_array(handle)
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
function var.write_array(handle, values)
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
function var.read_map(handle)
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
function var.set_map_value(handle, key, v)
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
        list = BR.brick.in_grid(target)
    end
    local out = {}
    for _, h in ipairs(list) do
        if BR.brick.valid(h) and BR.component.address(h, ctype) then out[#out + 1] = h end
    end
    return out
end

local function watch(target, ctype, field, size, decode, fn)
    local t = BR.component.type(ctype)
    local offset = find_field(BR.component.struct(t), field):GetOffset_Internal()
    local gates = {}
    for _, h in ipairs(watch_targets(target, ctype)) do
        local addr = BR.component.address(h, t)
        gates[#gates + 1] = { handle = h, addr = addr, last = __peek(addr + offset, size), value = decode(h, addr + offset) }
    end
    local stop
    stop = BR.event.tick(function()
        for i = #gates, 1, -1 do
            local g = gates[i]
            -- a deleted gate's storage slot can be reused by another component
            if not BR.brick.valid(g.handle) or BR.component.address(g.handle, t) ~= g.addr then
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
function var.on_change(target, fn)
    return watch(target, VAR, "Value", WIRE_VALUE_SIZE, function(_, at) return read_wirevalue(at) end, fn)
end

--- Like BR.var.on_change for Array Variable gates: fn(elements, handle) after
--- each change (pushes, sets, BR.var.write_array).
function var.on_array_change(target, fn)
    return watch(target, ARRAY_VAR, "MutationVersion", 8, function(h) return (BR.var.read_array(h)) end, fn)
end

--- Like BR.var.on_change for Map Variable gates: fn(entries, handle), entries as
--- BR.var.read_map gives them.
function var.on_map_change(target, fn)
    return watch(target, MAP_VAR, "MutationVersion", 8, function(h) return (BR.var.read_map(h)) end, fn)
end

return var

-- BR.raw: Byte packing and raw UFunction calls: the layer under every other namespace.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local SCRIPT, layout = I.SCRIPT, I.layout
local raw = {}

--- Call `Class:Function` on `target` with raw param bytes keyed by param name.
--- `class` is a Brickadia class name, or "Package.Class" for another script
--- package ("Engine.KismetStringLibrary"). Returns a table whose fields are the
--- raw bytes of each param after the call.
function raw.call(target, class, fn, args)
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

function raw.ptr(obj) return string.pack("<I8", obj and __addr(obj) or 0) end

function raw.obj(bytes)
    local a = string.unpack("<I8", bytes)
    return a ~= 0 and __obj(a) or nil
end

function raw.bool(bytes) return string.byte(bytes, 1) ~= 0 end

function raw.i32(bytes) return (string.unpack("<i4", bytes)) end

function raw.ivec(x, y, z) return string.pack("<i4i4i4", x, y, z) end

--- Decode FString bytes {TCHAR* Data, int32 Num, int32 Max} from a param buffer.
--- Num counts the terminator. Comes back as UTF-8.
function raw.fstring(bytes)
    local data, num = string.unpack("<I8i4", bytes)
    if data == 0 or num <= 1 then return "" end
    -- TCHAR is UTF-16 here; a surrogate pair is one character, and a lone
    -- surrogate (malformed text) becomes U+FFFD
    local units = __peek(data, (num - 1) * 2)
    local chars, i = {}, 1
    while i <= #units do
        local unit = string.unpack("<I2", units, i)
        i = i + 2
        if unit >= 0xD800 and unit <= 0xDBFF and i <= #units then
            local low = string.unpack("<I2", units, i)
            if low >= 0xDC00 and low <= 0xDFFF then
                unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                i = i + 2
            else
                unit = 0xFFFD
            end
        elseif unit >= 0xD800 and unit <= 0xDFFF then
            unit = 0xFFFD
        end
        chars[#chars + 1] = utf8.char(unit)
    end
    return table.concat(chars)
end

--- The 8-byte BrickHandles in a returned TArray (its 16 bytes from a parameter
--- buffer), freeing the array's buffer: the buffer is a copy nothing else
--- frees, so it would otherwise leak on every call.
function raw.take_handles(array)
    local data, num = string.unpack("<I8i4", array)
    local out = {}
    for i = 0, num - 1 do out[i + 1] = __peek(data + i * 8, 8) end
    if data ~= 0 then __game_free(data) end
    return out
end

--- A new FString's 16 bytes `{ data, num, max }` holding `text` (UTF-8), for a
--- parameter the engine takes over: its buffer comes from the game's heap, so
--- the engine frees it with the parameters. Invalid UTF-8 is an error.
function raw.new_fstring(text)
    local units = {}
    for _, code in utf8.codes(text) do
        if code >= 0x10000 then
            code = code - 0x10000
            units[#units + 1] = string.pack("<I2I2", 0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF))
        else
            units[#units + 1] = string.pack("<I2", code)
        end
    end
    local body = table.concat(units) .. "\0\0"
    local num = #body // 2
    return string.pack("<I8i4i4", __game_alloc(body), num, num)
end

--- An FText's bytes (borrowed, 0x10) as a Lua string.
function raw.ftext(bytes)
    local KT = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    return BR.raw.fstring(BR.raw.call(KT, "Engine.KismetTextLibrary", "Conv_TextToString", { InText = bytes }).ReturnValue)
end

return raw

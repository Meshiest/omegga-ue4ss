-- Shared helpers for the omegga.brickadia namespaces. `I.BR` is the root table
-- every namespace hangs off; they call each other through it, so the
-- namespaces can be loaded in any order.
local I = { BR = {} }
local BR = I.BR

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

-- Calling a method on an invalid UObject (FindFirstOf found nothing, the world
-- isn't loaded yet) dereferences null inside UE4SS and kills the server; pcall
-- can't catch it. Everything below checks IsValid() first and raises a Lua error.
local function valid(obj, what)
    if not obj or not obj:IsValid() then error(what .. " is not available (is the world loaded? see BR.world.ready())", 3) end
    return obj
end

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
        local sample = BR.raw.call(cdo("BRLuauAssetLibrary"), "BRLuauAssetLibrary", "GetAssetName", { Self = BR.raw.ptr(BR.brick.asset("PB_DefaultBrick")) }).ReturnValue
        local _, controller = string.unpack("<I8I8", sample)
        wirestring_vtable = string.unpack("<I8", __peek(controller, 8))
    end
    local data = __game_alloc(text .. "\0")
    local block = __game_alloc(string.pack("<I8I8I8i4i4I4I4", wirestring_vtable, 0x100000001, data, #text + 1, #text + 1, 0, 0))
    return string.pack("<I8I8", block + 0x10, block)
end

-- Players and teams. A PlayerState (`ps`) is the handle for a player; its
-- character and controller come from it.

local function str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    return v:ToString()
end

local function player_lib(fn, obj)
    return BR.raw.call(cdo("BRLuauPlayerLibrary"), "BRLuauPlayerLibrary", fn, { Self = BR.raw.ptr(obj) }).ReturnValue
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

-- WireValue: payload at +0, EWireKind at +0x20. A string's payload only points
-- at its text, so strings are read separately.
local WIRE_SIZE = 0x28
local WIRE_KIND_STRING = 7
local WIRE_DECODERS = {
    [0] = function(b) return string.byte(b, 1) ~= 0 end,
    [1] = function(b) return (string.unpack("<i8", b)) end,
    [2] = function(b) return (string.unpack("<d", b)) end,
    [4] = function(b) return { string.unpack("<ddd", b) } end,
    [13] = function(b) return (string.unpack("<f", b)) end,
    [14] = function(b) return (string.unpack("<i1", b)) end,
    [15] = function(b) return (string.unpack("<i2", b)) end,
    [16] = function(b) return (string.unpack("<i4", b)) end,
    [17] = function(b) return (string.unpack("<I1", b)) end,
    [18] = function(b) return (string.unpack("<I2", b)) end,
    [19] = function(b) return (string.unpack("<I4", b)) end,
    [20] = function(b) return (string.unpack("<I8", b)) end,
}

--- A WireValue's 0x28 bytes as a Lua value (see read_wirevalue); `text` is a
--- string value's text, which the bytes only point at.
local function decode_wirevalue(bytes, text)
    local kind = string.byte(bytes, 0x21)
    if kind == 29 or kind == 12 then return nil end
    if kind == WIRE_KIND_STRING then return text or "" end
    local decode = WIRE_DECODERS[kind]
    if decode then return decode(bytes) end
    return { kind = kind }
end

--- A WireValue at `addr` as a Lua value: booleans, numbers, strings and vectors
--- ({x, y, z}); nil for none and exec; { kind = n } for kinds not decoded yet.
local function read_wirevalue(addr)
    local bytes = __peek(addr, WIRE_SIZE)
    if string.byte(bytes, 0x21) == WIRE_KIND_STRING then return read_wirestring(addr) end
    return decode_wirevalue(bytes)
end

local VAR = "BrickComponentType_Var"

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
I.REPORT_COUNTERS_SIZE = #REPORT_FIELDS * 4

--- A BrickTransactionReport's bytes as { <counter> = n, lines = { text } }.
function I.decode_report(bytes)
    local counts = { string.unpack("<" .. string.rep("i4", #REPORT_FIELDS), bytes) }
    local report = {}
    for i, n in ipairs(REPORT_FIELDS) do report[n] = counts[i] end
    -- refusals that have no counter (admin gates, for one) only show up here
    local data, num = string.unpack("<I8i4", bytes, I.REPORT_COUNTERS_SIZE + 1)
    local lines = {}
    for i = 0, num - 1 do lines[#lines + 1] = BR.raw.ftext(__peek(data + i * 0x10, 0x10)) end
    report.lines = lines
    return report
end

local singles = {}
--- The world's one object of `class` (game mode, game state, global grid, ...),
--- or nil. FindFirstOf walks every object in the game (about 4 ms), so the
--- object is kept and found again only once it is gone (a map change).
function I.single(class)
    local o = singles[class]
    if o and o:IsValid() then return o end
    o = FindFirstOf(class)
    if o and o:IsValid() then
        singles[class] = o
        return o
    end
end

local offsets = {}
--- The offset of reflected property `name` in `obj`'s class or a super class.
function I.offset(obj, name)
    local cls = obj:GetClass()
    local key = cls:GetFullName() .. ":" .. name
    if offsets[key] then return offsets[key] end
    while cls and cls:IsValid() do
        local found
        cls:ForEachProperty(function(p)
            if p:GetFName():ToString() == name then found = p:GetOffset_Internal(); return true end
        end)
        if found then
            offsets[key] = found
            return found
        end
        cls = cls:GetSuperStruct()
    end
    error("no property " .. name .. " on " .. obj:GetClass():GetFullName(), 2)
end

--- The game state, or a Lua error saying the world isn't loaded yet: a mod's
--- main.lua runs before the world exists.
function I.game_state()
    return valid(I.single("BRGameStateBase"), "the game state")
end

--- Report an error a BR module caught from a mod's callback (an event handler,
--- a timer, a command). The marker is what the omegga plugin looks for in
--- UE4SS.log to repeat the error in omegga's own log, so a broken mod is seen
--- without reading UE4SS.log. `where` names the API the callback came from.
-- Whether `o` is a live object: valid to UE4SS and not yet destroyed. A
-- destroyed object (an actor torn down, everything of the old world after a
-- world load) is flagged garbage at once (RF_MirroredGarbage in its
-- ObjectFlags), but IsValid stays true until the garbage collector runs; asking
-- such an object for another (a PlayerState for its character) hands back a
-- pointer that crashes the server when wrapped.
local GARBAGE, FLAGS_AT = 0x40000000, 8
function I.alive(o)
    if o == nil or type(o) ~= "userdata" or not o:IsValid() then return false end
    local flags = string.unpack("<I4", __peek(__addr(o) + FLAGS_AT, 4))
    return (flags & GARBAGE) == 0
end

function I.report(where, err)
    print("[BR error] " .. where .. ": " .. tostring(err) .. "\n")
end

-- BR.profile's records, shared by every copy of the modules (hooks installed
-- by an older load still count)
_G.BR_PROFILE = _G.BR_PROFILE or { on = false, stats = {} }
local P = _G.BR_PROFILE
local sources = setmetatable({}, { __mode = "k" })
local function source_of(fn)
    local s = sources[fn]
    if not s then
        local info = debug.getinfo(fn, "S")
        s = (info.short_src or "?") .. ":" .. tostring(info.linedefined or 0)
        sources[fn] = s
    end
    return s
end

--- pcall(fn, ...), timed under `kind` and fn's source when BR.profile is on.
--- Every callback BR runs for a mod (events, ticks, timers, hooks, commands)
--- goes through here.
function I.call(kind, fn, ...)
    if not P.on then return pcall(fn, ...) end
    local t = __clock()
    local r = table.pack(pcall(fn, ...))
    local dt = __clock() - t
    local key = kind .. " " .. source_of(fn)
    local st = P.stats[key]
    if not st then
        st = { kind = kind, source = source_of(fn), calls = 0, total = 0, max = 0 }
        P.stats[key] = st
    end
    st.calls = st.calls + 1
    st.total = st.total + dt
    if dt > st.max then st.max = dt end
    return table.unpack(r, 1, r.n)
end

I.SCRIPT = SCRIPT
I.cdo = cdo
I.layout = layout
I.valid = valid
I.wirestring = wirestring
I.str = str
I.player_lib = player_lib
I.each_field = each_field
I.find_field = find_field
I.read_wirestring = read_wirestring
I.read_wirevalue = read_wirevalue
I.decode_wirevalue = decode_wirevalue
I.WIRE_SIZE = WIRE_SIZE
I.WIRE_KIND_STRING = WIRE_KIND_STRING
I.VAR = VAR

-- The inventory calls (ServerSetInventorySlot, ServerClearInventorySlot, ...)
-- act on the controller's pawn and do nothing without one. A bot's character
-- is driven by an AI controller, so its player controller has no pawn: it is
-- pointed at the character for the length of fn(pc).
function I.as_controller(ps, fn)
    local BR = I.BR
    local pc = assert(BR.player.controller(ps), "no controller")
    local ch = BR.player.character(ps)
    assert(ch and ch:IsValid(), "they have no character")
    local pawn = pc.Pawn
    local borrowed = not (pawn and pawn:IsValid())
    if borrowed then pc.Pawn = ch end
    local ok, err = pcall(fn, pc)
    if borrowed then pc.Pawn = nil end
    if not ok then error(err, 0) end
end

return I

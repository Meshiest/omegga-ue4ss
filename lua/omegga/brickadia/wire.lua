-- BR.wire: Wire values: the tagged 0x28-byte values gates pass around.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local wirestring, read_wirevalue = I.wirestring, I.read_wirevalue
local wire = {}

-- WireValue: 0x20 bytes of payload, then an EWireKind tag byte at +0x20
local WIRE_SIZE_PAYLOAD = 0x20

local function wire_value(kind, payload)
    return payload .. string.rep("\0", WIRE_SIZE_PAYLOAD - #payload) .. string.pack("B", kind)
end

function wire.bool(v) return wire_value(0, string.pack("B", v and 1 or 0)) end

function wire.int(v) return wire_value(1, string.pack("<i8", v)) end

function wire.double(v) return wire_value(2, string.pack("<d", v)) end

wire.wirestring = wirestring

--- A String wire value (UTF-8 text), for string inputs: chat messages, bot names,
--- string gates, custom event data.
function wire.string(text) return wire_value(7, wirestring(text)) end

wire.read = read_wirevalue

return wire

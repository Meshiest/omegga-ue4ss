-- Example UE4SS mod shipped by an omegga plugin (loaded from the plugin's mods/).
-- Uses the shared libraries the ue4ss plugin installs.
local Omegga = require("omegga")
local BR = require("omegga.brickadia")

local AND, CHANGER = "BrickComponentType_Expr_LogicalAND", "Component_BrickPropertyChanger"
local lamp -- { gate = BrickHandle bytes, signal = BrickHandle bytes }

-- handlers can run before the map has loaded; anything touching the world
-- should wait until this is true
Omegga.handle("ready", function() return BR.ready() end)

-- JS -> Lua: emitPlugin('call', 'greet', 'world')
Omegga.handle("greet", function(who)
    return "hello " .. tostring(who) .. " from mod " .. Omegga.id
end)

-- Lua -> JS -> Lua: ask the demo plugin to add, then report the answer as an event
Omegga.handle("add_via_js", function(a, b)
    Omegga.call("ue4ss-interop-demo", "add", { a, b }, function(ok, sum)
        Omegga.emit("sum", { ok = ok, sum = sum })
    end)
    return "asked"
end)

-- React to a component change: an AND gate wired into a property changer on a
-- second brick; the brick's visibility follows the gate's output, and a watch
-- turns that into `watch` events for omegga
Omegga.handle("build_lamp", function(x, y)
    assert(BR.ready(), "the world is not loaded yet")
    local ps, owner = BR.player(), BR.owner_index()
    local gate = assert(BR.place(BR.builder({ asset = "B_1x1_Gate_Expr_LogicalAND", owner = owner }), x, y, 6))
    local signal = assert(BR.place(BR.builder({ asset = "PB_DefaultBrick", size = { 5, 5, 6 }, owner = owner }), x + 40, y, 6))
    local report = BR.transaction(ps, function(tx)
        tx.attach(BR.brick_id(signal), BR.component_type(CHANGER))
        tx.connect(BR.brick_id(gate), BR.output_port(AND, "bOutput"), BR.brick_id(signal), BR.input_port(CHANGER, "bVisibility"))
    end)
    lamp = { gate = gate, signal = signal }
    Omegga.watch("lamp", 50, function() return BR.is_visible(signal) end)
    return BR.changes(report)
end)

Omegga.handle("set_lamp", function(a, b)
    return BR.changes(BR.transaction(BR.player(), function(tx)
        tx.set(BR.brick_id(lamp.gate), BR.input_port(AND, "bInputA"), BR.wire_bool(a))
        tx.set(BR.brick_id(lamp.gate), BR.input_port(AND, "bInputB"), BR.wire_bool(b))
    end))
end)

Omegga.emit("hello", { mod = Omegga.id })

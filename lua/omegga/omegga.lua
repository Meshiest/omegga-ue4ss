-- Interop between UE4SS Lua mods and omegga plugins, through the ue4ss plugin.
-- Installed to <omegga data>/Mods/shared/omegga/, so any mod can use it:
--
--   local Omegga = require("omegga")
--   Omegga.emit("door", { open = true })        -- plugins get ue4ss:door
--   Omegga.call("my-plugin", "add", { 2, 3 }, function(ok, sum) print(sum) end)
--   Omegga.handle("greet", function(who) return "hi " .. who end)
--   Omegga.watch("lamp", 100, function() return some_value() end)
--
-- Transport: the BrickadiaBridge C++ mod's socket, one JSON message per line
-- (docs/interop.md). Messages for this mod arrive through __bridge_listen on
-- the game thread at the start of the next engine tick; __bridge_send queues a
-- line for the plugin (connection 0 = every connected client).
--
-- Every mod that requires this module is a separate Lua state with its own
-- id and handlers; the plugin routes each call to the mod that registered the
-- handler.
local json = require("omegga.json")

local M = {}

assert(__bridge_listen, "the BrickadiaBridge C++ mod is not loaded")

math.randomseed(os.time() + math.floor((os.clock() % 1) * 1e6))
M.id = string.format("%08x", math.random(0, 0x7fffffff))

--- A JSON-safe copy of `v`: UObjects become their full name, other userdata a
--- string, and tables are copied to a bounded depth.
function M.plain(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "userdata" then
        local ok, name = pcall(function() return v:GetFullName() end)
        if ok then return name end
        local ok2, s = pcall(function() return v:ToString() end)
        if ok2 then return s end
        return tostring(v)
    elseif t == "table" and depth < 6 then
        local out = {}
        for k, x in pairs(v) do out[k] = M.plain(x, depth + 1) end
        return out
    elseif t == "function" or t == "thread" then
        return tostring(v)
    end
    return v
end

local function send(conn, message)
    message.mod = M.id
    __bridge_send(conn, json.encode(M.plain(message)))
end

--- Send `event` with `data` to omegga. Plugins receive it as an omegga event
--- `ue4ss:<event>` and, when subscribed, as pluginEvent('ue4ss:<event>', from, data).
function M.emit(event, data)
    send(0, { t = "event", event = event, data = data })
end

local pending = {}
local calls = 0
--- Call omegga plugin `plugin`'s pluginEvent(event, ...args). callback(ok,
--- resultOrError) runs later, on the game thread. Returns the call id.
function M.call(plugin, event, args, callback)
    calls = calls + 1
    local id = string.format("%s-%d", M.id, calls)
    pending[id] = callback or false
    send(0, { t = "call", id = id, plugin = plugin, event = event, args = args or {} })
    return id
end

local handlers = {}
--- Make fn callable from plugins: emitPlugin('call', name, ...args) returns
--- { ok = true, result = fn(...args) } (or { ok = false, error = ... }). fn runs on
--- the game thread. A later handle() with the same name, from any mod, wins.
function M.handle(name, fn)
    handlers[name] = fn
    send(0, { t = "register", name = name })
end

local watches = {}
--- Poll getter() on the game thread every interval_ms and emit `watch`
--- { name, value, previous } when the value changes (compared with ~=, so
--- return a string or number, not a table). The first reading is the baseline
--- and isn't emitted.
function M.watch(name, interval_ms, getter)
    local watch = { getter = getter, armed = false }
    watches[name] = watch
    LoopAsync(interval_ms, function()
        if watches[name] ~= watch then return true end
        ExecuteInGameThread(function()
            if watches[name] ~= watch then return end
            local ok, value = pcall(watch.getter)
            if not ok then return end
            if watch.armed and value ~= watch.value then
                M.emit("watch", { name = name, value = value, previous = watch.value })
            end
            watch.value, watch.armed = value, true
        end)
        return false
    end)
end

function M.unwatch(name)
    watches[name] = nil
end

local function on_message(conn, text)
    local ok, message = pcall(json.decode, text)
    if not ok or type(message) ~= "table" then return end
    if message.t == "connected" then
        -- a plugin that (re)connects learns which handlers live here
        for name in pairs(handlers) do send(conn, { t = "register", name = name }) end
    elseif message.t == "reply" then
        local callback = pending[message.id]
        pending[message.id] = nil
        if callback then
            if message.ok then callback(true, message.result) else callback(false, message.error) end
        end
    elseif message.t == "call" then
        local result
        local fn = handlers[message.name]
        if not fn then
            result = { ok = false, error = "no Lua handler named " .. tostring(message.name) }
        else
            local values = table.pack(pcall(fn, table.unpack(message.args or {})))
            if values[1] then result = { ok = true, result = values[2] }
            else result = { ok = false, error = tostring(values[2]) } end
        end
        result.t, result.id = "result", message.id
        send(conn, result)
    end
end

__bridge_listen(M.id, on_message)

return M

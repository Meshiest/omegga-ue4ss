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

--- Call a handler another Lua mod registered with Omegga.handle (or one in this
--- mod): callback(ok, result) runs later on the game thread, with what the
--- handler returned, or false and the error. Mods are separate Lua states, so
--- the call goes through the ue4ss plugin, which knows which mod has the
--- handler. Returns the call id.
---
---   Omegga.invoke("economy.balance", { player_id }, function(ok, coins) ... end)
function M.invoke(name, args, callback)
    local list = { name }
    for _, a in ipairs(args or {}) do list[#list + 1] = a end
    return M.call("ue4ss", "call", list, function(ok, reply)
        if not callback then return end
        if not ok then return callback(false, reply) end
        if type(reply) == "table" and reply.ok == false then return callback(false, reply.error) end
        callback(true, type(reply) == "table" and reply.result or reply)
    end)
end

local handlers = {}
--- Make fn callable from plugins: emitPlugin('call', name, ...args) returns
--- { ok = true, result = fn(...args) } (or { ok = false, error = ... }). fn runs on
--- the game thread. A later handle() with the same name, from any mod, wins.
function M.handle(name, fn)
    handlers[name] = fn
    send(0, { t = "register", name = name })
end

--- Serve HTTP: requests to /api/v1/plugin/ue4ss<path> on omegga's web server with
--- this method ("GET", "POST", ..., or "*" for any) call fn(request) on the
--- game thread. A path ending in "/*" also takes everything below it; of
--- several matching routes the longest path wins.
---
--- request: { method, path, query, headers, body, user, ip }; user is the web
--- UI user ({ id, username }) or nil. A route needs a web UI login unless
--- opts.public, when it must check for itself who may use it (a shared secret
--- in a header, say).
---
--- fn returns a string (the body, as text), a table with status, headers and
--- body (a table body goes out as JSON), any other table (a JSON body), or
--- nothing (204). An error answers 500. Like handle(), a later route with the
--- same method and path wins, from any mod.
---
---   Omegga.route("GET", "/players", function(req) return { count = #BR.player.list() } end)
function M.route(method, path, fn, opts)
    assert(type(method) == "string" and not method:find("%s"), "a route method is a word like GET")
    assert(type(path) == "string" and path:sub(1, 1) == "/" and not path:find("%s"), "a route path starts with / and has no spaces")
    M.handle(((opts and opts.public) and "http-public:" or "http:") .. method:upper() .. " " .. path, fn)
end

--- Answer an omegga event for a command a mod declares in its doc.json, like
--- an omegga plugin's:
---
--- "cmd:<name>" (doc.json `commands`) runs fn(player_name, ...words) on the
--- game thread when a player types /<name> in chat. BR.command.register wraps
--- it with the player's PlayerState, permissions and replies.
---
--- "consolecmd:<name>" (doc.json `consoleCommands`) runs fn(...args) when
--- someone types /<name> in omegga's console, and what fn returns (text, a
--- list of lines, or a table) is printed there.
---
---   Omegga.on("consolecmd:arena", function(action) return "arena " .. tostring(action) end)
function M.on(event, fn)
    local kind, name
    if type(event) == "string" then kind, name = event:match("^(%a+):([%w_%-]+)$") end
    assert((kind == "cmd" or kind == "consolecmd") and name, 'Omegga.on takes "cmd:<name>" or "consolecmd:<name>"')
    M.handle(kind .. ":" .. name:lower(), fn)
end

-- The mod this Lua state belongs to: the first script on the stack under
-- Mods/<name>/Scripts/ (or mods/, as the bridge's own lives; shared modules,
-- like this one, are elsewhere).
local function mod_name()
    for level = 2, 30 do
        local info = debug.getinfo(level, "S")
        if not info then break end
        local name = info.source and info.source:match("[/\\][Mm]ods[/\\]([^/\\]+)[/\\]Scripts[/\\]")
        if name and name ~= "shared" then return name end
    end
end
M.mod = mod_name()

-- Run Lua sent from omegga in this mod's state, as the bridge's exec does in
-- its own: an expression's value, or what a block returns.
local function exec(source)
    source = tostring(source)
    local chunk, err = load("return " .. source, "=exec")
    if not chunk then chunk, err = load(source, "=exec") end
    if not chunk then error("compile: " .. tostring(err), 0) end
    local results = table.pack(xpcall(chunk, debug.traceback))
    if not results[1] then error(tostring(results[2]), 0) end
    local values = {}
    for i = 2, results.n do values[#values + 1] = M.plain(results[i]) end
    if #values <= 1 then return values[1] end
    return values
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

local connect_listeners = {}
--- Run fn each time a plugin connects to the bridge (after omegga or the game
--- restarts). Keyed, so a module loaded again replaces its listener rather
--- than adding a second.
function M.on_connect(key, fn)
    connect_listeners[key] = fn
end

local function on_message(conn, text)
    local ok, message = pcall(json.decode, text)
    if not ok or type(message) ~= "table" then return end
    if message.t == "connected" then
        -- a plugin that (re)connects learns which handlers live here
        for name in pairs(handlers) do send(conn, { t = "register", name = name }) end
        for key, fn in pairs(connect_listeners) do
            local called, err = pcall(fn)
            if not called then print("[omegga] on_connect " .. key .. ": " .. tostring(err) .. "\n") end
        end
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

-- a REPL into this mod: the plugin's exec with a mod name lands here
if M.mod then M.handle("exec@" .. M.mod, exec) end

return M

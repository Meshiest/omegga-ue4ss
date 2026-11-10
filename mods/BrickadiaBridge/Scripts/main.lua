-- BrickadiaBridge: runs Lua snippets sent by omegga plugins (emitPlugin('exec', lua))
-- and returns the result as JSON. The C++ half of this mod owns the socket; a
-- line "BrickadiaBridge\t{"t":"exec","id":..,"lua":..}" reaches the listener
-- below on the game thread at the start of the next tick, and the answer goes
-- back to the same connection as {"t":"result","id":..,"ok":..,"result"|"error":..}.
--
-- Snippets see the shared libraries as globals: BR (omegga.brickadia) and
-- Omegga (omegga, the interop module; handlers registered here live in this mod).
local json = require("omegga.json")
BR = require("omegga.brickadia")
Omegga = require("omegga")

--- Re-read the shared libraries after editing them. UE4SS's module loader keeps
--- its own cache (ue4ss_loaded_modules) besides package.loaded; both are
--- cleared. Omegga is not reloaded: its handlers and pending calls live in it.
function BR_RELOAD()
    for key in pairs(ue4ss_loaded_modules) do
        if tostring(key):find("brickadia", 1, true) then ue4ss_loaded_modules[key] = nil end
    end
    package.loaded["omegga.brickadia"] = nil
    BR = require("omegga.brickadia")
    return BR
end

local function run(source)
    -- expression first, so `1 + 1` returns 2; then a statement block
    local chunk, err = load("return " .. source, "=bridge")
    if not chunk then chunk, err = load(source, "=bridge") end
    if not chunk then return { ok = false, error = "compile: " .. tostring(err) } end
    local results = table.pack(xpcall(chunk, debug.traceback))
    if not results[1] then return { ok = false, error = tostring(results[2]) } end
    local values = {}
    for i = 2, results.n do values[#values + 1] = Omegga.plain(results[i]) end
    return { ok = true, result = (#values <= 1) and values[1] or values }
end

__bridge_listen("BrickadiaBridge", function(conn, text)
    local ok, request = pcall(json.decode, text)
    if not ok or type(request) ~= "table" or request.t ~= "exec" then return end
    local ran, resp = pcall(run, tostring(request.lua))
    if not ran then resp = { ok = false, error = "bridge: " .. tostring(resp) } end
    resp.t, resp.id = "result", request.id
    local encoded_ok, encoded = pcall(json.encode, resp)
    if not encoded_ok then
        encoded = json.encode({ t = "result", id = request.id, ok = false, error = "encode: " .. tostring(encoded) })
    end
    __bridge_send(conn, encoded)
end)

print("[BrickadiaBridge] listening for exec\n")

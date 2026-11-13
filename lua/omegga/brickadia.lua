-- Brickadia helpers for UE4SS Lua on the Linux server.
--
-- Most of Brickadia's scripting UFunctions (BRLuau*Library) pass opaque structs
-- with no reflected fields (builder, brick handle, port ref, wire value), which
-- UE4SS's table marshalling drops. Those go through the native __raw_call: params
-- are packed into a byte buffer at the offsets reflection reports, and results
-- are read back out of the same buffer.
--
-- Each namespace is its own module under omegga/brickadia/.
local BR = require("omegga.brickadia.internal").BR

for _, ns in ipairs({
    "raw", "world", "server", "brick", "component", "wire", "var", "event", "player", "team",
    "leaderboard", "entity", "zone", "npc", "nav", "bot", "act", "voice", "store", "perm", "timer",
    "command", "mod", "enums", "ui", "behavior", "prefab", "sound", "chat", "effect", "state",
    "metrics", "pickup", "gen", "guard", "secrets", "db", "region", "target", "afk",
    "profile", "watch", "env", "config", "label", "mover", "math",
}) do
    BR[ns] = require("omegga.brickadia." .. ns)
end

return BR

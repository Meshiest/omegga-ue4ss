-- BR.command: Chat commands, as omegga delivers them. The game's own command
-- system handles a typed "/name args"; omegga sees it call one the game doesn't
-- have, and the ue4ss plugin hands the commands a mod declares in its doc.json
-- (`commands`, like an omegga plugin's) to Lua. A command needs that
-- declaration: omegga tells the player any other doesn't exist, and only
-- declared names reach Lua. A world can also take commands without Lua, with
-- the Chat Command gate wired to whatever it should do.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local command = {}

-- name (lowercase) -> the command; kept across a module reload like the
-- handlers omegga.lua registered for them
_G.BR_COMMANDS = _G.BR_COMMANDS or {}
local commands = _G.BR_COMMANDS

--- Words of a command line: split on spaces, with "double quotes" keeping
--- spaces together (a quote can't be escaped).
function command.split(text)
    local args, i = {}, 1
    while i <= #text do
        local c = text:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == '"' then
            local close = text:find('"', i + 1, true)
            args[#args + 1] = text:sub(i + 1, (close or #text + 1) - 1)
            i = (close or #text) + 1
        else
            local word = text:match("^%S+", i)
            args[#args + 1] = word
            i = i + #word
        end
    end
    return args
end

-- a reply to someone who isn't a connected client (a bot) goes to the log
local function reply(ps, text)
    local ok = pcall(BR.player.whisper, ps, text)
    if not ok then print("[BR.command] to " .. tostring(BR.player.id(ps)) .. ": " .. text .. "\n") end
end

local function run(key, player_name, ...)
    local c = commands[key]
    -- unregistered: the handler stays with omegga until the bridge reconnects
    if not c then return end
    local player = BR.player.find(player_name)
    if not player then return end
    -- omegga splits on single spaces; joined again, quotes can group words
    local raw = table.concat({ ... }, " ")
    local ctx = { name = c.name, raw = raw, reply = function(text) reply(player, text) end }
    if c.permission and not BR.perm.has(player, c.permission) then
        ctx.reply("You don't have permission to use /" .. c.name)
        return
    end
    local ok, err = I.call("command /" .. c.name, c.fn, player, command.split(raw), ctx)
    if not ok then
        I.report("BR.command /" .. c.name, err)
        ctx.reply("/" .. c.name .. " failed")
    end
end

--- Run fn(player, args, ctx) when a player types /name, a command the mod
--- declares in its doc.json `commands`. args are its words (BR.command.split)
--- and ctx is { name, raw = the text after the name, reply = fn(text)
--- whispering back }. Names are matched without regard to case.
---
--- opts.permission: a permission (BR.perm) the player needs; others are told
--- they can't use it. opts.aliases: more names (declared too).
--- opts.description and opts.usage: for BR.command.list. Returns a function
--- that unregisters it.
function command.register(name, fn, opts)
    opts = opts or {}
    assert(type(name) == "string" and name:match("^[%w_%-]+$"), "a command name is letters, digits, '_' and '-'")
    assert(type(fn) == "function", "a command needs a function")
    local Omegga = require("omegga")
    local c = { name = name, fn = fn, permission = opts.permission, description = opts.description, usage = opts.usage }
    local names = { name:lower() }
    for _, alias in ipairs(opts.aliases or {}) do names[#names + 1] = alias:lower() end
    for _, n in ipairs(names) do
        commands[n] = c
        Omegga.on("cmd:" .. n, function(...) return run(n, ...) end)
    end
    return function()
        for _, n in ipairs(names) do
            if commands[n] == c then commands[n] = nil end
        end
    end
end

--- The registered commands, as { { name, aliases, description, usage, permission } },
--- sorted by name; `player` leaves out the ones they lack the permission for.
function command.list(player)
    local by, out = {}, {}
    for alias, c in pairs(commands) do
        local e = by[c]
        if not e then
            e = { name = c.name, aliases = {}, description = c.description, usage = c.usage, permission = c.permission }
            by[c] = e
            if not player or not c.permission or BR.perm.has(player, c.permission) then out[#out + 1] = e end
        end
        if alias ~= c.name:lower() then e.aliases[#e.aliases + 1] = alias end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Whether the game has a built-in command `name`. A built-in runs before
--- omegga ever sees it, so a mod can't take its name.
function command.builtin(name)
    local sub = FindFirstOf("BRChatCommandWorldSubsystem")
    return sub ~= nil and sub:IsValid() and sub:ChatCommandExists(FName(name)) == true
end

return command

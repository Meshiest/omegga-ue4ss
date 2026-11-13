-- BR.chat: Chat lines delivered to chosen players: team, local, staff or
-- private channels, ignore lists. The game sends each client a player's line
-- with ClientPushPlayerChatMessage(formatted, raw, sender), so a line sent this
-- way shows as that player's own message, with their name and colour.
--
-- A routed line never reaches the game's own chat handling, so it isn't
-- written to the server log as "LogChat:" and omegga's chat event doesn't see
-- it; BR.event.on("chat") handlers that run before the route still do.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local chat = {}

--- A message as the game formats a typed chat line: markdown to rich text
--- (**bold** to <b>bold</>), :emoji: names to emoji, links made clickable,
--- markup a player typed escaped.
function chat.format(text)
    local utils = StaticFindObject("/Script/Brickadia.Default__BRRichTextUtils")
    return utils:ProcessChatMessage(BR.world.context(), text, {}):ToString()
end

local function recipients(to)
    if to == "all" then return BR.player.list() end
    if type(to) == "table" then return to end
    return { to }
end

-- The line the game sends for a typed message: the sender's name, bold, in the
-- colour this recipient sees it in (a team's, say), then the message:
--   <color="#A5A19A"><style="bold">Name</></>: message
-- The client shows the formatted line as it is, so without the name a routed
-- message arrives with no sender.
local function line_for(recipient, from, message)
    local c = from:GetChatNameColorFor(recipient)
    local name = BR.player.info(from).display_name
    return string.format('<color="#%02X%02X%02X"><style="bold">%s</></>: %s', c.R, c.G, c.B, name, message)
end

--- Deliver `text` as a chat line from player `from` to `to` (a PlayerState, a
--- list, or "all"); bots and anyone not connected are skipped. The line is
--- built as the game builds a typed one: the sender's name in the colour the
--- recipient sees it in, then the text formatted as a typed message
--- (chat.format). opts.raw sends `text` exactly as the formatted line instead.
function chat.send(to, from, text, opts)
    local raw = opts and opts.raw
    local message = not raw and chat.format(text) or nil
    for _, ps in ipairs(recipients(to)) do
        if BR.player.connected(ps) then
            local formatted = raw and text or line_for(ps, from, message)
            BR.player.controller(ps):ClientPushPlayerChatMessage(formatted, text, from)
        end
    end
end

--- Decide who hears each chat line: fn(player, message) returns the
--- PlayerStates that should get it (the sender is not added for you), or nil to
--- let the game send it to everyone as usual. Chat commands ("/...") are left
--- alone. Returns a function that stops routing.
---
---   BR.chat.route(function(player, message)
---       if message:sub(1, 1) == "!" then return staff end  -- a staff channel
---   end)
function chat.route(fn)
    return BR.event.on("chat", function(player, info)
        if not player or info.message:sub(1, 1) == "/" then return nil end
        local ok, to = pcall(fn, player, info.message)
        if not ok then
            I.report("BR.chat.route", to)
            return nil
        end
        if to == nil then return nil end
        chat.send(to, player, info.message)
        return false
    end)
end

--- Limit how fast players chat: more than opts.messages (default 5) lines in
--- opts.per seconds (default 10) mutes a player for opts.mute seconds (default
--- 30); their lines are refused meanwhile and they're told why (opts.message).
--- Commands ("/...") don't count. Returns a function that stops it.
function chat.limit(opts)
    opts = opts or {}
    local messages, per, mute = opts.messages or 5, opts.per or 10, opts.mute or 30
    local sent, muted = {}, {}
    local clock = 0
    local stop_tick = BR.event.tick(function(dt) clock = clock + dt end)
    local stop_chat = BR.event.on("chat", function(ps, info)
        if not ps or info.message:sub(1, 1) == "/" then return nil end
        local key = __addr(ps)
        if muted[key] and clock < muted[key] then
            pcall(BR.player.whisper, ps, opts.message or string.format("You're muted for %d more seconds", math.ceil(muted[key] - clock)))
            return false
        end
        local list = sent[key] or {}
        sent[key] = list
        list[#list + 1] = clock
        while list[1] and clock - list[1] > per do table.remove(list, 1) end
        if #list > messages then
            muted[key] = clock + mute
            sent[key] = {}
            pcall(BR.player.whisper, ps, opts.message or string.format("Slow down: muted for %d seconds", mute))
            return false
        end
        return nil
    end)
    return function() stop_tick() stop_chat() end
end

local function escape(text) return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

--- Filter words out of chat: each word in `words` (matched without regard to
--- case, as a whole word) is replaced with opts.replace (default "■■■"; not
--- asterisks, which chat reads as markdown and drops), or with
--- opts.block the whole line is refused. Returns a function that stops it.
function chat.censor(words, opts)
    opts = opts or {}
    local patterns = {}
    for _, w in ipairs(words) do
        -- each letter as [xX], so case doesn't matter, bounded by non-letters
        local p = escape(w):gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end)
        patterns[#patterns + 1] = "%f[%w]" .. p .. "%f[%W]"
    end
    return BR.event.on("chat", function(ps, info)
        if not ps then return nil end
        local text, hits = info.message, 0
        for _, p in ipairs(patterns) do
            local n
            text, n = text:gsub(p, opts.replace or "■■■")
            hits = hits + n
        end
        if hits == 0 then return nil end
        if opts.block then return false end
        return text
    end)
end

return chat

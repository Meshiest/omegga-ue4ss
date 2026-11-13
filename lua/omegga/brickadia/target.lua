-- BR.target: Who a command means. Mods that take a player argument ("/kick
-- bob", "/heal @team") resolve it here, the same way everywhere: selectors,
-- names matched as players type them, and admins protected from being targeted.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local target = {}

local IMMUNE = "target.immune"
local BYPASS = "target.bypass_immunity"

-- defined unless something defined them already (defining again would reset
-- the roles an admin gave them)
local defined = BR.perm.defined()
if not defined[IMMUNE] then
    BR.perm.define(IMMUNE, { description = "Can't be targeted by other players' commands (kick, slay, teleport)" })
end
if not defined[BYPASS] then
    BR.perm.define(BYPASS, { description = "Targets players even when they are immune" })
end

local function players(opts)
    local list = BR.player.list()
    if opts.bots then for _, b in ipairs(BR.bot.list()) do list[#list + 1] = b end end
    return list
end

local function same(a, b) return __addr(a) == __addr(b) end

local function position(ps)
    local ch = BR.player.character(ps)
    if not ch then return nil end
    local l = ch:K2_GetActorLocation()
    return l
end

local function team_name(ps)
    local t = BR.player.team(ps)
    return t and BR.team.info(t).name
end

-- the selectors, each from (actor, everyone, arg) to a list
local SELECTORS = {}
SELECTORS.all = function(_, all) return all end
SELECTORS.me = function(actor) return actor and { actor } or {} end
SELECTORS.others = function(actor, all)
    local out = {}
    for _, p in ipairs(all) do if not actor or not same(p, actor) then out[#out + 1] = p end end
    return out
end
SELECTORS.nearest = function(actor, all)
    local from = actor and position(actor)
    if not from then return {} end
    local best, best_d
    for _, p in ipairs(all) do
        if not same(p, actor) then
            local at = position(p)
            if at then
                local d = (at.X - from.X) ^ 2 + (at.Y - from.Y) ^ 2 + (at.Z - from.Z) ^ 2
                if not best_d or d < best_d then best, best_d = p, d end
            end
        end
    end
    return best and { best } or {}
end
SELECTORS.random = function(_, all)
    if #all == 0 then return {} end
    return { all[math.random(1, #all)] }
end
SELECTORS.team = function(actor, all, arg)
    local name = arg or (actor and team_name(actor))
    if not name then return {} end
    local out = {}
    for _, p in ipairs(all) do
        local t = team_name(p)
        if t and t:lower() == name:lower() then out[#out + 1] = p end
    end
    return out
end
SELECTORS.alive = function(_, all)
    local out = {}
    for _, p in ipairs(all) do if BR.player.character(p) then out[#out + 1] = p end end
    return out
end
SELECTORS.dead = function(_, all)
    local out = {}
    for _, p in ipairs(all) do if not BR.player.character(p) then out[#out + 1] = p end end
    return out
end
local ALIASES = { a = "all", s = "me", self = "me", o = "others", p = "nearest", r = "random", t = "team" }

-- players whose name (display or account) matches `text`: an exact match
-- wins; otherwise every name starting with it; otherwise every name containing it
local function by_name(all, text)
    local needle = text:lower()
    local exact, prefix, inside = {}, {}, {}
    for _, p in ipairs(all) do
        local info = BR.player.info(p)
        local names = { (info.display_name or ""):lower(), (info.name or ""):lower() }
        local kind
        for _, n in ipairs(names) do
            if n == needle or info.id == needle then kind = "exact" break end
            if n:sub(1, #needle) == needle then kind = kind or "prefix" end
            if not kind and n:find(needle, 1, true) then kind = "inside" end
        end
        if kind == "exact" then exact[#exact + 1] = p
        elseif kind == "prefix" then prefix[#prefix + 1] = p
        elseif kind == "inside" then inside[#inside + 1] = p end
    end
    if #exact > 0 then return exact end
    if #prefix > 0 then return prefix end
    return inside
end

local function names_of(list)
    local out = {}
    for _, p in ipairs(list) do out[#out + 1] = BR.player.info(p).display_name end
    return table.concat(out, ", ")
end

--- The players `spec` means, said by `actor` (a PlayerState, or nil for the
--- console or a mod): a selector (@all or @a, @me or @s, @others or @o,
--- @nearest or @p, @random or @r, @team or @t (the actor's team), @team:<name>,
--- @alive, @dead), an account id, or a name: an exact display or account name,
--- else the names starting with it, else the names containing it.
---
--- Players with the `target.immune` permission are left out unless they are
--- the actor or the actor has `target.bypass_immunity` (opts.immunity = false
--- skips that). opts.bots includes bots. opts.one: exactly one player, else an
--- error naming the candidates. Returns the list, or nil and a message to show.
function target.resolve(actor, spec, opts)
    opts = opts or {}
    if type(spec) ~= "string" or spec == "" then return nil, "name a player" end
    local all = players(opts)
    local list
    local selector, arg = spec:match("^@([%a_]+):?(.*)$")
    if selector then
        selector = ALIASES[selector:lower()] or selector:lower()
        local fn = SELECTORS[selector]
        if not fn then return nil, "no selector @" .. selector end
        list = fn(actor, all, arg ~= "" and arg or nil)
    else
        list = by_name(all, spec)
    end
    if opts.immunity ~= false then
        local bypass = actor and select(2, pcall(BR.perm.has, actor, BYPASS)) == true
        if not bypass then
            local kept, skipped = {}, 0
            for _, p in ipairs(list) do
                local ok, immune = pcall(BR.perm.has, p, IMMUNE)
                if (actor and same(p, actor)) or not (ok and immune) then kept[#kept + 1] = p else skipped = skipped + 1 end
            end
            if #kept == 0 and skipped > 0 then return nil, "you can't target " .. (skipped == 1 and "them" or "those players") end
            list = kept
        end
    end
    if #list == 0 then return nil, "nobody matches " .. spec end
    if opts.one and #list > 1 then
        local shown = {}
        for i = 1, math.min(5, #list) do shown[i] = list[i] end
        return nil, spec .. " matches " .. #list .. " players: " .. names_of(shown) .. (#list > 5 and ", ..." or "")
    end
    return list
end

--- Exactly one player for `spec` (BR.target.resolve with opts.one): the
--- PlayerState, or nil and a message.
function target.one(actor, spec, opts)
    local o = { one = true }
    for k, v in pairs(opts or {}) do o[k] = v end
    local list, err = target.resolve(actor, spec, o)
    if not list then return nil, err end
    return list[1]
end

--- The selector names, for help texts.
function target.selectors()
    local out = {}
    for name in pairs(SELECTORS) do out[#out + 1] = "@" .. name end
    table.sort(out)
    return out
end

return target

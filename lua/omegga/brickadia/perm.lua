-- BR.perm: Permissions: checking them, overriding the game's own for one player,
-- and permissions plugins define for themselves.
--
-- The game's permissions are gameplay tags ("BR.Permission.Building.Placer.PlaceBricks"),
-- granted by roles. Every check the game makes goes through one function the
-- bridge hooks, so a per-player override changes what the game itself allows.
-- A tag covers the tags below it: forbidding "BR.Permission.Building" stops all
-- building, unless a more specific tag has an override of its own.
--
-- Plugin permissions are names a plugin defines ("myplugin.vip"), granted per
-- role and per player, and saved with the world (BR.store "permissions"). They
-- follow the same parent rule.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local single = I.single
local perm = {}

perm.GAME_PREFIX = "BR.Permission"

local ZERO_ID = "00000000-0000-0000-0000-000000000000"

local defined = {}

-- { roles = { [role] = { [name] = bool } }, players = { [id] = { [name] = bool } } };
-- `players` holds game tags too, so overrides come back when a player rejoins
local saved
local function data()
    if saved then return saved end
    local s = BR.store.view("permissions")
    s.data.roles = s.data.roles or {}
    s.data.players = s.data.players or {}
    if not s.pending then saved = s end
    return s
end

-- bots share the all-zero account id, so their grants are kept per PlayerState
-- for this session only
local session = {}

local function is_game(name) return name == perm.GAME_PREFIX or name:sub(1, #perm.GAME_PREFIX + 1) == perm.GAME_PREFIX .. "." end

local function player_grants(ps, create)
    local id = BR.player.id(ps)
    if id == ZERO_ID then
        local key = __addr(ps)
        if create then session[key] = session[key] or { ps = ps, grants = {} } end
        return session[key] and session[key].grants, false
    end
    local players = data().data.players
    if create then players[id] = players[id] or {} end
    return players[id], true
end

-- the most specific entry for `name` in `grants`: the name, then each parent
local function lookup(grants, name)
    if not grants then return nil end
    local key = name
    while key do
        local v = grants[key]
        if v ~= nil then return v end
        key = key:match("^(.*)%.[^.]+$")
    end
    return nil
end

local function valid_name(name)
    assert(type(name) == "string" and name:match("^[%w_%-]+[%w_%-%.]*$") and not name:match("%.$"),
        "a permission name is dot-separated words: \"myplugin.vip\"")
end

--- Define a plugin permission. opts.default: whether players without a grant
--- have it (default false). opts.roles: role names that have it unless a
--- grant says otherwise. opts.description is for listings. Defining one twice
--- replaces the options.
function perm.define(name, opts)
    valid_name(name)
    assert(not is_game(name), "BR.Permission tags are the game's own")
    opts = opts or {}
    defined[name] = { default = opts.default == true, roles = opts.roles or {}, description = opts.description }
end

--- Every defined plugin permission, as { [name] = { default, roles, description } }.
function perm.defined() return defined end

local function defined_root(name)
    local key = name
    while key do
        if defined[key] then return defined[key] end
        key = key:match("^(.*)%.[^.]+$")
    end
    return nil
end

local function game_has(ps, tag)
    return ps:HasPermission({ TagName = FName(tag) }) == true
end

--- Whether a player has a permission: a game tag ("BR.Permission.Fly", the
--- game's own answer, overrides included) or a defined plugin permission.
--- A plugin permission is decided by, in order: the player's own grant, the
--- server owner (who has everything), the highest role the player has that
--- grants or forbids it, the roles in its definition, then its default.
function perm.has(ps, name)
    if is_game(name) then return game_has(ps, name) end
    local def = defined_root(name)
    if not def then error("no permission " .. tostring(name) .. " (BR.perm.define it first)", 2) end
    local own = lookup((player_grants(ps, false)), name)
    if own ~= nil then return own end
    if ps:GetIsOwner() then return true end
    local roles = I.game_state().PermissionsManager:GetAllPermissionsRoles()
    local role_grants = data().data.roles
    -- roles come lowest first, so the last one that decides wins
    local decided
    for i = 1, #roles do
        local role = roles[i]:get().Name:ToString()
        local v = lookup(role_grants[role], name)
        if v ~= nil and ps:GetHasRole(role) then decided = v end
    end
    if decided ~= nil then return decided end
    for _, role in ipairs(def.roles) do
        if ps:GetHasRole(role) then return true end
    end
    return def.default
end

--- Force a permission for one player: true allows, false forbids, nil removes
--- the override. Works on game tags (the game itself then allows or forbids
--- it) and plugin permissions. Saved by account, so it comes back when they
--- rejoin; a bot's lasts until it leaves.
function perm.set(ps, name, state)
    valid_name(name)
    assert(state == nil or type(state) == "boolean", "state is true, false or nil")
    if not is_game(name) and not defined_root(name) then error("no permission " .. name .. " (BR.perm.define it first)", 2) end
    local grants, persisted = player_grants(ps, true)
    grants[name] = state
    if is_game(name) then __permission_set(ps, name, state) end
    if persisted then data().save() end
end

--- The player's own override for `name` (true, false), or nil.
function perm.get(ps, name) return (player_grants(ps, false) or {})[name] end

--- Drop every override a player has, game and plugin alike.
function perm.clear(ps)
    local grants, persisted = player_grants(ps, false)
    if not grants then return end
    for name in pairs(grants) do grants[name] = nil end
    __permission_clear(ps)
    if persisted then data().save() end
end

--- Grant (true) or forbid (false) a plugin permission for everyone with a role,
--- or remove that (nil). The game's own permissions are edited in its role
--- editor instead.
function perm.set_role(role, name, state)
    valid_name(name)
    assert(not is_game(name), "game permissions are set in the game's role editor")
    assert(state == nil or type(state) == "boolean", "state is true, false or nil")
    local roles = data().data.roles
    roles[role] = roles[role] or {}
    roles[role][name] = state
    data().save()
end

--- The game's permission tags, from every role's list (the tags roles can set).
function perm.game_tags()
    local seen, out = {}, {}
    local roles = I.game_state().PermissionsManager:GetAllPermissionsRoles()
    for i = 1, #roles do
        roles[i]:get().Permissions:ForEach(function(_, p)
            local tag = p:get().Tag.TagName:ToString()
            if not seen[tag] then seen[tag], out[#out + 1] = true, tag end
        end)
    end
    table.sort(out)
    return out
end

--- Call fn(player, tag, allowed) for every permission check the game makes, a
--- tick late, to find out what an action checks. Returns a function that stops it.
function perm.trace(fn)
    __permission_trace(true)
    local stop
    stop = BR.event.tick(function()
        for _, c in ipairs(__permission_trace_take()) do
            local ok, err = pcall(fn, c.player, c.tag, c.result)
            if not ok then I.report("BR.perm.trace", err) end
        end
    end)
    return function()
        stop()
        __permission_trace(false)
    end
end

-- Saved game-tag overrides reach a player's PlayerState when it appears (a join,
-- a reload of this module); the hook forgets a PlayerState once it is gone.
-- One poller per Lua state, as with the other pollers.
local applied = {}
local function apply_saved()
    -- the poller starts with the mod, before the world (and its game state) loads
    local gs = single("BRGameStateBase")
    if not gs then return end
    local players = data().data.players
    gs.PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if not ps:IsValid() then return end
        local key = __addr(ps)
        local id = BR.player.id(ps)
        if applied[key] == id then return end
        applied[key] = id
        for name, state in pairs(players[id] or {}) do
            if is_game(name) then __permission_set(ps, name, state) end
        end
    end)
end

if _G.BR_PERM_POLL then _G.BR_PERM_POLL() end
do
    local wait = 0
    _G.BR_PERM_POLL = BR.event.tick(function(dt)
        wait = wait - dt
        if wait > 0 then return end
        wait = 1
        local ok, err = pcall(apply_saved)
        if not ok then I.report("BR.perm", err) end
    end)
end

return perm

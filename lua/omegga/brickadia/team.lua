-- BR.team: Game mode teams.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local str, player_lib, single = I.str, I.player_lib, I.single
local team = {}

--- Every team, unaffiliated (id -1) first, then the game mode's teams by id.
function team.list()
    local gs = single("BRGameStateBase")
    local out = { gs:GetUnaffiliatedTeam() }
    for i = 0, gs:GetNumTeams() - 1 do
        local t = gs:GetTeam(i)
        if t and t:IsValid() then out[#out + 1] = t end
    end
    return out
end

function team.info(team)
    local c = team:GetTeamDisplayColor()
    local members = {}
    for i = 0, team:GetNumMembers() - 1 do
        local m = team:GetMember(i)
        if m and m:IsValid() then members[#members + 1] = str(m:GetUserName()) end
    end
    return {
        id = single("BRGameStateBase"):GetTeamId(team),
        name = BR.raw.fstring(player_lib("GetTeamName", team)),
        color = { c.R, c.G, c.B, c.A },
        members = members,
    }
end

--- The team's members as PlayerStates.
function team.players(t)
    local out = {}
    for i = 0, t:GetNumMembers() - 1 do
        local m = t:GetMember(i)
        if m and m:IsValid() then out[#out + 1] = m end
    end
    return out
end

--- Move a player to the team with `id` (-1: unaffiliated). `respawn` respawns
--- them on it; without it they keep their current character.
function team.join(ps, id, respawn)
    local pc = assert(BR.player.controller(ps), "no controller")
    pc:JoinGameModeTeam(id, respawn and true or false, false)
end

--- The team named `name`, or nil.
function team.find(name)
    for _, t in ipairs(BR.team.list()) do
        if BR.team.info(t).name == name then return t end
    end
end

-- Teams are created and deleted through the game mode manager's server calls
-- on the bridge's own controller, the calls a client's game mode editor sends,
-- so clients' team lists update the way an owner's edits do.
local function manager()
    return assert(BR.player.controller(BR.player.server()), "no server controller").GameModeManagerComponent
end

local function team_set()
    local set = {}
    for _, t in ipairs(BR.team.list()) do set[__addr(t)] = t end
    return set
end

--- Change a team's settings. opts: name, color {r, g, b}, friendly_damage
--- (bool), respawn_time and invincibility (seconds after respawning),
--- max_item_slots, spectator (force spectator mode). Anything else is on
--- t.Settings (SetStartingInventory, SetGameplayPermission, damage modes...).
function team.configure(t, opts)
    local s = t.Settings
    if opts.name then s:SetTeamName(opts.name) end
    if opts.color then s:SetTeamColor({ R = opts.color[1], G = opts.color[2], B = opts.color[3], A = 255 }) end
    if opts.friendly_damage ~= nil then s:SetFriendlyDamage(opts.friendly_damage) end
    if opts.respawn_time then s:SetPlayerRespawnTime(opts.respawn_time) end
    if opts.invincibility then s:SetRespawnInvincibilityTime(opts.invincibility) end
    if opts.max_item_slots then s:SetMaxItemSlots(opts.max_item_slots) end
    if opts.spectator ~= nil then s:SetForceSpectatorMode(opts.spectator) end
end

--- The team named `name`, created if there is none, with team.configure's
--- options applied. Like other game mode edits, it lasts until the game mode is
--- reset or reloaded. Returns the team.
function team.create(name, opts)
    local t = team.find(name)
    if not t then
        local before = team_set()
        -- the changelist and initial rules have to be empty tables
        manager():ServerCreateTeam({}, {}, false)
        -- a new team isn't always appended, so find the one that wasn't there
        for addr, candidate in pairs(team_set()) do
            if not before[addr] then t = candidate break end
        end
        assert(t, "the game mode did not create a team")
        t.Settings:SetTeamName(name)
    end
    if opts then team.configure(t, opts) end
    return t
end

--- Delete the team named `name` (or a team object). Its members become
--- unaffiliated.
function team.delete(t)
    local name = type(t) == "string" and t or BR.team.info(t).name
    manager():ServerDeleteTeam(name, false)
end

-- Rules. Teams carry rules from the game mode editor (speed and health
-- multipliers, infinite ammo, keeping inventory, water damage, uniforms, music,
-- scoring...), each a BRGameModeTeamRule_<Kind> object whose setters
-- (SetWalkSpeedMultiplier, ...) take effect at once and replicate, so clients
-- predict with the same values. The game mode has its own game-wide rules
-- (BRGameModeRule_<Kind>: Rounds, TimeLimit, AutoSort...), in the same kind of
-- container on the game state; BR.world.rule reaches those. There is no rule
-- container on a player or character: a rule for one player means a team of
-- their own. Rules added here last until the game mode is reset or reloaded;
-- the game mode's saved settings are unchanged.

local function rule_class(prefix, kind)
    local cls = StaticFindObject("/Script/Brickadia." .. prefix .. kind)
    assert(cls and cls:IsValid(), "no rule " .. prefix .. tostring(kind))
    return cls
end

local kinds = {}
local function rule_kinds(prefix)
    if kinds[prefix] then return kinds[prefix] end
    local base = StaticFindObject("/Script/Brickadia." .. prefix:sub(1, -2))
    local class = StaticFindObject("/Script/CoreUObject.Class")
    local out = {}
    ForEachUObject(function(obj)
        if not obj:IsA(class) then return end
        local name = obj:GetFName():ToString()
        if name:sub(1, #prefix) == prefix and obj:IsChildOf(base) then out[#out + 1] = name:sub(#prefix + 1) end
    end)
    table.sort(out)
    kinds[prefix] = out
    return out
end

local function rules(container, prefix)
    local out = {}
    container.Rules:ForEach(function(_, r)
        local rule = r:get()
        if rule and rule:IsValid() then
            local kind = rule:GetClass():GetFName():ToString():gsub("^" .. prefix, "")
            out[#out + 1] = { kind = kind, rule = rule }
        end
    end)
    return out
end

local function rule(container, prefix, kind, create)
    local cls = rule_class(prefix, kind)
    local found = container:FindRule(cls)
    if found and found:IsValid() then return found end
    if create == false then return nil end
    local added = container:AddRule(cls)
    assert(added and added:IsValid(), "the game mode refused rule " .. kind)
    return added
end

local function remove_rule(container, prefix, r)
    if type(r) == "string" then r = rule(container, prefix, r, false) end
    if r then container:RemoveRule(r) end
end

-- shared with BR.world's game-wide rules
I.rule_container = { kinds = rule_kinds, list = rules, get = rule, remove = remove_rule }

local TEAM = "BRGameModeTeamRule_"

--- The kinds of team rule this build has, as BR.team.rule takes them
--- (EnhancedBrickadians, InfiniteAmmo, RestrictedChatRange, HealthRegeneration,
--- ...), sorted. Found by looking through every class once, which takes a
--- fraction of a second; later calls reuse the list.
function team.rule_kinds() return rule_kinds(TEAM) end

--- The rules on a team as { kind, rule } (kind without the class prefix).
function team.rules(t) return rules(t.TeamRuleContainer, TEAM) end

--- A team's rule of `kind` (from BR.team.rule_kinds), added if it has none unless
--- `create` is false. Change it with its setters:
---   BR.team.rule(t, "EnhancedBrickadians"):SetWalkSpeedMultiplier(1.5)
function team.rule(t, kind, create) return rule(t.TeamRuleContainer, TEAM, kind, create) end

--- Remove a rule from a team: a kind, or a rule object.
function team.remove_rule(t, r) remove_rule(t.TeamRuleContainer, TEAM, r) end

return team

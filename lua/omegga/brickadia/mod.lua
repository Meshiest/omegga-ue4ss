-- BR.mod: Moderation: kicking, bans, and refusing players as they join.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local single = I.single
local mod = {}

local ZERO = { A = 0, B = 0, C = 0, D = 0 }

-- FDateTime counts 100 ns ticks from 0001-01-01; Unix time starts 62135596800 s later
local UNIX_EPOCH = 62135596800
local TICKS = 10000000

-- a ban without a duration lasts this long: the game's ban list has no "forever"
local PERMANENT = 100 * 365 * 24 * 3600

--- An account id ("8-4-4-4-12" hex, as BR.player.id gives) as a BRGuid table.
function mod.guid(id)
    local a, b1, b2, c1, c2, d = id:match("^(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)(%x%x%x%x%x%x%x%x)$")
    assert(a, "not an account id: " .. tostring(id))
    return { A = tonumber(a, 16), B = (tonumber(b1, 16) << 16) | tonumber(b2, 16), C = (tonumber(c1, 16) << 16) | tonumber(c2, 16), D = tonumber(d, 16) }
end

-- a PlayerState or an account id, as the id
local function account(who)
    if type(who) == "string" then return who end
    return BR.player.id(who)
end

-- the connected player with this account id, if any
local function online(id)
    for _, ps in ipairs(BR.player.list()) do
        if BR.player.id(ps) == id then return ps end
    end
end

--- Disconnect a player (bots included) with a reason they are shown. The game
--- announces it in chat ("... was kicked by server (reason)"). `by`, a
--- PlayerState, names who did it.
function mod.kick(ps, reason, by)
    local pc = BR.player.controller(ps)
    assert(pc, "no controller for that player")
    return single("BRGameSession"):BRKickPlayer(pc, by and BR.player.controller(by) or nil, reason or "") == true
end

--- Ban an account (a PlayerState or account id) and kick them if they are on.
--- opts.duration in seconds (default: permanent, which is 100 years: the
--- game's bans always expire), opts.reason, opts.by (the banning PlayerState).
--- The game keeps bans in Saved/Server/BanList.json and refuses banned players
--- when they connect.
function mod.ban(who, opts)
    opts = opts or {}
    local id = account(who)
    assert(id ~= "00000000-0000-0000-0000-000000000000", "bots have no account to ban")
    local expires = os.time() + (opts.duration or PERMANENT)
    single("BRGameStateBase"):Ban(mod.guid(id), { Ticks = (expires + UNIX_EPOCH) * TICKS },
        opts.by and mod.guid(BR.player.id(opts.by)) or ZERO, opts.reason or "")
    local ps = type(who) ~= "string" and who or online(id)
    if ps then mod.kick(ps, opts.reason or "banned", opts.by) end
end

function mod.unban(who) single("BRGameStateBase"):Unban(mod.guid(account(who))) end

--- The ban on an account as { reason, by (account id), created, expires } (Unix
--- seconds), or nil if they aren't banned.
function mod.banned(who)
    local gs = single("BRGameStateBase")
    local g = mod.guid(account(who))
    if not gs:IsBanned(g) then return nil end
    local b = gs:GetBan(g)
    local by = b.BannerId
    return {
        reason = b.Reason:ToString(),
        by = string.format("%08x-%04x-%04x-%04x-%04x%08x", by.A, by.B >> 16, by.B & 0xFFFF, by.C >> 16, by.C & 0xFFFF, by.D),
        created = b.Created.Ticks // TICKS - UNIX_EPOCH,
        expires = b.Expires.Ticks // TICKS - UNIX_EPOCH,
    }
end

--- Every ban, from the game's ban list file: { [account id] = { reason, by,
--- created, expires } }, with times as the file has them ("2026.11.12-06.24.57", UTC).
function mod.bans()
    local saved = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString()
    local f = io.open(saved .. "Server/BanList.json", "rb")
    if not f then return {} end
    local ok, data = pcall(require("omegga.json").decode, f:read("a"))
    f:close()
    local out = {}
    for id, b in pairs(ok and type(data) == "table" and data.banList or {}) do
        out[id] = { reason = b.reason, by = b.bannerId, created = b.created, expires = b.expires }
    end
    return out
end

-- Join gates. A real client logging in fires the login hook at once; bots never
-- log in, so new names in the player list are also polled for, which catches
-- anyone the hook missed.
local gates = {}
local checked = {}

local function check(ps)
    if not ps or not ps:IsValid() then return end
    local key = __addr(ps)
    if checked[key] then return end
    checked[key] = true
    for i = #gates, 1, -1 do
        local ok, verdict = pcall(gates[i], ps)
        if not ok then
            I.report("BR.mod.on_join", verdict)
        elseif verdict == false or type(verdict) == "string" then
            mod.kick(ps, type(verdict) == "string" and verdict or "You can't join this server")
            return
        end
    end
end

local function poll()
    local gs = single("BRGameStateBase")
    if not gs then return end
    local present = {}
    gs.PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if ps:IsValid() then
            present[__addr(ps)] = true
            check(ps)
        end
    end)
    -- forget who left, so a reused address is checked afresh
    for key in pairs(checked) do
        if not present[key] then checked[key] = nil end
    end
end

local watching = false
local function watch()
    if watching then return end
    watching = true
    -- everyone here now was let in already (nobody, before the world loads)
    local gs = single("BRGameStateBase")
    if gs then gs.PlayerArray:ForEach(function(_, p) checked[__addr(p:get())] = true end) end
    BR.event.on("join", function(player) check(player) end)
    BR.timer.every(0.1, poll)
end

--- Call fn(player) for everyone who joins from now on, bots included, as soon as
--- they appear. Returning false kicks them; returning a string kicks them with
--- that reason. Gates run newest first, and the first to refuse decides.
--- Returns a function that removes the gate.
function mod.on_join(fn)
    watch()
    gates[#gates + 1] = fn
    return function()
        for i, g in ipairs(gates) do if g == fn then table.remove(gates, i) break end end
    end
end

return mod

-- Trusted interact: pressing someone else's button, switch, door or seat needs
-- their trust, the same trust the game asks for to build on their bricks. A
-- refused press shows the player a status line and never reaches the brick.
-- Run it in the bridge (an omegga plugin's emitPlugin('exec', ...)):
--
--   local T = dofile("<omegga>/plugins/ue4ss/examples/trustedinteract.lua")
--   T.start()   -- from now on
--   T.stop()
--
-- Public bricks (owned by nobody) stay usable by everyone. Holders of the
-- trustedinteract.bypass permission (Admin by default) press anything.
local T = {}

local BYPASS = "trustedinteract.bypass"
local NOTICE_EVERY = 3

_G.TRUSTED_INTERACT = _G.TRUSTED_INTERACT or { notified = {} }
local S = _G.TRUSTED_INTERACT

local function statics() return StaticFindObject("/Script/Brickadia.Default__BrickInstanceStatics") end

-- The game's own check: may this controller modify (and so use) the brick?
-- It covers trust, collective trust rules and bricks on vehicles' grids.
local function trusted(h, pc)
    local r = BR.raw.call(statics(), "BrickInstanceStatics", "HasTrustToModifyBrick", {
        BrickHandle = h, Controller = BR.raw.ptr(pc),
    })
    return BR.raw.bool(r.ReturnValue)
end

-- BR.brick.owner gives the owner's { index, id, name, display_name }, or nil
-- when the brick's owner index has no entry
local function owner_of(h)
    local ok, info = pcall(BR.brick.owner, h)
    return ok and info or nil
end

local function notify(ps, text)
    local key = __addr(ps)
    local now = os.clock()
    if now - (S.notified[key] or 0) < NOTICE_EVERY then return end
    S.notified[key] = now
    pcall(BR.player.status, ps, text)
end

local function on_interact(ps, info)
    local h = info.brick
    if not (h and BR.brick.valid(h)) then return nil end
    if BR.bot.is_bot(ps) then return nil end
    local owner = owner_of(h)
    if not owner or owner.index == BR.brick.PUBLIC then return nil end
    if BR.perm.has(ps, BYPASS) then return nil end
    local pc = BR.player.controller(ps)
    if not pc then return nil end
    local allowed, yes = pcall(trusted, h, pc)
    if not allowed or yes then return nil end
    notify(ps, (owner.display_name or owner.name or "Its owner") .. " hasn't trusted you to use that.")
    return false
end

function T.start()
    T.stop()
    if not BR.perm.defined()[BYPASS] then
        BR.perm.define(BYPASS, { description = "Use other players' buttons, switches and doors without their trust" })
        BR.perm.set_role("Admin", BYPASS, true)
    end
    S.stop = BR.event.on("interact", on_interact)
    return "trusted interact on"
end

function T.stop()
    if S.stop then pcall(S.stop) end
    S.stop = nil
end

return T

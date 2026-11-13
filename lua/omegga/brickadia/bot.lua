-- BR.bot: Bots: players with no client behind them. A bot is a spawned player
-- controller, so the game treats it as a player: it is in the player list, joins
-- teams, owns bricks, chats and has its own set of builder tools (BR.act). Its
-- character is driven by an AI controller of its own (see "Driving" below).
-- BR.npc is the game's own AI bots, which are characters only.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local single = I.single
local bot = {}

local CONTROLLER = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"
local AI_CONTROLLER = "/Script/AIModule.AIController"

-- Driving. On a dedicated server a player controller is never local, so the
-- server moves its character and runs its weapons only from what the client
-- sends. A bot's character is handed to an AI controller instead, which the
-- server treats as local: movement input, view rotation, crouch, sprint and
-- weapon input then apply directly. The player controller keeps the identity
-- (name, player list, tools, chat), and the character and PlayerState are linked
-- both ways so team, nametag and BR.player.character still work. The PlayerState
-- is marked a bot (bIsABot): the game then takes its NPC paths for that
-- character, where a player's character it would expect a player controller
-- behind, and crash without one.
--
-- A bot is armed while its player controller still holds a new character
-- (pickups only arm a player-held character), then handed over. The game does
-- not respawn a bot, so this does, after
-- opts.respawn_after seconds.

-- per bot, by PlayerState address; in _G so a BR_RELOAD keeps bots going
_G.BR_BOTS = _G.BR_BOTS or {}
local bots = _G.BR_BOTS

-- live, not just valid: after a world load the old world's objects are still
-- IsValid until the garbage collector runs (I.alive)
local function valid(o) return I.alive(o) end

--- Whether a PlayerState is a bot: it has a controller but no client, and is not
--- a server owner (BR.player.server's, which each Lua state that uses it spawns).
function bot.is_bot(ps)
    return BR.player.controller(ps) ~= nil and not BR.player.connected(ps) and not ps.bIsOwner
end

local function state(ps)
    if not bot.is_bot(ps) then error("not a bot", 3) end
    local key = __addr(ps)
    local s = bots[key]
    if not s then
        s = { ps = ps, yaw = 0, pitch = 0, loadout = {}, respawn_after = 3 }
        bots[key] = s
    end
    bot.drive()
    return s
end

-- the weapon pickup Blueprint for a weapon name ("Pistol", "Longsword", ...)
local function pickup_class(name)
    local path = "/Game/Pickups/Weapons/BP_ItemPickup_" .. name .. ".BP_ItemPickup_" .. name .. "_C"
    local cls = StaticFindObject(path)
    if not valid(cls) then
        LoadAsset(path)
        cls = StaticFindObject(path)
    end
    if not valid(cls) then error("no weapon " .. tostring(name), 4) end
    return cls
end

-- Put a weapon into a player-held character, through a pickup as if it walked
-- into one. Returns the inventory slot it went to, or nil.
local function pick_up(ch, name)
    local p = BR.world.spawn(pickup_class(name))
    local v = ch:K2_GetActorLocation()
    BR.world.teleport(p, v.X, v.Y, v.Z)
    p:HandlePickupAttempt(ch)
    for _, e in ipairs(BR.player.inventory(ch)) do
        if e.item == "Weapon_" .. name .. "_C" then return e.slot end
    end
end

local function link(s, ch)
    s.ps.PawnPrivate = ch
    ch.PlayerState = s.ps
end

-- Hand the character the player controller holds to the bot's AI controller.
local function take_over(s, ch)
    if not valid(s.ai) then s.ai = BR.world.spawn(StaticFindObject(AI_CONTROLLER)) end
    s.ai:Possess(ch)
    link(s, ch)
    s.character, s.dead_for = __addr(ch), nil
end

-- Take down what the bot's AI controller holds: its character, alive or dead,
-- and the controller. Left standing, the character keeps ticking as if a local
-- player drove it and looks for a HUD every frame, which a dedicated server
-- doesn't have: an error in the log each tick.
local function bury(s)
    local ch = valid(s.ai) and s.ai.Pawn
    if valid(ch) then ch:K2_DestroyActor() end
    if valid(s.ai) then s.ai:K2_DestroyActor() end
    s.ai = nil
end

-- the character the bot's AI controller drives, or nil
local function driven(s)
    local ch = valid(s.ai) and s.ai.Pawn
    if valid(ch) and not ch.bIsDead then return ch end
end

--- Spawn a bot named `name` and return its PlayerState. opts: team (game mode
--- team id, default -1, unaffiliated), weapons (names: "Pistol", "Longsword",
--- ...; it gets them on every spawn), respawn_after (seconds after a death,
--- default 3; false: stay dead until BR.player.respawn, for game modes that run
--- their own respawns), respawn = false (no character until BR.player.respawn).
-- A bot's character counts as locally controlled (see Driving), so its tick
-- runs the client's interaction prompt: near some interactables (a seat, for
-- one) it sets up the on-screen prompt widget, whose Blueprint reaches for
-- Slate, which a dedicated server doesn't have, and the server crashes
-- ("Assertion failed: CurrentApplication.IsValid()"). A server shows no
-- prompts, so the widget's Setup is refused for everyone, once per Lua state.
local function no_prompt_widgets()
    if _G.BR_NO_PROMPT_WIDGETS then return end
    _G.BR_NO_PROMPT_WIDGETS = true
    -- hooks match a call's function object, and a Blueprint widget that
    -- overrides Setup is called through its own: so the native one and every
    -- loaded override are refused
    local base = StaticFindObject("/Script/Brickadia.BRInteractablePromptWidget")
    local paths = { "/Script/Brickadia.BRInteractablePromptWidget:Setup" }
    -- UE4SS gives a widget class no IsChildOf, so its supers are walked
    local function derives(class)
        local s = class:GetSuperStruct()
        while s and s:IsValid() do
            if s:GetAddress() == base:GetAddress() then return true end
            s = s:GetSuperStruct()
        end
        return false
    end
    ForEachUObject(function(o)
        if o:GetClass():GetFName():ToString() == "WidgetBlueprintGeneratedClass" and derives(o) then
            -- the full name is "<Class type> <path>"
            paths[#paths + 1] = o:GetFullName():match(" (.*)") .. ":Setup"
        end
    end)
    for _, path in ipairs(paths) do
        local ok, err = pcall(BR.event.hook, path, function() return false end)
        if not ok then I.report("BR.bot prompt widgets", err) end
    end
end

function bot.spawn(name, opts)
    opts = opts or {}
    no_prompt_widgets()
    local pc = BR.world.spawn(StaticFindObject(CONTROLLER))
    local ps = pc.PlayerState
    if not valid(ps) then error("the spawned controller has no PlayerState", 2) end
    ps.PlayerNamePrivate = name
    ps:OnRep_PlayerName()
    ps.bIsABot = true
    local s = state(ps)
    s.loadout = opts.weapons or {}
    if opts.respawn_after ~= nil then s.respawn_after = opts.respawn_after end
    pc:JoinGameModeTeam(opts.team or -1, opts.respawn ~= false, false)
    -- arm and hand over now, so BR.bot calls work as soon as this returns
    local ch = pc.Pawn
    if valid(ch) then
        for _, weapon in ipairs(s.loadout) do pick_up(ch, weapon) end
        take_over(s, ch)
    end
    return ps
end

--- PlayerStates of every bot.
function bot.list()
    local out = {}
    I.game_state().PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if ps:IsValid() and bot.is_bot(ps) then out[#out + 1] = ps end
    end)
    return out
end

-- The game announces a leaving player, bots included, with a chat line from the
-- server and a sound each client plays itself when the PlayerState goes away.
-- The line goes out through the game state's chat multicasts while the
-- controller is destroyed; these hooks drop every broadcast in that short window
-- rather than decode the message to pick out the bot's. The sound still plays.
local QUIET_LEAVE_SECONDS = 0.2
_G.BR_BOT_QUIET_UNTIL = _G.BR_BOT_QUIET_UNTIL or 0
local function now()
    return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(BR.world.context())
end
local function quiet_leaves()
    if _G.BR_BOT_QUIET_HOOKED then return end
    _G.BR_BOT_QUIET_HOOKED = true
    for _, fn in ipairs({ "MulticastPushChatMessageText", "MulticastPushChatMessage" }) do
        BR.event.hook("/Script/Brickadia.BRGameStateBase:" .. fn, function()
            if now() < _G.BR_BOT_QUIET_UNTIL then return false end
        end)
    end
end

--- Remove a bot: its character now, its controllers and PlayerState on the next
--- tick (it is still in BR.bot.list until then). The game's "left the game"
--- chat line is suppressed (chat broadcast in that same moment is dropped too);
--- clients still play the leave sound.
function bot.remove(ps)
    if not bot.is_bot(ps) then error("not a bot", 2) end
    quiet_leaves()
    local s = bots[__addr(ps)]
    if s then bury(s) end
    local ch = BR.player.character(ps)
    if valid(ch) then ch:K2_DestroyActor() end
    _G.BR_BOT_QUIET_UNTIL = now() + QUIET_LEAVE_SECONDS
    -- K2_DestroyActor leaves a player controller standing; an expiring lifespan
    -- takes it down, PlayerState and tools included
    BR.player.controller(ps):SetLifeSpan(0.01)
    bots[__addr(ps)] = nil
end

-- how close a waypoint along the way counts as reached, and how close to a
-- waypoint that needs a jump the bot jumps
local WAYPOINT_RADIUS, JUMP_DISTANCE = 12, 35
-- a route making less progress than this per check is stuck
local STUCK_CHECK, STUCK_PROGRESS, REPLANS = 1.0, 15, 3

local function callback(fn, ps, what)
    if not fn then return end
    local ok, err = pcall(fn, ps)
    if not ok then I.report("BR.bot." .. what, err) end
end

local function end_route(s, arrived)
    local r = s.route
    s.route, s.dx, s.dy = nil, nil, nil
    callback(arrived and r.on_arrive or r.on_fail, s.ps, arrived and "on_arrive" or "on_fail")
end

-- Head for the route's current waypoint: advance past reached ones, jump where
-- the path climbs, and replan (path_to routes) or give up when stuck.
local function steer(s, ch, dt)
    local r = s.route
    local loc = ch:K2_GetActorLocation()
    local pt = r.points[r.i]
    local last = r.i == #r.points
    local tx, ty = pt[1] - loc.X, pt[2] - loc.Y
    local dist = math.sqrt(tx * tx + ty * ty)
    if dist <= (last and r.radius or WAYPOINT_RADIUS) then
        if last then
            -- stop where it arrived, rather than slide on past
            ch.CharacterMovement:StopMovementImmediately()
            return end_route(s, true)
        end
        r.i, r.best = r.i + 1, nil
        return steer(s, ch, dt)
    end
    if pt.jump and r.jumped ~= r.i and dist < JUMP_DISTANCE then
        s.jump, r.jumped = true, r.i
    end
    r.waited = (r.waited or 0) + dt
    if r.waited >= STUCK_CHECK then
        local stuck = r.best and r.best - dist < STUCK_PROGRESS
        r.waited, r.best = 0, dist
        if stuck then
            if r.goal and r.replans < REPLANS then
                return bot.path_to(s.ps, r.goal, r.opts, r.replans + 1)
            elseif r.goal or r.on_fail then
                return end_route(s, false)
            end
        end
    end
    s.dx, s.dy = tx / dist, ty / dist
end

-- EBRWeaponInputKeys
local KEY_FIRE, KEY_RELOAD = 1, 4
-- how long a tapped key (a reload) stays down
local TAP_SECONDS = 0.2

-- weapon keys: s.keys[key] = true while held, or seconds left for a tap
local function weapon_keys(s, ch, dt)
    if not s.keys then return end
    local w = ch:GetItemInstance()
    if not valid(w) then return end
    for key, v in pairs(s.keys) do
        if not s.pressed[key] then
            w:SetPredictedWeaponInput(key, true)
            s.pressed[key] = true
        end
        if type(v) == "number" then
            v = v - dt
            s.keys[key] = v > 0 and v or nil
        end
        if s.keys[key] == nil then
            w:SetPredictedWeaponInput(key, false)
            s.pressed[key] = nil
        end
    end
end

local function drive_character(s, ch, dt)
    if s.route then steer(s, ch, dt) end
    if s.dx then ch:AddMovementInput({ X = s.dx, Y = s.dy, Z = 0 }, 1.0, false) end
    -- face where it walks unless told where to look
    if s.dx and not s.looking then s.yaw = math.deg(math.atan(s.dy, s.dx)) end
    s.ai:SetControlRotation({ Pitch = s.pitch, Yaw = s.yaw, Roll = 0 })
    -- Jump presses the key and it stays held, jumping again on every landing,
    -- so it is let go on the next tick once the jump is under way
    if s.jumped then
        ch:StopJumping()
        s.jumped = nil
    end
    if s.jump then
        ch:Jump()
        s.jump, s.jumped = nil, true
    end
    weapon_keys(s, ch, dt)
end

-- respawn handling: a character the player controller holds is new (a spawn,
-- or a respawn by the game mode or BR.player.respawn): arm it and take it over
local function tend(s, dt)
    local pc = BR.player.controller(s.ps)
    if not pc then return end
    local held = pc.Pawn
    if valid(held) and not held.bIsDead then
        for _, name in ipairs(s.loadout) do pick_up(held, name) end
        take_over(s, held)
        return
    end
    local ch = driven(s)
    if ch then return drive_character(s, ch, dt) end
    if s.respawn_after then
        s.dead_for = (s.dead_for or 0) + dt
        if s.dead_for >= s.respawn_after then
            s.dead_for = nil
            pc:RestartPlayer(true)
        end
    end
end

local function tick(dt)
    for key, s in pairs(bots) do
        -- a bot kicked or banned through the game loses its player controller
        -- but keeps its PlayerState, which its character still references
        if not valid(s.ps) or not BR.player.controller(s.ps) then
            bury(s)
            bots[key] = nil
        else
            local ok, err = pcall(tend, s, dt)
            if not ok then I.report("BR.bot", err) end
        end
    end
end

-- one driver per server; a reloaded module stops the previous module's
local token = {}
--- Make sure the tick that drives bots runs (BR.bot.spawn does this). Only
--- needed after a BR_RELOAD, for bots spawned before it.
function bot.drive()
    local d = _G.BR_BOT_DRIVER
    if d and d.token == token then return end
    if d then d.stop() end
    _G.BR_BOT_DRIVER = { token = token, stop = BR.event.tick(tick) }
end

--- Walk in world direction (x, y) (any length) until told otherwise; (0, 0)
--- stops. The bot faces where it walks unless BR.bot.look has it look elsewhere.
function bot.move(ps, x, y)
    local s = state(ps)
    bot.stop(ps)
    local len = math.sqrt(x * x + y * y)
    if len == 0 then s.dx, s.dy = nil, nil else s.dx, s.dy = x / len, y / len end
end

local function route(points, opts)
    return { points = points, i = 1, radius = opts.radius or 40, on_arrive = opts.on_arrive, on_fail = opts.on_fail }
end

--- Walk straight to world point `target` {x, y, z}. opts.radius: how close
--- counts as there (default 40 units); opts.on_arrive(ps) runs on arrival, and
--- opts.on_fail(ps), if given, when it stops getting closer. Walls are not
--- avoided: see BR.bot.path_to.
function bot.move_to(ps, target, opts)
    opts = opts or {}
    bot.stop(ps)
    state(ps).route = route({ target }, opts)
end

--- Walk a round of `points` ({ {x, y, z}, ... }) again and again, waiting
--- opts.wait seconds at each (default 0), with BR.bot.path_to around walls
--- when opts.pathfind, else straight lines. Returns a function that stops it.
function bot.patrol(ps, points, opts)
    opts = opts or {}
    assert(#points >= 1, "a patrol needs points")
    local i, stopped = 0, false
    local go
    local function next_point()
        if stopped or not bot.is_bot(ps) then return end
        i = i % #points + 1
        local walk = opts.pathfind and bot.path_to or bot.move_to
        walk(ps, points[i], { radius = opts.radius, on_arrive = function()
            BR.timer.after(opts.wait or 0, go, { owner = ps })
        end, on_fail = function()
            BR.timer.after(1, go, { owner = ps })
        end })
    end
    go = next_point
    go()
    return function()
        stopped = true
        if bot.is_bot(ps) then bot.stop(ps) end
    end
end

--- Keep near `target` (a PlayerState or bot): walk toward them whenever they
--- are further than opts.distance (default 150), re-aiming every opts.every
--- seconds (default 0.5). Returns a function that stops it.
function bot.follow(ps, target, opts)
    opts = opts or {}
    local distance = opts.distance or 150
    return BR.timer.every(opts.every or 0.5, function()
        if not bot.is_bot(ps) then return false end
        local me, them = BR.player.character(ps), BR.player.character(target)
        if not (me and them) then return end
        local a, b = me:K2_GetActorLocation(), them:K2_GetActorLocation()
        local d = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
        if d > distance then
            bot.move_to(ps, { b.X, b.Y, b.Z }, { radius = distance * 0.8 })
        elseif bot.moving(ps) then
            bot.stop(ps)
        end
    end, { owner = ps })
end

--- Walk to world point `target` {x, y, z} along a path BR.nav finds: around
--- walls, up steps, jumping up ledges. The search takes a few ticks; the bot
--- starts once it has a path. When the bot stops getting closer it finds a new
--- path from where it is, up to three times. opts: radius (default 40),
--- on_arrive(ps), on_fail(ps) (no path, or stuck), graph = true to follow the
--- baked graph (BR.nav.route, at once) instead of searching, and the
--- BR.nav.find options.
function bot.path_to(ps, target, opts, replans)
    opts = opts or {}
    local s = state(ps)
    bot.stop(ps)
    local ch = BR.player.character(ps)
    if not ch then error("the bot has no living character", 2) end
    local v = ch:K2_GetActorLocation()
    local function follow(path)
        s.search = nil
        if not path then return callback(opts.on_fail, ps, "on_fail") end
        local r = route(path, opts)
        r.i = math.min(2, #path)
        r.goal, r.opts, r.replans = target, opts, replans or 0
        s.route = r
    end
    if opts.graph then return follow(BR.nav.route({ v.X, v.Y, v.Z }, target)) end
    s.search = BR.nav.find({ v.X, v.Y, v.Z }, target, follow, opts)
end

--- Stop walking, and drop any route or path search (without its callbacks).
function bot.stop(ps)
    local s = bots[__addr(ps)]
    if not s then return end
    if s.search then s.search() end
    s.dx, s.dy, s.route, s.search = nil, nil, nil, nil
end

--- Whether the bot is walking, heading somewhere, or looking for a path.
function bot.moving(ps)
    local s = bots[__addr(ps)]
    return s ~= nil and (s.dx ~= nil or s.route ~= nil or s.search ~= nil)
end

--- Look at yaw and pitch (degrees; yaw 0 is +x, 90 is +y). The bot keeps this
--- view, walking or not, until BR.bot.look(ps) with no angles hands its facing
--- back to its walking direction. Weapons fire where it looks.
function bot.look(ps, yaw, pitch)
    local s = state(ps)
    if yaw == nil then
        s.looking = nil
    else
        s.yaw, s.pitch, s.looking = yaw, pitch or 0, true
    end
end

--- Look at world point {x, y, z}, from the character's eyes.
function bot.look_at(ps, point)
    local ch = BR.player.character(ps)
    if not ch then error("the bot has no living character", 2) end
    local eye = ch:K2_GetActorLocation()
    local r = (BR.math.vec(point) - BR.math.vec(eye.X, eye.Y, eye.Z + ch.BaseEyeHeight)):rotator()
    bot.look(ps, r.Yaw, r.Pitch)
end

local function character(ps)
    local s = state(ps)
    local ch = driven(s)
    if not ch then error("the bot has no living character", 3) end
    return ch, s
end

--- Jump once.
function bot.jump(ps) state(ps).jump = true end

--- Hold or release crouch.
function bot.crouch(ps, on)
    local ch = character(ps)
    if on then ch:Crouch(false) else ch:UnCrouch(false) end
end

-- UBRCharacterMovementComponent keeps two unreflected flags after its last
-- delegate (OnControlModeChanged, 0x10 bytes): whether the character is
-- sprinting (+0x13, what GetSprinting reads) and whether it wants to (+0x14,
-- what SetSprinting writes). With tap-to-sprint, which a server's default
-- controls settings have on, letting go of sprint does not end a sprint until
-- the character slows down or turns back.
local SPRINTING_AFTER_DELEGATE = 0x13

--- Hold or release sprint. Releasing ends the sprint at once, even while moving.
function bot.sprint(ps, on)
    local cm = character(ps).CharacterMovement
    cm:SetSprinting(on and true or false)
    if on or not cm:GetSprinting() then return end
    local at = __addr(cm) + I.offset(cm, "OnControlModeChanged") + SPRINTING_AFTER_DELEGATE
    -- only a byte that reads as the sprinting flag is cleared, so a changed
    -- layout leaves the latch alone rather than writing elsewhere
    if __peek(at, 1) == "\1" then __poke(at, "\0") end
end

--- Fly, or walk again. This sets the movement mode itself, so it does not ask
--- for the permission to fly a player would need.
function bot.fly(ps, on)
    -- EMovementMode: MOVE_Walking 1, MOVE_Flying 5
    character(ps).CharacterMovement:SetMovementMode(on and 5 or 1, 0)
end

--- Give the bot a weapon by name ("Pistol", "Longsword", ...; the part after
--- BP_ItemPickup_ in /Game/Pickups/Weapons) and return the slot it went to.
--- Only a character a player controller holds takes a pickup, so it is handed
--- back for that moment.
function bot.give(ps, name)
    local ch, s = character(ps)
    BR.player.controller(ps):Possess(ch)
    local ok, slot = pcall(pick_up, ch, name)
    take_over(s, ch)
    if not ok then error(slot, 2) end
    return slot
end

--- Switch to the item in inventory slot `slot` (0-based, as BR.player.inventory
--- numbers them).
function bot.equip(ps, slot) character(ps):SetDesiredMainInventoryIndex(slot) end

--- Hold or release the trigger of the weapon in hand.
function bot.fire(ps, on)
    local _, s = character(ps)
    s.keys, s.pressed = s.keys or {}, s.pressed or {}
    s.keys[KEY_FIRE] = on and true or nil
    if not on and s.pressed[KEY_FIRE] then s.keys[KEY_FIRE] = 0 end
end

--- Reload the weapon in hand.
function bot.reload(ps)
    local _, s = character(ps)
    s.keys, s.pressed = s.keys or {}, s.pressed or {}
    s.keys[KEY_RELOAD] = TAP_SECONDS
end

--- The weapon in hand, or nil.
function bot.weapon(ps)
    local s = bots[__addr(ps)]
    local ch = s and driven(s)
    local w = ch and ch:GetItemInstance()
    if valid(w) then return w end
end

return bot

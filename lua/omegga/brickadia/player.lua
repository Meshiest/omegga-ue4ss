-- BR.player: Players: who is connected, their characters, inventories and what they see.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local SCRIPT, str, player_lib, single = I.SCRIPT, I.str, I.player_lib, I.single
local player = {}

--- The PlayerState Lua acts as: transactions, admin gates, brick ownership.
---
--- Execute discards every action unless the PlayerState's Owner is a
--- BRPlayerController, and a server with nobody connected has neither, so a
--- controller is spawned once; it creates its own PlayerState, which is the one
--- the game reads permissions through (a second PlayerState merely owned by the
--- controller passes Execute but has no permissions, so admin gates are refused
--- with only a report line). It is marked as the server owner, and since that
--- alone doesn't pass every role check (placing bricks was refused), it also has
--- a permission override allowing every game permission. Edits are also trust-checked
--- against the brick's owner, so the controller is registered in the brick owner
--- table, and bricks this player should edit are placed with that owner index
--- (`BR.brick.builder({ owner = BR.player.owner_index() })`).
---
--- It is not a connected player: it is left out of BR.player.list().
function player.server()
    local ps = _G.BR_PLAYER
    if ps and ps:IsValid() and _G.BR_OWNER_INDEX then
        -- a stand-in made before the grant existed (an older module, reloaded) gets it now
        if _G.BR_PLAYER_GRANTED ~= __addr(ps) then
            __permission_set(ps, "BR.Permission", true)
            _G.BR_PLAYER_GRANTED = __addr(ps)
        end
        return ps
    end
    local pc = BR.world.spawn(StaticFindObject("/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"))
    ps = pc.PlayerState
    assert(ps and ps:IsValid(), "the spawned controller has no PlayerState")
    ps.bIsOwner = true
    -- the all-F account id is PUBLIC's, so its bricks show as PUBLIC rather than
    -- as the all-zero id every bot shares (with a blank name)
    ps.UserId = { A = 0xFFFFFFFF, B = 0xFFFFFFFF, C = 0xFFFFFFFF, D = 0xFFFFFFFF }
    _G.BR_PLAYER_CONTROLLER = pc
    _G.BR_PLAYER = ps
    _G.BR_OWNER_INDEX = single("BRGameStateBase"):IdOrRegisterBrickOwner(pc)
    -- being the owner isn't enough for the role checks a transaction makes (placing
    -- was refused), so every game permission is allowed outright
    __permission_set(ps, "BR.Permission", true)
    _G.BR_PLAYER_GRANTED = __addr(ps)
    return ps
end

function player.owner_index()
    BR.player.server()
    return _G.BR_OWNER_INDEX
end

--- The controller of a PlayerState, or nil.
function player.controller(ps)
    if not I.alive(ps) then return nil end
    local pc = ps:GetOwnerBRPlayerController()
    if pc and pc:IsValid() then return pc end
end

--- Whether a PlayerState belongs to a connected client. Spawned controllers
--- (BR.player.server's, tests) have no NetConnection.
function player.connected(ps)
    local pc = BR.player.controller(ps)
    return pc ~= nil and pc.NetConnection ~= nil and pc.NetConnection:IsValid()
end

--- PlayerStates of the connected players.
function player.list()
    local out = {}
    I.game_state().PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if ps:IsValid() and BR.player.connected(ps) then out[#out + 1] = ps end
    end)
    return out
end

--- A connected player's PlayerState by user name or display name, or nil.
function player.find(name)
    local ps = single("BRGameStateBase"):FindClientState(name)
    if ps and ps:IsValid() then return ps end
end

--- BRGuid {A, B, C, D} as the usual 8-4-4-4-12 hex id.
local function guid(g)
    return string.format("%08x-%04x-%04x-%04x-%04x%08x", g.A, g.B >> 16, g.B & 0xFFFF, g.C >> 16, g.C & 0xFFFF, g.D)
end

--- A player's account id (8-4-4-4-12 hex), the same across sessions and
--- name changes.
function player.id(ps) return guid(ps:GetUserId()) end

--- The living character of a PlayerState, or nil.
function player.character(ps)
    if not I.alive(ps) or not ps:HasLivingCharacter() then return nil end
    local ch = BR.raw.obj(player_lib("GetStatePlayer", ps))
    if ch and ch:IsValid() then return ch end
end

--- The team a PlayerState is on, or nil.
function player.team(ps)
    local t = BR.raw.obj(player_lib("GetStateTeam", ps))
    if t and t:IsValid() then return t end
end

--- A connected player's ping in milliseconds, as the server measures it (0 for
--- bots and the server's stand-in).
function player.ping(ps) return ps:GetPingInMilliseconds() end

--- Seconds since the player joined this server (game time, so it pauses with
--- the world).
function player.online_for(ps)
    local now = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(BR.world.context())
    return math.max(0, now - ps.StartTime)
end

--- When the player joined, as a Unix time (seconds), from the game's join stamp.
function player.joined_at(ps)
    local ok, ticks = pcall(function() return ps.ReplicatedJoinTime.Ticks end)
    if not ok or type(ticks) ~= "number" then return nil end
    -- FDateTime counts 100 ns ticks from 0001-01-01; Unix time starts 1970-01-01
    return math.floor((ticks - 621355968000000000) / 10000000)
end

--- Name, id, team and health of a player, as plain values.
function player.info(ps)
    local team = BR.player.team(ps)
    local ch = BR.player.character(ps)
    local info = {
        name = str(ps:GetUserName()),
        display_name = BR.raw.fstring(player_lib("GetStateDisplayName", ps)),
        id = guid(ps:GetUserId()),
        owner = ps:GetIsOwner(),
        connected = BR.player.connected(ps),
        team = team and BR.team.info(team).name,
        alive = ch ~= nil,
    }
    if ch then info.health, info.max_health = BR.player.health(ch) end
    return info
end

-- Health. Brickadia stores damage taken against a limit, so health is
-- limit - damage and a character dies when damage reaches the limit.

-- a character from a character or a PlayerState (its living character)
local function as_character(who)
    if I.alive(who) and who:IsA(StaticFindObject(SCRIPT .. "BRPlayerState")) then
        local ch = BR.player.character(who)
        if not ch then error("the player has no living character", 3) end
        return ch
    end
    if not (I.alive(who) and who:IsA(StaticFindObject(SCRIPT .. "BRCharacter"))) then error("not a character or player", 3) end
    return who
end

--- Current and maximum health of a character (or a player's character).
function player.health(ch)
    ch = as_character(ch)
    local limit = ch:GetDamageLimit()
    return limit - ch:GetDamage(), limit
end

--- Set a character's (or a player's character's) health, clamped to 0..max;
--- 0 kills it. `max` also changes the maximum.
function player.set_health(ch, hp, max)
    ch = as_character(ch)
    if max then ch:SetDamageLimit(max) end
    local limit = ch:GetDamageLimit()
    ch:SetDamage(limit - math.max(0, math.min(hp, limit)))
end

function player.kill(ch) BR.player.set_health(ch, 0) end

--- Respawn a player (their old character is removed).
function player.respawn(ps)
    assert(BR.player.controller(ps), "no controller"):RestartPlayer(true)
end

-- Spawning and spectating, through the controller's own replicated setters.

--- Make a player a spectator (no character, a free camera) or put them back.
function player.set_spectator(ps, on)
    assert(BR.player.controller(ps), "no controller"):SetIsSpectator(on and true or false)
end

function player.spectator(ps) return assert(BR.player.controller(ps), "no controller"):GetIsSpectator() == true end

--- Stop a player respawning after they die (false), or allow it again (true).
function player.set_can_respawn(ps, can)
    assert(BR.player.controller(ps), "no controller"):SetCannotRespawn(not can)
end

function player.can_respawn(ps) return assert(BR.player.controller(ps), "no controller"):GetCannotRespawn() ~= true end

--- Where a player respawns: a checkpoint brick, or nil to clear it.
function player.set_checkpoint(ps, brick)
    local pc = assert(BR.player.controller(ps), "no controller")
    if not brick then return pc:ClearCheckPoint() end
    assert(BR.brick.valid(brick), "invalid brick handle")
    BR.raw.call(pc, "BRPlayerController", "SetCheckPoint", { CheckPoint = brick })
end

--- A player's checkpoint brick, or nil.
function player.checkpoint(ps)
    local pc = assert(BR.player.controller(ps), "no controller")
    local h = BR.raw.call(pc, "BRPlayerController", "GetCheckPoint", {}).ReturnValue
    return BR.brick.valid(h) and h or nil
end

--- Launch a character with `velocity` ({x, y, z}, units/s), added to its own
--- unless opts.replace_xy / opts.replace_z replace those parts. The engine sends
--- it to the character's client, so it moves smoothly for real players too.
function player.launch(ch, velocity, opts)
    opts = opts or {}
    ch:LaunchCharacter({ X = velocity[1], Y = velocity[2], Z = velocity[3] }, opts.replace_xy == true, opts.replace_z == true)
end

-- Movement. The server sees what a client's moves carry (crouch, sprint, the
-- velocity it ends up with) and what it decides itself (seats, emotes).

-- horizontal speed (units/s) under which a character counts as standing still;
-- a stopped character's replicated velocity is rarely exactly 0
local MOVING_SPEED = 10

local MODES = { [0] = "none", [1] = "walk", [2] = "walk", [3] = "fall", [4] = "swim", [5] = "fly", [6] = "custom" }

local function sit_emote(ch)
    local sit = false
    ch.ActiveEmotes:ForEach(function(_, e)
        local c = e:get()
        if c:IsValid() and c:GetFName():ToString() == "BP_Emote_Sit_C" then sit = true end
    end)
    return sit
end

--- How a character is moving, as plain values:
--- `seated` (in a seat brick), `sitting` (seated or playing the Sit emote),
--- `crouching`, `sprinting` (sprint held while moving, walking or flying),
--- `walking` (moving on the ground, neither sprinting nor crouching), `moving`
--- (any horizontal motion), `speed` (horizontal, units/s), `in_water` (see
--- BR.player.in_water) and `mode`, the movement mode: "walk" (on the ground),
--- "fall", "fly", "swim", "none" or "custom". A sitting character is neither
--- walking, sprinting nor crouching.
function player.movement(ch)
    local cm = ch.CharacterMovement
    local v = ch:GetVelocity()
    local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
    local seated = ch:IsSitting()
    local sitting = seated or sit_emote(ch)
    local moving = speed > MOVING_SPEED
    local mode = MODES[cm.MovementMode] or "custom"
    local crouching = not sitting and ch.bIsCrouched
    local sprinting = not sitting and not crouching and moving and (mode == "walk" or mode == "fly") and ch:GetSprinting()
    return {
        seated = seated,
        sitting = sitting,
        crouching = crouching,
        sprinting = sprinting,
        walking = not sitting and not crouching and not sprinting and moving and mode == "walk",
        moving = moving,
        speed = speed,
        mode = mode,
        in_water = player.in_water(ch),
    }
end

function player.sitting(ch) return player.movement(ch).sitting end
function player.crouching(ch) return player.movement(ch).crouching end
function player.sprinting(ch) return player.movement(ch).sprinting end
function player.walking(ch) return player.movement(ch).walking end

--- Whether a character is in water: the world's water, or a zone with water on.
--- The game moves a character into a water physics volume (a zone's water is
--- a shared stand-in volume) once its centre is under the surface; it swims there.
function player.in_water(ch)
    local pv = ch.CharacterMovement:GetPhysicsVolume()
    return pv ~= nil and pv:IsValid() and pv.bWaterVolume == true
end

--- Whether a character is in a zone (a zone projector's BrickHandle); see
--- BR.zone.contains.
function player.in_zone(ch, zone) return BR.zone.contains(zone, ch) end

-- Inventory: a character's slots hold items (weapons, tools) by class.

--- An item class by its class name ("Weapon_Knife_C" or "Weapon_Knife") or
--- full path, or nil.
function player.item_class(name)
    if name:sub(1, 1) == "/" then
        local c = StaticFindObject(name)
        return c and c:IsValid() and c or nil
    end
    if not name:find("_C$") then name = name .. "_C" end
    local c = FindObject("BlueprintGeneratedClass", name)
    if c and c:IsValid() then return c end
end

--- A character's slots: { slot, count, item = class name or nil }, 0-based.
function player.inventory(ch)
    local inv = ch:GetCharacterInventory()
    local out = {}
    for i = 0, inv:Num() - 1 do
        local e = inv:GetSlotEntry(i)
        local item = e.ItemInstance
        out[#out + 1] = {
            slot = i,
            count = e.Count,
            item = item and item:IsValid() and item:GetClass():GetFName():ToString() or nil,
        }
    end
    return out
end

--- Put an item (a class, or a name for BR.player.item_class) in a player's slot.
function player.give(ps, slot, item, count)
    local class = type(item) == "string" and assert(BR.player.item_class(item), "no item class " .. item) or item
    I.as_controller(ps, function(pc) pc:ServerSetInventorySlot(slot, { Count = count or 1, bIsPlaceable = false, ItemClass = class }) end)
end

--- What a character's player is pressing, as the server last heard it: keys =
--- { primary, secondary, reload, inspect, custom1..custom4 = true } (the weapon
--- keys; custom1-4 are the game's custom weapon binds) and move = {x, y, z}, the
--- direction their movement input pushes (world space, 0 when still).
--- BR.event.on("key") reports presses as they happen.
function player.input(ch)
    local bits = ch.PendingWeaponSimInputs.Keys
    local keys = {}
    for name, bit in pairs(BR.event.KEYS) do
        if (bits & bit) ~= 0 then keys[name] = true end
    end
    local a = ch.CharacterMovement:GetCurrentAcceleration()
    local len = math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z)
    local move = len > 0 and { a.X / len, a.Y / len, a.Z / len } or { 0, 0, 0 }
    return { keys = keys, move = move }
end

--- Change the item in a character's slot (0-based): opts.damage and opts.speed
--- (multipliers of its damage and firing/swing speed), opts.scale (its size),
--- opts.projectile_scale, opts.projectile (another projectile class, by name or
--- class), opts.name (the name shown for it), opts.colors ({ {r, g, b, a}, ... },
--- its mesh colours). These are the fields the game's advanced Add Item gate
--- sets, and they replicate, so the player's client uses the same values.
--- Returns the item, or nil if the slot holds none.
function player.tune(ch, slot, opts)
    local e = ch:GetCharacterInventoryEntry(slot)
    local item = e and e.ItemInstance
    if not (item and item:IsValid()) then return nil end
    if opts.damage then item.DamageMultiplier = opts.damage end
    if opts.speed then item.WeaponSpeedMultiplier = opts.speed end
    if opts.scale then item.ItemScale = opts.scale end
    if opts.name then item.DisplayName = FText(opts.name) end
    if opts.colors then
        local colors = {}
        for i, c in ipairs(opts.colors) do colors[i] = { R = c[1], G = c[2], B = c[3], A = c[4] or 255 } end
        item.MeshColors = colors
    end
    local WEAPON = StaticFindObject(SCRIPT .. "BRWeaponBase")
    if item:IsA(WEAPON) then
        if opts.projectile_scale then item.ProjectileScaleMultiplier = opts.projectile_scale end
        if opts.projectile then
            local p = opts.projectile
            if type(p) == "string" then
                p = FindObject("BlueprintGeneratedClass", p:find("_C$") and p or (p .. "_C"))
                assert(p and p:IsValid(), "no projectile class " .. tostring(opts.projectile))
            end
            item.ProjectileOverride = p
        end
    end
    item:ForceNetUpdate()
    return item
end

--- Empty a player's slot (0-based).
function player.clear_slot(ps, slot) I.as_controller(ps, function(pc) pc:ServerClearInventorySlot(slot) end) end

-- Messages and on-screen text for one player. These are client RPCs, which on a
-- controller without a connection would run the client's UI code on the server,
-- so they refuse anything but a connected player.

local function client(ps)
    assert(BR.player.connected(ps), "not a connected player")
    return BR.player.controller(ps)
end

--- A chat line only this player sees.
function player.whisper(ps, message) client(ps):ClientPushChatMessage(message) end

--- The status line above the hotbar. `flash` flashes it if unchanged; it clears
--- itself unless `keep`.
function player.status(ps, message, flash, keep)
    client(ps):ClientPushStatusMessage(message, flash and true or false, not keep)
end

--- Turn a connected player's view to `yaw` and `pitch` (degrees): the game's
--- own call for it, which their client applies.
function player.set_view(ps, yaw, pitch)
    local rot = { Pitch = pitch or 0, Yaw = yaw, Roll = 0 }
    local pc = client(ps)
    pc:SetControlRotation(rot)
    pc:ClientSetControlRotation(rot)
end

--- While spectating, follow `actor` (a character, an entity...).
function player.spectate_target(ps, actor) client(ps):ClientSetSpectatorTarget(actor) end

--- The game's error dialog, with a title and a message.
function player.error_dialog(ps, title, message) client(ps):ClientShowErrorDialog(FText(title), FText(message)) end

function player.message_box(ps, title, message) client(ps):ClientShowMessageBoxDialog(FText(title), FText(message)) end

--- Fade a player's screen: alpha from `from` to `to` (0 clear, 1 solid) over
--- `seconds`, in color ({r, g, b}, default black); opts.hold keeps it at `to`
--- afterwards, opts.audio fades sound too. BR.player.fade(ps, 0, 1, 1) blacks
--- out over a second; BR.player.fade(ps, 1, 0, 1) brings the picture back.
function player.fade(ps, from, to, seconds, color, opts)
    opts = opts or {}
    local c = color or { 0, 0, 0 }
    client(ps):ClientSetCameraFade(true, { R = c[1], G = c[2], B = c[3], A = 255 }, { X = from, Y = to }, seconds or 1,
        opts.audio == true, opts.hold ~= false)
end

--- Show a player the world from another actor (a camera entity, another
--- character, a vehicle), blending over opts.blend seconds; BR.player.view_reset
--- gives them their own view back.
function player.view_from(ps, actor, opts)
    opts = opts or {}
    client(ps):ClientSetViewTarget(actor, { BlendTime = opts.blend or 0, BlendFunction = 1, BlendExp = 2, bLockOutgoing = false })
end

--- Give a player their own view back (after BR.player.view_from).
function player.view_reset(ps, opts)
    local pc = client(ps)
    local target = pc.Pawn
    if not (target and target:IsValid()) then target = pc end
    pc:ClientSetViewTarget(target, { BlendTime = (opts and opts.blend) or 0, BlendFunction = 1, BlendExp = 2, bLockOutgoing = false })
end

local HINT_PLACES = { game = 0, pause = 1, both = 2 }
--- Show a hint card, as the game's tutorial hints are shown: a title and text,
--- in game (opts.where = "game", the default), in the pause menu ("pause") or
--- both ("both").
function player.hint(ps, title, text, opts)
    opts = opts or {}
    local where = assert(HINT_PLACES[opts.where or "game"], "where is game, pause or both")
    client(ps):ClientPushHintMessage({ HintTitle = FText(title), HintText = FText(text), WhereToShow = where })
end

--- Show text on a player's screen: what the Controller Display Text gate does.
--- `params` are BRDisplayTextParams fields (Text, PersistentId, Position = { X, Y },
--- Anchor, Pivot, FontSize, FontColor = { R, G, B, A }, Lifetime, ...); the same
--- PersistentId replaces earlier text, and BR.player.remove_text removes it.
function player.display_text(ps, params)
    local p = { PersistentId = 0, FontSize = 24, Scale = { X = 1, Y = 1 }, FontColor = { R = 255, G = 255, B = 255, A = 255 } }
    for k, v in pairs(params) do p[k] = v end
    client(ps):ClientDisplayText(p)
end

function player.remove_text(ps, id) client(ps):ClientRemoveDisplayText(id) end

-- Player events. Each is a UFunction the action passes through on the server: an
-- RPC the client sends (chat, tools, emotes), an RPC the server multicasts
-- (death), or a Blueprint event (login, damage). BR.event.on hooks it with BR.event.hook
-- and hands the handler the PlayerState behind it and the event's details.

local function class_of(name) return StaticFindObject(SCRIPT .. name) end

--- The PlayerState behind an object (a controller, character, tool, weapon or a
--- tool's control mode), or nil (bots, the world).
function player.of(obj)
    local PS, PC, CH, ACTOR = class_of("BRPlayerState"), class_of("BRPlayerController"), class_of("BRCharacter"), StaticFindObject("/Script/Engine.Actor")
    local CONTROLLER = StaticFindObject("/Script/Engine.Controller")
    local PROJECTILE = class_of("BRWeaponProjectile")
    for _ = 1, 8 do
        if not obj or not obj:IsValid() then return nil end
        if obj:IsA(PS) then return obj end
        -- a projectile has no owner, but remembers who fired it
        if obj:IsA(PROJECTILE) then
            local ps = obj.InstigatorState
            return ps and ps:IsValid() and ps or nil
        end
        if obj:IsA(PC) then
            local ps = obj.PlayerState
            return ps and ps:IsValid() and ps or nil
        end
        -- any other controller (a bot's AI controller) has no PlayerState of its
        -- own; its character carries the bot's
        if obj:IsA(CONTROLLER) then
            local ps = obj.PlayerState
            if ps and ps:IsValid() then return ps end
            obj = obj.Pawn
            if not obj or not obj:IsValid() then return nil end
        end
        if obj:IsA(CH) then
            local ps = obj:GetBRPlayerState()
            return ps and ps:IsValid() and ps or nil
        end
        if obj:IsA(ACTOR) then obj = obj:GetOwner() else obj = obj:GetOuter() end
    end
end

return player

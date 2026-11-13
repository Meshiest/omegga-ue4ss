-- BR.event: Game events, ticks, function hooks and custom events.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local SCRIPT, cdo, single = I.SCRIPT, I.cdo, I.single
local event = {}

-- Ticks: one native tick listener per Lua state runs every BR.event.tick
-- callback. The list and the listener live in _G, so a reload of this module
-- adds no second native listener (each one also kept the old module alive).
_G.BR_TICK = _G.BR_TICK or { fns = {} }
local tick_fns = _G.BR_TICK.fns

--- Run fn(deltaSeconds) at the start of every engine tick, on the game thread.
--- Returns a function that stops it.
-- what the native listener runs: this load's, so a reload changes it
function _G.BR_TICK.run(dt)
    local fns = tick_fns
    for i = #fns, 1, -1 do
        local f = fns[i]
        local ok, err = I.call("tick", f, dt)
        if not ok then I.report("BR.event.tick", err) end
    end
end

function event.tick(fn)
    if not _G.BR_TICK.installed then
        _G.BR_TICK.installed = true
        local shared = _G.BR_TICK
        __on_tick(function(dt) shared.run(dt) end)
    end
    tick_fns[#tick_fns + 1] = fn
    return function()
        for i, f in ipairs(tick_fns) do if f == fn then table.remove(tick_fns, i) break end end
    end
end

-- Custom events. Every Send Custom Event gate, built in game or by BR, hands its
-- event to one native dispatcher, which queues it on each receiver (Event_Custom
-- gate) listening for that name. The bridge hooks the dispatcher, so listening
-- needs no gates. Sending does what the dispatcher does once it knows its sender:
-- the registry keeps receivers by name, global or per owner, and by the entity
-- an event is for, and BR queues the event on those directly.

local EVENT_VALUES = 8

local registry
local function world_registry()
    if not (registry and registry:IsValid()) then
        registry = FindFirstOf("BRRegistry")
        assert(registry and registry:IsValid(), "no BRRegistry in this world")
    end
    return registry
end

-- an entity's id, what a targeted event is routed by and reports as its target
local function entity_id(entity)
    local id = cdo("BRLuauEntityLibrary"):GetId(entity, BR.world.context())
    return id and id.ElementID or 0
end

local function entity_owner(entity)
    return cdo("BRLuauEntityLibrary"):GetOwnerId(entity)
end

local WIRE_PAD = string.rep("\0", I.WIRE_SIZE)
-- an unconnected data input holds a number 0
local UNSET = BR.wire.double(0)

local function wire_text(value)
    local object = string.unpack("<I8", value)
    if object == 0 then return "" end
    local data, num = string.unpack("<I8i4", __peek(object, 12))
    if data == 0 or num <= 1 then return "" end
    return __peek(data, num - 1)
end

-- the 8 wire values an event carries, padded to their full size. The event
-- takes over the references its strings hold and drops them once delivered,
-- so each string is copied and the caller's value stays usable.
local function pack_values(values)
    assert(values.n <= EVENT_VALUES, "a custom event carries at most 8 values")
    local out = {}
    for i = 1, EVENT_VALUES do
        local v = values[i]
        if v == nil then v = UNSET end
        assert(type(v) == "string" and #v >= 0x21, "custom event data are wire values (BR.wire.bool / int / double / string)")
        if string.byte(v, 0x21) == I.WIRE_KIND_STRING then v = BR.wire.string(wire_text(v)) end
        out[i] = (v .. WIRE_PAD):sub(1, I.WIRE_SIZE)
    end
    return table.concat(out)
end

--- Return `ev`, whose `ev.send(...)` fires the custom event `name` with up to 8
--- data values (wire values: BR.wire.bool / int / double / string; missing ones
--- are 0, as on an unconnected input). Every send is delivered at once and
--- counts: in-game receivers play one event per tick from a queue of up to 64
--- each, so a burst beyond that is cut short for them (Lua listeners hear it
--- all). `ev.send` returns how many receivers it reached.
---
--- opts.target = an entity (BR.world.grids(), BR.brick.grid(brick)) sends the
--- event to that entity only, reaching receivers on it that listen for object
--- events. The game routes a targeted event to receivers built by the sender's
--- owner, so it reaches those built by the entity's owner, or by opts.owner (an
--- owner index, BR.player.owner_index) when given.
function event.custom(name, opts)
    assert(type(name) == "string" and name ~= "", "a custom event needs a name")
    local target = opts and opts.target
    local ev = {}
    if not target then
        function ev.send(...)
            return __custom_event_post(world_registry(), name, true, -1, 0, pack_values(table.pack(...)))
        end
        return ev
    end
    local owner = opts.owner
    function ev.send(...)
        if not I.alive(target) then error("the target entity is gone", 2) end
        return __custom_event_post(world_registry(), name, false, owner or entity_owner(target),
            entity_id(target), pack_values(table.pack(...)))
    end
    return ev
end

-- Listeners. One poller per Lua state takes what the hook recorded since its
-- last look; a reload stops the previous module's poller.
local custom_listeners = {}

local function custom_poll(state)
    local events
    events, state.cursor = __custom_event_take(state.cursor)
    if #events == 0 or #custom_listeners == 0 then return end
    local ids = {}
    for _, l in ipairs(custom_listeners) do
        if l.entity then ids[l] = I.alive(l.entity) and entity_id(l.entity) or nil end
    end
    for _, e in ipairs(events) do
        local data
        for _, l in ipairs(custom_listeners) do
            local wanted = l.any or (l.name == e.name and (l.entity and e.target == ids[l] or not l.entity and e.target == 0))
            if wanted then
                if not data then
                    data = {}
                    for i = 1, EVENT_VALUES do
                        data[i] = I.decode_wirevalue(e.values:sub((i - 1) * I.WIRE_SIZE + 1, i * I.WIRE_SIZE), e.texts[i])
                    end
                end
                local ok, err = pcall(l.fn, data, { name = e.name, target = e.target, sender = e.sender })
                if not ok then I.report("BR.event.on_custom " .. e.name, err) end
            end
        end
    end
end

local function custom_listen(l)
    if not (_G.BR_CUSTOM_POLL and _G.BR_CUSTOM_POLL.module == custom_listeners) then
        if _G.BR_CUSTOM_POLL then _G.BR_CUSTOM_POLL.stop() end
        local state = { cursor = __custom_event_capture() }
        _G.BR_CUSTOM_POLL = { module = custom_listeners, stop = BR.event.tick(function() custom_poll(state) end) }
    end
    custom_listeners[#custom_listeners + 1] = l
    return function()
        for i, x in ipairs(custom_listeners) do if x == l then table.remove(custom_listeners, i) break end end
    end
end

--- Call fn(data, info) for every custom event named `name`, sent by any Send
--- Custom Event gate (built in game or by BR.event.custom). `data` holds its 8
--- values as Lua values (booleans, numbers, strings, vectors); `info` is
--- { name, target, sender }: `target` is the entity id a targeted event was sent
--- to (0 for a global one) and `sender` the sending gate's component handle
--- (8 zero bytes for one BR sent).
--- Runs on the game thread at the start of the next tick, once per event, with
--- no gates placed. Returns a function that stops it.
---
--- Without opts.entity it hears global events, like a global receiver gate.
--- opts.entity = an entity hears events targeted at that entity instead.
function event.on_custom(name, fn, opts)
    assert(type(name) == "string" and name ~= "", "a custom event needs a name")
    local entity = opts and opts.entity
    return custom_listen({ name = name, fn = fn, entity = entity })
end

--- Call fn(data, info) for every custom event of any name, global or targeted
--- (see BR.event.on_custom for the arguments). Returns a function that stops it.
function event.on_any_custom(fn)
    return custom_listen({ any = true, fn = fn })
end

-- Calls into the game: UE4SS's RegisterHook hands over reflected parameters only,
-- so a parameter like a BrickHandle arrives empty. BR.event.hook gets the raw bytes.

--- Run fn(self, params) before every call of the UFunction `path`
--- ("/Script/Brickadia.Class:Function"), on the game thread. `params` is the
--- parameter buffer as bytes (offsets from __fn_layout). Calls a client makes to
--- the server (RPCs) arrive this way too. Hooks last until the mod stops.
---
--- fn may return false to stop the call (the function doesn't run; for a
--- client's RPC, the server ignores the request), or a byte string to write over
--- the parameters, which later hooks and the function then see. Anything the
--- old bytes owned (an FString's buffer) is the hook's to free.
function event.hook(path, fn)
    __on_call(path, function(self, params)
        local ok, result = I.call("hook " .. path:match("[^.]*$"), fn, self, params)
        if not ok then
            I.report("BR.event.hook " .. path, result)
            return nil
        end
        if result == false or type(result) == "string" then return result end
        return nil
    end)
end

--- Run fn(self, params) after every call of the UFunction `path` that ran (a
--- call a BR.event.hook handler stopped doesn't count), on the game thread.
--- `params` are the parameter bytes as the call left them: the return value and
--- out parameters filled in, at the offsets __fn_layout(path) gives. fn may
--- return a byte string of the same size to replace them: the caller then reads
--- the new return value and out parameters (BR.event.result does the packing
--- for a plain return value). Returns a function that stops it.
---
--- Like BR.event.hook, it sees calls that go through ProcessEvent: client RPCs,
--- Blueprint calls, calls made from Lua. The game's C++ calling its own C++
--- (HasPermission, for one) never passes through.
---
---   BR.event.after("/Script/Brickadia.BRPlayerController:ServerPushChatMessage", function(pc)
---       -- the message has been handled: broadcast, or refused by the game
---   end)
function event.after(path, fn)
    local active = true
    __on_call_after(path, function(self, params)
        if not active then return end
        local ok, result = I.call("after " .. path:match("[^.]*$"), fn, self, params)
        if not ok then
            I.report("BR.event.after " .. path, result)
            return nil
        end
        if type(result) == "string" and #result == #params then return result end
        return nil
    end)
    return function() active = false end
end

--- `params` (as an after-hook gets them) with the call's return value replaced
--- by `bytes` (packed as the return type is: string.pack("<i4", n), "\1" for
--- true, BR.raw.ptr(obj)).
---
---   -- every player may interact with everything, whatever the game decided
---   BR.event.after(path, function(self, params) return BR.event.result(path, params, "\1") end)
function event.result(path, params, bytes)
    local r = assert(I.layout(path).ReturnValue, path .. " returns nothing")
    assert(#bytes <= r.size, "the return value is " .. r.size .. " bytes")
    return params:sub(1, r.offset) .. bytes .. params:sub(r.offset + #bytes + 1)
end

--- Call fn(params, layout) whenever `owner`'s multicast delegate `name` (a
--- reflected property such as a game mode's OnRoundStart) is broadcast, on the
--- game thread, as the game broadcasts it. `params` are the delegate's
--- parameter bytes and `layout` their offsets ({ size, <Param> = { offset, size } }).
--- The binding ends with the owner. Returns a function that removes it.
function event.delegate(owner, name, fn)
    local layout
    local id, signature = __delegate_bind(owner, name, function(params)
        local ok, err = pcall(fn, params, layout)
        if not ok then I.report("BR.event.delegate " .. name, err) end
    end)
    layout = __fn_layout(signature)
    return function() __delegate_unbind(id) end
end

--- fn(character, brick, nearby) whenever a character starts interacting with a
--- brick: BR.event.on("interact") with the character first.
function event.interact(fn)
    return BR.event.on("interact", function(_, info) fn(info.character, info.brick, info.nearby) end)
end

--- fn(character) when a character lets go (releases a held button).
function event.interact_end(fn)
    return BR.event.on("interact_end", function(_, info) fn(info.character) end)
end

--- Call fn(player, manager) when a player saves an avatar in the editor.
--- `manager` is their BRPlayerAvatarManagerComponent. fn returning false refuses
--- the save (team uniforms). Returns a function that stops it.
function event.avatar_change(fn)
    return BR.event.on("avatar", function(player, info) return fn(player, info.manager) end)
end

local function brick_at(params, offset)
    local h = params:sub(offset + 1, offset + 8)
    return BR.brick.valid(h) and h or nil
end

local function object_at(params, offset)
    local o = BR.raw.obj(params:sub(offset + 1, offset + 8))
    return o and o:IsValid() and o or nil
end

-- a TArray of object pointers in the parameters
local function objects_at(params, offset)
    local data, num = string.unpack("<I8i4", params, offset + 1)
    local out = {}
    for i = 0, num - 1 do
        local o = __obj(string.unpack("<I8", __peek(data + i * 8, 8)))
        if o and o:IsValid() then out[#out + 1] = o end
    end
    return out
end

local function fstring_at(params, offset) return BR.raw.fstring(params:sub(offset + 1, offset + 16)) end

local function name_of(o) return o and o:IsValid() and o:GetFName():ToString() or nil end

local function ivec_at(params, offset) return { string.unpack("<i4i4i4", params, offset + 1) } end

local function vec_at(params, offset) return { string.unpack("<ddd", params, offset + 1) } end

local function fname_at(params, offset)
    local s = BR.raw.fstring(BR.raw.call(StaticFindObject("/Script/Engine.Default__KismetStringLibrary"), "Engine.KismetStringLibrary",
        "Conv_NameToString", { InName = params:sub(offset + 1, offset + 8) }).ReturnValue)
    return s ~= "None" and s or nil
end

-- What a projectile stopped against. FHitResult names the actor only through a
-- weak handle Lua can't resolve, so a brick or entity is found by tracing a few
-- units into the surface, and a character from the bone it hit plus being the
-- nearest one to the point.
local function projectile_target(pos, normal, bone)
    if bone then
        local best, best_d
        for _, ch in ipairs(FindAllOf("BRCharacter") or {}) do
            if ch:IsValid() then
                local l = ch:K2_GetActorLocation()
                local d = (l.X - pos[1]) ^ 2 + (l.Y - pos[2]) ^ 2 + (l.Z - pos[3]) ^ 2
                if not best_d or d < best_d then best, best_d = ch, d end
            end
        end
        if best and best_d < 300 ^ 2 then return { character = best, player = BR.player.of(best) } end
    end
    local from = { pos[1] + normal[1] * 4, pos[2] + normal[2] * 4, pos[3] + normal[3] * 4 }
    local hit = BR.world.raycast(from, { -normal[1], -normal[2], -normal[3] }, { distance = 12 })
    if hit and hit.brick then return { brick = hit.brick } end
    if hit and hit.entity then return { entity = hit.entity } end
    return {}
end

-- event -> list of { UFunction path, decode(self, params) -> player, info }
-- A parameter's byte offset in a call, or a field's inside a struct parameter,
-- found by name on first use and kept: the decoders below read raw parameter
-- bytes, and names (unlike numbers) survive a game update that moves things.
local offsets = {}
local function at(path, param, field)
    local key = path .. "." .. param .. "." .. (field or "")
    local v = offsets[key]
    if v then return v end
    local p = I.layout(path)[param]
    assert(p, path .. " has no parameter " .. param)
    v = p.offset
    if field then
        local fn = StaticFindObject(path)
        local struct
        fn:ForEachProperty(function(prop)
            if prop:GetFName():ToString() == param then struct = prop:GetStruct() end
        end)
        local f = assert(struct and I.find_field(struct, field), path .. "." .. param .. " has no field " .. field)
        v = v + f:GetOffset_Internal()
    end
    offsets[key] = v
    return v
end

local EVENTS = {
    -- the game mode's own delegates (see bind_delegate below): params are the
    -- delegate signature's parameter bytes
    join = { { delegate = "OnPlayerJoined", decode = function(p) return object_at(p, 0), {} end } },
    leave = { { delegate = "OnPlayerLeft", decode = function(p) return object_at(p, 0), {} end } },
    spawn = { { delegate = "OnRespawnPlayer", decode = function(p)
        local ps = object_at(p, 0)
        return ps, { character = ps and BR.player.character(ps) }
    end } },
    team = { { delegate = "OnPlayerSwitchTeam", decode = function(p)
        return object_at(p, 0), { old_team = object_at(p, 8), new_team = object_at(p, 16) }
    end } },
    respawn_lock = { { delegate = "OnPlayerCannotRespawnChanged", decode = function(p)
        return object_at(p, 0), { locked = p:byte(9) ~= 0 }
    end } },
    round_start = { { delegate = "OnRoundStart", decode = function(p) return nil, { round = (string.unpack("<i4", p)) } end } },
    round_end = { { delegate = "OnRoundEnd", decode = function(p)
        return object_at(p, 8), { round = (string.unpack("<i4", p)) }
    end } },
    -- Result: EBRRoundEndResult; Players and Teams: TArray of objects
    round_won = { { delegate = "OnRoundWon", decode = function(p)
        local results = { [0] = "player", [1] = "team", [2] = "draw", [3] = "mixed" }
        return nil, { result = results[p:byte(1)] or p:byte(1), players = objects_at(p, 8), teams = objects_at(p, 24) }
    end } },
    reset = { { delegate = "OnReset", decode = function() return nil, {} end } },
    session_start = { { delegate = "OnSessionStart", decode = function() return nil, {} end } },
    chat = { { SCRIPT .. "BRPlayerController:ServerPushChatMessage", function(self, p)
        return BR.player.of(self), { message = fstring_at(p, 0) }
    end } },
    typing = { { SCRIPT .. "BRPlayerController:ServerSetTyping", function(self, p)
        return BR.player.of(self), { typing = p:byte(at(SCRIPT .. "BRPlayerController:ServerSetTyping", "bTyping") + 1) ~= 0 }
    end } },
    death = { { SCRIPT .. "BRCharacter:MulticastHandleDeath", function(self, p)
        local fn = SCRIPT .. "BRCharacter:MulticastHandleDeath"
        local killer, cause = object_at(p, at(fn, "InstigatedBy")), object_at(p, at(fn, "DeathCauser"))
        return BR.player.of(self), {
            character = self, damage = (string.unpack("<f", p, at(fn, "FinalDamage") + 1)), killer = killer,
            damage_type = name_of(object_at(p, at(fn, "DeathType"))), cause = cause,
            -- a bot's kill names no killer controller; its projectile or weapon
            -- (the cause) still leads back to the bot
            killer_player = BR.player.of(killer) or BR.player.of(cause),
        }
    end } },
    -- Brickadia's damage doesn't go through the engine's ReceiveAnyDamage; every
    -- character that is hurt plays a pain sound for everyone, which carries the amount
    damage = { { SCRIPT .. "BRCharacter:MulticastPlayPainSound", function(self, p)
        return BR.player.of(self), { character = self, damage = (string.unpack("<f", p, at(SCRIPT .. "BRCharacter:MulticastPlayPainSound", "DamageTaken") + 1)) }
    end } },
    emote = { { SCRIPT .. "BRCharacter:ServerStartEmoting", function(self, p)
        return BR.player.of(self), { character = self, emote = name_of(object_at(p, at(SCRIPT .. "BRCharacter:ServerStartEmoting", "EmoteClass"))) }
    end } },
    emote_end = { { SCRIPT .. "BRCharacter:ServerStopEmoting", function(self)
        return BR.player.of(self), { character = self }
    end } },
    interact = { { SCRIPT .. "BRCharacter:ServerMaybeStartInteract", function(self, p)
        local fn = SCRIPT .. "BRCharacter:ServerMaybeStartInteract"
        return BR.player.of(self), { character = self, brick = brick_at(p, at(fn, "BrickHandle")), nearby = p:byte(at(fn, "bIsNearbyInteraction") + 1) ~= 0 }
    end } },
    interact_end = { { SCRIPT .. "BRCharacter:ServerStopAnyInteract", function(self)
        return BR.player.of(self), { character = self }
    end } },
    -- a melee weapon's hit as the attacking client reports it, in one event struct
    melee_hit = { { SCRIPT .. "BRWeaponBase:ServerApplyMeleePredictedDamage", function(self, p)
        local fn = SCRIPT .. "BRWeaponBase:ServerApplyMeleePredictedDamage"
        local function f(name) return at(fn, "Event", name) end
        local actor = object_at(p, f("HitActor"))
        local info = { weapon = name_of(self:GetClass()), position = vec_at(p, f("HitLocation")),
            damage = (string.unpack("<f", p, f("ClientDamage") + 1)),
            backstab = p:byte(f("bClientClaimsBackstab") + 1) ~= 0, actor = actor, brick = brick_at(p, f("HitBrick")) }
        if actor and actor:IsA(StaticFindObject(SCRIPT .. "BRCharacter")) then
            info.character, info.player = actor, BR.player.of(actor)
        end
        return BR.player.of(self), info
    end } },
    -- a player saving their avatar in the editor
    avatar = { { SCRIPT .. "BRPlayerAvatarManagerComponent:ServerUpdatePlayerAvatar", function(self)
        return BR.player.of(self), { manager = self }
    end } },
    -- a projectile stopping against something (the engine's hit result);
    -- bounces don't count
    projectile_hit = { { SCRIPT .. "BRWeaponProjectile:ProcessStop", function(self, p)
        local fn = SCRIPT .. "BRWeaponProjectile:ProcessStop"
        local function f(name) return at(fn, "ImpactResult", name) end
        local pos, normal, bone = vec_at(p, f("ImpactPoint")), vec_at(p, f("ImpactNormal")), fname_at(p, f("BoneName"))
        local info = { projectile = name_of(self:GetClass()), position = pos, normal = normal, bone = bone }
        for k, v in pairs(projectile_target(pos, normal, bone)) do info[k] = v end
        local by = self.InstigatorState
        return (by and by:IsValid()) and by or BR.player.of(self), info
    end } },
    shoot = { { SCRIPT .. "BRWeaponBase:MulticastReplicateAcceleratedProjectiles", function(self)
        return BR.player.of(self), { weapon = name_of(self:GetClass()) }
    end }, { SCRIPT .. "BRWeaponBase:MulticastReplicateAcceleratedProjectilesWithSeed", function(self)
        return BR.player.of(self), { weapon = name_of(self:GetClass()) }
    end } },
    place = {
        { SCRIPT .. "BRTool_Placer:ServerPlaceSimpleBrickVolume", function(self, p)
            local fn = SCRIPT .. "BRTool_Placer:ServerPlaceSimpleBrickVolume"
            -- FColor is stored B, G, R, A
            local c = at(fn, "ColorAndAlpha")
            local b, g, r, a = string.byte(p, c + 1, c + 4)
            return BR.player.of(self), { kind = "brick", position = ivec_at(p, at(fn, "Position")),
                orientation = p:byte(at(fn, "Orientation") + 1), color = { r, g, b, a } }
        end },
        { SCRIPT .. "BRTool_Placer:ServerPlaceSimpleEntityVolume", function(self, p)
            local fn = SCRIPT .. "BRTool_Placer:ServerPlaceSimpleEntityVolume"
            return BR.player.of(self), { kind = "entity", entity = name_of(object_at(p, at(fn, "EntityType"))), position = ivec_at(p, at(fn, "Position")) }
        end },
        { SCRIPT .. "BRTool_Placer:ServerPlaceCurrentPrefab", function(self, p)
            return BR.player.of(self), { kind = "prefab", position = ivec_at(p, at(SCRIPT .. "BRTool_Placer:ServerPlaceCurrentPrefab", "Position")) }
        end },
    },
    delete = {
        { SCRIPT .. "BRTool_Hammer:ServerHammerBrick", function(self, p)
            return BR.player.of(self), { kind = "hammer", brick = brick_at(p, at(SCRIPT .. "BRTool_Hammer:ServerHammerBrick", "BrickHandle")) }
        end },
        { SCRIPT .. "BRPlacerControlMode_Delete:ServerHammerBrick", function(self, p)
            return BR.player.of(self), { kind = "placer", brick = brick_at(p, at(SCRIPT .. "BRPlacerControlMode_Delete:ServerHammerBrick", "BrickHandle")) }
        end },
        { SCRIPT .. "BRTool_Selector:ServerDeleteSelection", function(self)
            return BR.player.of(self), { kind = "selection" }
        end },
    },
    change = {
        { SCRIPT .. "BRTool_Painter:ServerPaintBrick", function(self, p) return BR.player.of(self), { kind = "paint", brick = brick_at(p, at(SCRIPT .. "BRTool_Painter:ServerPaintBrick", "BrickHandle")) } end },
        { SCRIPT .. "BRTool_Painter:ServerFillPaint", function(self, p) return BR.player.of(self), { kind = "fill", brick = brick_at(p, at(SCRIPT .. "BRTool_Painter:ServerFillPaint", "BrickHandle")) } end },
        { SCRIPT .. "BRTool_Applicator:ServerApplyBrickState", function(self, p) return BR.player.of(self), { kind = "apply", brick = brick_at(p, at(SCRIPT .. "BRTool_Applicator:ServerApplyBrickState", "BrickHandle")) } end },
        { SCRIPT .. "BRTool_Applicator:ServerPasteBrick", function(self, p) return BR.player.of(self), { kind = "paste", brick = brick_at(p, at(SCRIPT .. "BRTool_Applicator:ServerPasteBrick", "BrickHandle")) } end },
        { SCRIPT .. "BRTool_Applicator:ServerResetBrickState", function(self, p) return BR.player.of(self), { kind = "reset", brick = brick_at(p, at(SCRIPT .. "BRTool_Applicator:ServerResetBrickState", "BrickHandle")) } end },
        { SCRIPT .. "BRTool_Applicator:ServerRemoveComponent", function(self, p) return BR.player.of(self), { kind = "remove_component", brick = brick_at(p, at(SCRIPT .. "BRTool_Applicator:ServerRemoveComponent", "BrickHandle")) } end },
        { SCRIPT .. "BRTool_Resizer:ServerApplyBrickTransform", function(self, p) return BR.player.of(self), { kind = "resize", brick = brick_at(p, at(SCRIPT .. "BRTool_Resizer:ServerApplyBrickTransform", "BrickHandle")) } end },
        { SCRIPT .. "BRTool_Resizer:ServerApplyBrickRotation", function(self, p) return BR.player.of(self), { kind = "rotate", brick = brick_at(p, at(SCRIPT .. "BRTool_Resizer:ServerApplyBrickRotation", "BrickHandle")) } end },
        { SCRIPT .. "BRTool_Resizer:ServerApplyBrickDirection", function(self, p) return BR.player.of(self), { kind = "direction", brick = brick_at(p, at(SCRIPT .. "BRTool_Resizer:ServerApplyBrickDirection", "BrickHandle")) } end },
    },
}

-- Movement states have no call to hook: crouching and sprinting arrive as flags
-- on every client move, walking is just velocity, and water and zones are where
-- a character is. These events come from polling each character instead.
-- event -> the BR.player.movement field it follows
local POLLED = { sprint = "sprinting", walk = "walking", crouch = "crouching", sit = "sitting", water = "in_water" }

-- The "key" event: the weapon keys a character's client last sent
-- (EBRWeaponInputKeys bits on PendingWeaponSimInputs), polled with the rest.
event.KEYS = { primary = 1, secondary = 2, reload = 4, inspect = 8, custom1 = 16, custom2 = 32, custom3 = 64, custom4 = 128 }

-- watched zones by handle: { zone = handle, fns = { fn, ... } } (BR.event.on_zone)
local zones = {}

-- seconds between polls: the delay before a polled event fires
local POLL_INTERVAL = 0.1

event.EVENTS = {}
for name in pairs(EVENTS) do event.EVENTS[#event.EVENTS + 1] = name end
for name in pairs(POLLED) do event.EVENTS[#event.EVENTS + 1] = name end
event.EVENTS[#event.EVENTS + 1] = "key"
event.EVENTS[#event.EVENTS + 1] = "equip"
event.EVENTS[#event.EVENTS + 1] = "seat"
table.sort(event.EVENTS)

-- Events that come from a client's request (an RPC the server is about to act
-- on) can be refused: a handler returning false stops the request.
for _, name in ipairs({ "chat", "typing", "emote", "interact", "melee_hit", "avatar", "place", "delete", "change" }) do
    for _, source in ipairs(EVENTS[name]) do source.block = true end
end

-- a chat handler returning a string sends that instead; the message is the
-- FString at the start of the parameters
EVENTS.chat[1].rewrite = function(params, message)
    if type(message) ~= "string" then return nil end
    local old = string.unpack("<I8", params)
    -- the engine frees the parameters' FString after the call, which is now ours
    if old ~= 0 then __game_free(old) end
    return BR.raw.new_fstring(message) .. params:sub(17)
end

-- Handlers and the hooks that feed them outlive a reload of this module: the
-- native hooks are installed once per Lua state and call SE.run, which each
-- load replaces with its own decoders. (Installing them per load leaked every
-- old copy of the module and ran each hooked call once more per reload.)
_G.BR_EVENT = _G.BR_EVENT or { handlers = {}, installed = {} }
local SE = _G.BR_EVENT
local handlers = SE.handlers

-- Runs every handler, newest first, even after one refuses, so all of them see
-- the event. Returns false if any handler returned false, else the last other
-- value a handler returned (a replacement, for events that take one).
local function dispatch(name, player, info)
    local list = handlers[name]
    local verdict
    for i = #list, 1, -1 do
        local ok, result = I.call("event " .. name, list[i], player, info)
        if not ok then
            I.report("BR.event.on " .. name, result)
        elseif result == false then
            verdict = false
        elseif result ~= nil and verdict ~= false then
            verdict = result
        end
    end
    return verdict
end

local function zone_dispatch(z, player, active, ch)
    for i = #z.fns, 1, -1 do
        local ok, err = pcall(z.fns[i], player, active, ch)
        if not ok then I.report("BR.event.on_zone", err) end
    end
end

-- PlayerState address -> { ch = character address, [field] = last value,
-- zones = { [handle] = true } }. Addresses, not objects, so a character that
-- died meanwhile is never touched.
local seen = {}

-- a character gone (death, respawn, leaving) ends the states it was in
local function forget(key, player)
    local last = seen[key]
    seen[key] = nil
    if not last or not (player and player:IsValid()) then return end
    for name, field in pairs(POLLED) do
        if last[field] and handlers[name] then dispatch(name, player, { active = false }) end
    end
    for h in pairs(last.zones) do
        if zones[h] then zone_dispatch(zones[h], player, false, nil) end
    end
end

-- a zone whose brick is gone lets everyone in it out, and is watched no more
local function drop_zone(h)
    local z = zones[h]
    zones[h] = nil
    I.game_state().PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if not ps:IsValid() then return end
        local last = seen[__addr(ps)]
        if last and last.zones[h] then
            last.zones[h] = nil
            zone_dispatch(z, ps, false, nil)
        end
    end)
end

local function poll()
    -- each zone's box once per poll, for every character
    local boxes = {}
    for h in pairs(zones) do
        local box = BR.zone.box(h)
        if box then boxes[h] = box else drop_zone(h) end
    end
    local present, living = {}, {}
    I.game_state().PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if not ps:IsValid() then return end
        local key = __addr(ps)
        present[key] = ps
        local ch = BR.player.character(ps)
        if not ch then return end
        living[key] = true
        local now = BR.player.movement(ch)
        local last = seen[key]
        if last and last.ch ~= __addr(ch) then
            forget(key, ps)
            last = nil
        end
        if not last then
            -- first sight: a fresh character standing still says nothing, one that
            -- appears already crouched or seated reports it
            last = { ch = __addr(ch), zones = {} }
            seen[key] = last
        end
        for h, box in pairs(boxes) do
            local inside = BR.zone.contains(h, ch, box)
            if inside ~= (last.zones[h] or false) then
                last.zones[h] = inside or nil
                zone_dispatch(zones[h], ps, inside, ch)
            end
        end
        -- stops before starts, so a sprint ending into a walk reads in order
        for _, active in ipairs({ false, true }) do
            for name, field in pairs(POLLED) do
                if now[field] == active and (last[field] or false) ~= active then
                    last[field] = active
                    if handlers[name] and #handlers[name] > 0 then
                        dispatch(name, ps, { character = ch, active = active, movement = now })
                    end
                end
            end
        end
        if handlers.equip and #handlers.equip > 0 then
            local ok, cls = pcall(function() return ch:GetItemClass() end)
            local item = ok and cls and cls:IsValid() and cls:GetFName():ToString() or false
            if last.item == nil then
                last.item = item
            elseif item ~= last.item then
                local previous = last.item
                last.item = item
                dispatch("equip", ps, { character = ch, item = item or nil, previous = previous or nil })
            end
        end
        if handlers.seat and #handlers.seat > 0 then
            local seat = BR.raw.call(ch, "BRCharacter", "GetSeatBrick", {}).ReturnValue
            local seated = BR.brick.valid(seat) and seat or false
            if last.seat == nil then
                last.seat = seated
            elseif seated ~= last.seat then
                local left = last.seat
                last.seat = seated
                dispatch("seat", ps, { character = ch, brick = seated or left, active = seated ~= false })
            end
        end
        if handlers.key and #handlers.key > 0 then
            local keys = ch.PendingWeaponSimInputs.Keys
            local was = last.keys or 0
            if keys ~= was then
                last.keys = keys
                for name, bit in pairs(event.KEYS) do
                    if (keys & bit) ~= (was & bit) then
                        dispatch("key", ps, { character = ch, key = name, down = (keys & bit) ~= 0 })
                    end
                end
            end
        end
    end)
    -- dead (still listed, no character) or gone (left: nobody to report to)
    for key in pairs(seen) do
        if not living[key] then forget(key, present[key]) end
    end
end

-- one poller per Lua state; a reloaded module stops the previous module's
local function start_polling()
    if _G.BR_MOVEMENT_POLL and _G.BR_MOVEMENT_POLL.module == seen then return end
    if _G.BR_MOVEMENT_POLL then _G.BR_MOVEMENT_POLL.stop() end
    local wait = 0
    _G.BR_MOVEMENT_POLL = { module = seen, stop = BR.event.tick(function(dt)
        wait = wait - dt
        if wait > 0 then return end
        wait = POLL_INTERVAL
        poll()
    end) }
end

-- Game mode delegates (OnPlayerJoined, OnRoundStart, ...): the bridge binds a
-- function to the game mode's delegate. A new world brings a new game mode, so
-- a timer moves the bindings over when the game mode changes. A mod's main.lua
-- runs before the first world loads, when there is no game mode yet; its
-- bindings wait for the timer to find one.
local delegates = {}

local function rebind(now)
    for _, x in ipairs(delegates) do
        if x.gm ~= __addr(now) then
            if x.id then __delegate_unbind(x.id) end
            x.gm, x.id = __addr(now), (__delegate_bind(now, x.name, x.fn))
        end
    end
end

local function bind_delegate(name, fn)
    delegates[#delegates + 1] = { name = name, fn = fn }
    local gm = single("BRGameModeBase")
    if gm then rebind(gm) end
    if #delegates == 1 then
        BR.timer.every(1, function()
            -- between worlds there is no game mode for a moment
            local now = single("BRGameModeBase")
            if now then rebind(now) end
        end)
    end
end

-- what an installed hook does, with this load's decoders and dispatch
function SE.run(event, i, self, params)
    if #(handlers[event] or {}) == 0 then return nil end
    local source = EVENTS[event][i]
    local player, info = source[2](self, params)
    local verdict = dispatch(event, player, info)
    if verdict == false then
        if source.block then return false end
        return nil
    end
    if verdict ~= nil and source.rewrite then return source.rewrite(params, verdict) end
    return nil
end

function SE.run_delegate(event, i, params)
    if #(handlers[event] or {}) == 0 then return end
    local player, info = EVENTS[event][i].decode(params)
    dispatch(event, player, info)
end

--- Call fn(player, info) when a player does `event` (BR.event.EVENTS lists them):
--- join, leave, spawn, team, respawn_lock, chat, typing, death, damage, emote,
--- emote_end, interact, interact_end, shoot, projectile_hit, melee_hit, avatar,
--- place, delete, change, the round events round_start, round_end, round_won,
--- reset and session_start (no player), and the polled states sprint, walk,
--- crouch, sit and water. `player` is their
--- PlayerState (bots included); `info` holds the event's details (docs/lua-api.md).
--- Handlers run on the game thread before the game handles the action, so a
--- brick being deleted can still be read. Movement states are polled instead
--- (see BR.event.on_sprint) and fire up to 0.1 s late. Returns a function that
--- stops it.
---
--- Events that are a player's request (chat, typing, emote, interact,
--- melee_hit, avatar, place, delete, change) can be refused: a handler returning
--- false stops it, and the server acts as if the request never came. A chat
--- handler can instead return a string, which is sent in place of the message.
--- Every handler still sees the event. The player's own client may have shown
--- the action already (its avatar, a brick preview), which the server's state
--- then corrects.
function event.on(event, fn)
    local polled = POLLED[event] ~= nil or event == "key" or event == "equip" or event == "seat"
    local sources = EVENTS[event]
    if not sources and not polled then error("no event " .. tostring(event) .. " (see BR.event.EVENTS)", 2) end
    handlers[event] = handlers[event] or {}
    if not SE.installed[event] then
        SE.installed[event] = true
        for i, source in ipairs(sources or {}) do
            if source.delegate then
                bind_delegate(source.delegate, function(params) return SE.run_delegate(event, i, params) end)
            else
                BR.event.hook(source[1], function(self, params) return SE.run(event, i, self, params) end)
            end
        end
    end
    if polled then start_polling() end
    table.insert(handlers[event], fn)
    return function()
        for i, f in ipairs(handlers[event]) do if f == fn then table.remove(handlers[event], i) break end end
    end
end

-- world lifecycle listeners, kept across reloads
_G.BR_LIFECYCLE = _G.BR_LIFECYCLE or { ready = {}, unload = {} }
_G.BR_LIFECYCLE.unload = _G.BR_LIFECYCLE.unload or {}
local LC = _G.BR_LIFECYCLE

local function call_all(list, what, ...)
    for _, fn in ipairs(list) do
        local ok, err = I.call(what, fn, ...)
        if not ok then I.report("BR.event." .. what, err) end
    end
end

local function watch_worlds()
    if LC.polling then return end
    LC.polling = true
    BR.timer.every(1, function()
        local gm = single("BRGameModeBase")
        local key = gm and I.alive(gm) and __addr(gm) or nil
        if key == LC.game_mode then return end
        if LC.game_mode then call_all(LC.unload, "on_unload") end
        LC.game_mode = key
        if key then call_all(LC.ready, "on_ready") end
    end, { now = true })
end

--- fn() once the world is ready (its game mode exists): at once if it is now,
--- and again after every world load. Checked once a second. Returns a
--- function that stops it.
function event.on_ready(fn)
    table.insert(LC.ready, fn)
    if LC.polling and LC.game_mode then
        BR.timer.next_tick(function() local ok, err = I.call("on_ready", fn) if not ok then I.report("BR.event.on_ready", err) end end)
    end
    watch_worlds()
    return function()
        for i, f in ipairs(LC.ready) do if f == fn then table.remove(LC.ready, i) break end end
    end
end

--- fn() when the world that was there is gone (a world load replaced it),
--- just before on_ready for the next. It comes after the fact: the engine
--- calls no script as a world is torn down, so state worth keeping belongs in
--- BR.store or BR.db as it changes, not saved here. Returns a function that
--- stops it.
function event.on_unload(fn)
    table.insert(LC.unload, fn)
    watch_worlds()
    return function()
        for i, f in ipairs(LC.unload) do if f == fn then table.remove(LC.unload, i) break end end
    end
end

--- fn(player, character) when a player's character spawns: joining, respawning,
--- or a bot appearing. It runs as the game finishes the spawn, so it is the
--- place to hand out a loadout or set health. Returns a function that stops it.
function event.on_spawn(fn)
    return BR.event.on("spawn", function(player, info) fn(player, info.character) end)
end

local function movement_event(name)
    return function(fn)
        return BR.event.on(name, function(player, info) fn(player, info.active, info.character) end)
    end
end

--- fn(player, active, character) when a player starts (active true) or stops
--- sprinting: sprint held while moving on the ground or flying (BR.player.movement).
--- `character` is nil when the stop comes from the character dying or leaving.
--- Polled, so it fires up to 0.1 s late. Returns a function that stops it.
event.on_sprint = movement_event("sprint")

--- fn(player, active, character) when a player starts or stops walking: moving on
--- the ground, neither sprinting nor crouching. Sprinting ends a walk and
--- stopping a sprint while still moving starts one. Like BR.event.on_sprint.
event.on_walk = movement_event("walk")

--- fn(player, active, character) when a player crouches or stands up. Like
--- BR.event.on_sprint.
event.on_crouch = movement_event("crouch")

--- fn(player, active, character) when a player sits down (in a seat brick or with
--- the Sit emote) or gets up. Like BR.event.on_sprint.
event.on_sit = movement_event("sit")

--- fn(player, active, character) when a player goes into water (the world's or a
--- water zone's) or comes out: BR.player.in_water. Like BR.event.on_sprint.
event.on_water = movement_event("water")

--- fn(player, active, character) when a player's character enters (active true)
--- or leaves a zone, a zone projector's BrickHandle (BR.zone). It goes by the
--- character's capsule touching the zone's box, as the game counts occupants,
--- whatever the zone's own detection settings say. Polled with the movement
--- states, so it fires up to 0.1 s late. Leaving by dying or disconnecting, or
--- the zone's brick being removed, comes with no `character`. Returns a
--- function that stops it.
function event.on_zone(zone, fn)
    if not BR.zone.is_zone(zone) then error("not a zone (a BrickHandle of a zone projector)", 2) end
    local z = zones[zone]
    if not z then
        z = { zone = zone, fns = {} }
        zones[zone] = z
    end
    table.insert(z.fns, fn)
    start_polling()
    return function()
        for i, f in ipairs(z.fns) do if f == fn then table.remove(z.fns, i) break end end
        -- nobody listening: forget who was inside, so a new listener starts afresh
        if #z.fns == 0 and zones[zone] == z then
            zones[zone] = nil
            for _, last in pairs(seen) do last.zones[zone] = nil end
        end
    end
end

return event

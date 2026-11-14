-- BR.world: The loaded world: game mode, grids, spawning actors, prefabs and traces.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local cdo, valid, single = I.cdo, I.valid, I.single
local world = {}

function world.game_mode() return valid(single("BRGameModeBase"), "the game mode") end

-- The BRLuau libraries want the UWorld itself as WorldContextObject (Place checks
-- IsA(UWorld) and then fetches its BRRegistry); an actor in that world makes them
-- fail. UE4SS's UObject:GetWorld() hands back a mis-wrapped object here, so the
-- world comes from the global grid's outer chain: grid -> PersistentLevel -> World.
function world.global_grid() return valid(single("GlobalBrickGridActor"), "the global brick grid") end

function world.context()
    local level = valid(BR.world.global_grid():GetOuter(), "the grid's level")
    return valid(level:GetOuter(), "the world")
end

--- Whether the world is loaded enough for the helpers (the global grid exists).
function world.ready()
    return single("GlobalBrickGridActor") ~= nil
end

--- Every dynamic brick grid entity in the world (destroyed ones left out).
function world.grids()
    local out = {}
    for _, g in ipairs(FindAllOf("BrickGridDynamicActor") or {}) do
        if I.alive(g) then out[#out + 1] = g end
    end
    return out
end

--- Spawn an actor of `class` (a UClass) in the game world, at the origin.
function world.spawn(class)
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local actor = GS:BeginDeferredActorSpawnFromClass(BR.world.context(), class, xf, 1, nil, 0)
    assert(actor and actor:IsValid(), "spawn failed")
    GS:FinishSpawningActor(actor, xf, 0)
    return actor
end

-- Weapon projectiles: short name ("RocketLauncher", from Projectile_RocketLauncher_C)
-- -> class, found once from the loaded class defaults
local projectile_classes

local function projectiles()
    if projectile_classes then return projectile_classes end
    projectile_classes = {}
    local base = StaticFindObject("/Script/Brickadia.BRWeaponProjectile")
    ForEachUObject(function(o)
        local name = o:GetFullName():match("Default__Projectile_(%S+)_C$")
        if name and o:IsA(base) then projectile_classes[name] = o:GetClass() end
    end)
    return projectile_classes
end

--- The projectiles BR.world.spawn_projectile takes, by name ("RocketLauncher",
--- "Pistol", "SeekerMissile", ...), sorted.
function world.projectile_types()
    local out = {}
    for name in pairs(projectiles()) do out[#out + 1] = name end
    table.sort(out)
    return out
end

--- Fire a weapon's projectile from `from` {x, y, z} along `dir` {x, y, z}, as if
--- someone had shot it: it flies, bounces, explodes and damages as the weapon's
--- would. `class` is a name from BR.world.projectile_types or a projectile class.
--- opts: speed and damage (multipliers, default 1), scale (of its simulation,
--- default 1), instigator (a PlayerState the damage and kills count for).
---
--- A weapon's projectiles normally reach clients through the weapon's own
--- messages; this one has no weapon, so it is spawned as a replicated actor
--- instead, as the Projectile Spawner brick's are. Returns the projectile actor.
function world.spawn_projectile(class, from, dir, opts)
    opts = opts or {}
    if type(class) == "string" then
        local name = class:gsub("^Projectile_", ""):gsub("_C$", "")
        class = projectiles()[name]
        if not class then error("no projectile " .. name .. " (BR.world.projectile_types lists them)", 2) end
    end
    local dx, dy, dz = dir[1], dir[2], dir[3]
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len == 0 then error("a projectile needs a direction", 2) end
    dx, dy, dz = dx / len, dy / len, dz / len
    local at = { X = from[1], Y = from[2], Z = from[3] }
    local xf = { Rotation = BR.math.vec(dx, dy, dz):quat():ue(), Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    -- deferred, so the spawn fields are in place when it starts moving
    local p = GS:BeginDeferredActorSpawnFromClass(BR.world.context(), class, xf, 1, nil, 0)
    if not I.alive(p) then error("the projectile didn't spawn", 2) end
    p.ReplicationMode = 2 -- EBRWeaponProjectileReplicationMode.ReplicatedActor
    p:SetReplicates(true)
    p.InitialLocation = at
    p.SpawnDirection = { X = dx, Y = dy, Z = dz }
    p.SpawnSpeedMultiplier = opts.speed or 1
    p.DamageMultiplier = opts.damage or 1
    p.SpawnSimulationScale = opts.scale or 1
    if opts.instigator then
        p.InstigatorState = opts.instigator
        local pc = BR.player.controller(opts.instigator)
        if pc then p.InstigatorController = pc end
    end
    GS:FinishSpawningActor(p, xf, 0)
    return p
end

--- Teleport an actor (bot, entity) to a world location in UE units.
function world.teleport(actor, x, y, z)
    -- BR.guard's teleport signal leaves moves made here alone
    if _G.BR_GUARD then _G.BR_GUARD.moved[__addr(actor)] = _G.BR_GUARD.clock end
    return actor:K2_TeleportTo({ X = x, Y = y, Z = z }, actor:K2_GetActorRotation())
end

--- Load a prefab bundle into the live world, added to what's there: bricks,
--- components, wires and entities in one synchronous load (10,000 bricks in
--- ~20 ms, against ~70 ms per brick for a fresh builder). `name` is a bundle
--- ref under Saved/Prefabs without ".brz" ("ttt/map", or "Prefabs/Uploads/<hash>.brz"
--- for an uploaded one). The prefab's bounds corner lands at (x, y, z), in world
--- units. Owners come from the file. Returns the brick count added; bricks that
--- would overlap existing ones are skipped (and logged by the game).
function world.load_prefab(name, x, y, z, orientation)
    assert(type(name) == "string" and not name:find('["\r\n]'), "bad prefab name")
    local before = BR.brick.count()
    BR.server.console(string.format('br.Prefab.Load "%s" %d %d %d 0 %d', name, math.floor(x or 0), math.floor(y or 0), math.floor(z or 0),
        orientation or BR.brick.Z_UP))
    return BR.brick.count() - before
end

-- Traces. Channels are EBRLuauTraceChannel (what the ray collides as) and targets
-- EBRLuauTraceTargets bits (what it may hit).

world.TRACE_CHANNEL = {
    Brick = 1, BrickComponent = 2, BrickInteractive = 3, BrickJoint = 4, BrickTouch = 5, Interaction = 6,
    Player1 = 7, Player2 = 8, Player3 = 9, Player4 = 10, Projectile = 11, RadialDamage = 12, Tool = 13,
    Visibility = 14, Weather = 15,
}

world.TRACE_TARGETS = {
    Brick = 1, PhysicsBody = 2, Pickup = 4, Player1 = 8, Player2 = 16, Player3 = 32, Player4 = 64,
    Projectile = 128, Water = 256, WorldDynamic = 512, WorldStatic = 1024, All = 2047,
}

-- BRLuauTraceHit: Entity (UObject*) +0, Brick (BrickHandle) +8, Position +0x10,
-- Normal +0x28 (FVector, doubles), Distance +0x40
local function trace_hit(bytes)
    local entity = BR.raw.obj(bytes:sub(1, 8))
    local brick = bytes:sub(9, 16)
    local px, py, pz = string.unpack("<ddd", bytes, 0x10 + 1)
    local nx, ny, nz = string.unpack("<ddd", bytes, 0x28 + 1)
    return {
        position = { px, py, pz },
        normal = { nx, ny, nz },
        distance = (string.unpack("<d", bytes, 0x40 + 1)),
        brick = BR.brick.valid(brick) and brick or nil,
        entity = entity and entity:IsValid() and entity or nil,
    }
end

local function trace_opts(opts)
    opts = opts or {}
    local channel = opts.channel or "Visibility"
    local targets = opts.targets or "All"
    if type(channel) == "string" then channel = assert(BR.world.TRACE_CHANNEL[channel], "no trace channel " .. channel) end
    if type(targets) == "string" then targets = assert(BR.world.TRACE_TARGETS[targets], "no trace targets " .. targets) end
    return channel, targets, opts.distance or 100000, opts.complex and "\1" or "\0"
end

--- Cast a ray from `origin` along `direction` ({x, y, z}, world units; the
--- direction need not be normalised). opts: distance (default 100000), channel
--- and targets (names from BR.world.TRACE_CHANNEL / BR.world.TRACE_TARGETS or numbers;
--- default Visibility / All), complex. Returns nil for no hit, or { position,
--- normal, distance, brick = handle or nil, entity = actor or nil }.
function world.raycast(origin, direction, opts)
    local channel, targets, distance, complex = trace_opts(opts)
    local r = BR.raw.call(cdo("BRLuauWorldLibrary"), "BRLuauWorldLibrary", "Raycast", {
        Origin = string.pack("<ddd", origin[1], origin[2], origin[3]),
        Direction = string.pack("<ddd", direction[1], direction[2], direction[3]),
        WorldContextObject = BR.raw.ptr(BR.world.context()),
        MaxDistance = string.pack("<d", distance),
        Channel = string.pack("B", channel),
        Targets = string.pack("<I4", targets),
        bComplex = complex,
    })
    if not BR.raw.bool(r.ReturnValue) then return nil end
    return trace_hit(r.OutHit)
end

--- Like BR.world.raycast with a sphere of `radius` swept along the ray.
function world.sweep(origin, direction, radius, opts)
    local channel, targets, distance, complex = trace_opts(opts)
    local r = BR.raw.call(cdo("BRLuauWorldLibrary"), "BRLuauWorldLibrary", "Sweep", {
        Origin = string.pack("<ddd", origin[1], origin[2], origin[3]),
        Direction = string.pack("<ddd", direction[1], direction[2], direction[3]),
        Radius = string.pack("<d", radius),
        WorldContextObject = BR.raw.ptr(BR.world.context()),
        MaxDistance = string.pack("<d", distance),
        Channel = string.pack("B", channel),
        Targets = string.pack("<I4", targets),
        bComplex = complex,
    })
    if not BR.raw.bool(r.ReturnValue) then return nil end
    return trace_hit(r.OutHit)
end

-- BRLuauOverlap: Entity (AActor*) +0, Grid (ABrickGridActor*) +8; an actor
-- touching through several components appears once per component
local OVERLAP_SIZE = 0x10

local function overlaps(array)
    local data, num = string.unpack("<I8i4", array)
    local out, seen = {}, {}
    for i = 0, num - 1 do
        local e, g = string.unpack("<I8I8", __peek(data + i * OVERLAP_SIZE, OVERLAP_SIZE))
        local key = e ~= 0 and e or g
        if key ~= 0 and not seen[key] then
            seen[key] = true
            local actor = __obj(key)
            if actor and actor:IsValid() then
                out[#out + 1] = { actor = actor, grid = g ~= 0 and __obj(g) or nil }
            end
        end
    end
    if data ~= 0 then __game_free(data) end
    return out
end

--- Actors overlapping a sphere: characters, entities and brick grids (the
--- global grid whenever bricks are near), once each, as { actor, grid }, where
--- grid is set when the actor is a grid. opts: channel, targets, complex as
--- for BR.world.raycast. BR.player.of(actor) finds a character's player.
function world.overlap_sphere(center, radius, opts)
    local channel, targets, _, complex = trace_opts(opts)
    local r = BR.raw.call(cdo("BRLuauWorldLibrary"), "BRLuauWorldLibrary", "OverlapSphere", {
        Center = string.pack("<ddd", center[1], center[2], center[3]),
        Radius = string.pack("<d", radius),
        WorldContextObject = BR.raw.ptr(BR.world.context()),
        Channel = string.pack("B", channel),
        Targets = string.pack("<I4", targets),
        bComplex = complex,
    })
    return overlaps(r.ReturnValue)
end

--- Like BR.world.overlap_sphere for a box of half size `extent` ({x, y, z}).
function world.overlap_box(center, extent, opts)
    local channel, targets, _, complex = trace_opts(opts)
    local r = BR.raw.call(cdo("BRLuauWorldLibrary"), "BRLuauWorldLibrary", "OverlapBox", {
        Center = string.pack("<ddd", center[1], center[2], center[3]),
        Extent = string.pack("<ddd", extent[1], extent[2], extent[3]),
        WorldContextObject = BR.raw.ptr(BR.world.context()),
        Channel = string.pack("B", channel),
        Targets = string.pack("<I4", targets),
        bComplex = complex,
    })
    return overlaps(r.ReturnValue)
end

--- PlayerStates (bots included) whose living character is within `radius` of
--- `center`, nearest first, as { player, character, distance }.
function world.players_near(center, radius)
    local out = {}
    I.game_state().PlayerArray:ForEach(function(_, p)
        local ps = p:get()
        if not ps:IsValid() then return end
        local ch = BR.player.character(ps)
        if not ch then return end
        local l = ch:K2_GetActorLocation()
        local dx, dy, dz = l.X - center[1], l.Y - center[2], l.Z - center[3]
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d <= radius then out[#out + 1] = { player = ps, character = ch, distance = d } end
    end)
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end

-- Explosions. Explode wants an explosion class's full path; they are found by
-- name once (every subclass of BRWeaponExplosion: the weapons' explosions and
-- the generic impact effects).
local explosion_paths

local function explosions()
    if explosion_paths then return explosion_paths end
    local base = StaticFindObject("/Script/Brickadia.BRWeaponExplosion")
    local class = StaticFindObject("/Script/CoreUObject.Class")
    explosion_paths = {}
    ForEachUObject(function(o)
        if o:IsA(class) and o:IsChildOf(base) and o ~= base then
            -- the full name is "<Class type> <path>"
            local name, path = o:GetFName():ToString(), o:GetFullName():match("^%S+ (.*)$")
            explosion_paths[(name:gsub("_C$", ""))] = path
        end
    end)
    return explosion_paths
end

--- The explosion kinds BR.world.explode takes, sorted ("BP_Rocket_Explosion",
--- "BP_Dynamite_Explosion", "Explosion_Shotgun", ...).
function world.explosion_kinds()
    local out = {}
    for name in pairs(explosions()) do out[#out + 1] = name end
    table.sort(out)
    return out
end

--- Set off an explosion at `position` ({x, y, z}): its effect, sound and
--- damage, as the weapon's would. opts: kind (default "BP_Rocket_Explosion"),
--- normal ({x, y, z}, the surface it faces; default up), scale (default 1),
--- damage (a multiplier, default 1; 0 for show only), projectiles (whether it
--- throws its shrapnel). Returns whether the game set it off.
function world.explode(position, opts)
    opts = opts or {}
    local kind = opts.kind or "BP_Rocket_Explosion"
    local path = explosions()[kind] or error("no explosion " .. tostring(kind) .. " (BR.world.explosion_kinds lists them)", 2)
    local n, sc = opts.normal or { 0, 0, 1 }, opts.scale or 1
    local r = BR.raw.call(cdo("BRLuauWorldLibrary"), "BRLuauWorldLibrary", "Explode", {
        WorldContextObject = BR.raw.ptr(world.context()),
        ExplosionClass = BR.raw.new_fstring(path),
        Location = string.pack("<ddd", position[1], position[2], position[3]),
        Normal = string.pack("<ddd", n[1], n[2], n[3]),
        Scale = string.pack("<ddd", sc, sc, sc),
        DamageMultiplier = string.pack("<d", opts.damage or 1),
        bSpawnProjectiles = opts.projectiles and "\1" or "\0",
    })
    return BR.raw.bool(r.ReturnValue)
end

-- Game-wide rules: the game mode's own rules (Rounds, TimeLimit, AutoSort,
-- EndIfTeamsWiped...), BRGameModeRule_<Kind> objects on the game state, which
-- work like team rules (BR.team.rule): setters take effect at once and
-- replicate, and additions last until the game mode is reset or reloaded. The
-- same container takes team rule kinds too (HealthRegeneration, KeepInventory,
-- EnhancedBrickadians...), which then apply to every player whatever their team.

local GAME_RULE, TEAM_RULE = "BRGameModeRule_", "BRGameModeTeamRule_"
local function rule_container() return I.game_state().GameRuleContainer end

local function prefix_of(kind)
    for _, k in ipairs(I.rule_container.kinds(GAME_RULE)) do
        if k == kind then return GAME_RULE end
    end
    return TEAM_RULE
end

--- The kinds of game-wide rule this build has, sorted. Team rule kinds
--- (BR.team.rule_kinds) are accepted as well.
function world.rule_kinds() return I.rule_container.kinds(GAME_RULE) end

--- The game-wide rules as { kind, rule }, team rule kinds included.
function world.rules()
    local out = I.rule_container.list(rule_container(), GAME_RULE)
    for _, r in ipairs(out) do r.kind = r.kind:gsub("^" .. TEAM_RULE, "") end
    return out
end

--- The game-wide rule of `kind`, added if there is none unless `create` is false:
---   BR.world.rule("Rounds"):SetShowRoundNumber(true)
---   BR.world.rule("EnhancedBrickadians"):SetJumpMultiplier(2)  -- everyone
function world.rule(kind, create) return I.rule_container.get(rule_container(), prefix_of(kind), kind, create) end

--- Remove a game-wide rule: a kind, or a rule object.
function world.remove_rule(r)
    if type(r) == "string" then r = world.rule(r, false) end
    if r then rule_container():RemoveRule(r) end
end

-- Rounds, through the game mode's own functions. Ending or starting a round
-- runs the game mode's rules (respawns, score resets, win screens), as the
-- game mode editor's buttons do.

--- The current round number (from 1).
function world.round() return world.game_mode():GetCurrentRound() end

--- Whether the game mode's session is running.
function world.session_running() return world.game_mode():GetSessionIsRunning() == true end

--- End this round and start the next; `immediate` skips the end-of-round pause.
function world.next_round(immediate) world.game_mode():NextRound(immediate and true or false) end

--- End the round as a win for players and/or teams ({ ps, ... }, { team, ... }).
function world.win(players, teams)
    world.game_mode():WinPlayersAndTeams(players or {}, teams or {})
end

--- End the round as a draw.
function world.draw() world.game_mode():FinishRoundWithDraw() end

--- Put the game mode back to its first round, as at server start.
function world.reset_game_mode() world.game_mode():ResetGameMode() end

return world

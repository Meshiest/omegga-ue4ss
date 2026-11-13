-- BR.act: Things a player does, by their own hand: a bot or a real player alike.
-- Every action takes the player's PlayerState and goes through the same server
-- function the game client calls, so the game applies its own rules: the
-- player's permissions (a game mode team can take building away), trust,
-- quotas, brick ownership. Builder tools need no wielding.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local decode_report, offset, single = I.decode_report, I.offset, I.single
local act = {}

--- Emotes, for BR.act.emote: each is the name of an emote Blueprint.
act.EMOTE = {
    Beckon = "BP_Emote_Beckon", Clap = "BP_Emote_Clap", Dab = "BP_Emote_Dab", Facepalm = "BP_Emote_Facepalm",
    HatBow = "BP_Emote_Hat_Bow", Hug = "BP_Emote_Hug", Nod = "BP_Emote_Nod", Point = "BP_Emote_Point",
    ShakeHead = "BP_Emote_ShakeHead", Shrug = "BP_Emote_Shrug", Sit = "BP_Emote_Sit", Think = "BP_Emote_Think",
    TipHat = "BP_Emote_Tip_Hat", Wave = "BP_Emote_Wave",
}

local EMOTE_DIR = "/Game/Pawns/FigureV2/Model/Animations/Emotes/"

local function controller(ps)
    local pc = BR.player.controller(ps)
    if not pc then error("the player has no controller", 3) end
    return pc
end

local function character(ps)
    local ch = BR.player.character(ps)
    if not ch then error("the player has no living character", 3) end
    return ch
end

-- the player's own instance of a builder tool (BRTool_Placer, BRTool_Hammer, ...)
local function tool(ps, kind)
    if kind == "Placer" then return ps.PlacerTool end
    local pc = controller(ps)
    for _, t in ipairs(FindAllOf("BRTool_" .. kind) or {}) do
        if t:IsValid() then
            local owner = t:GetOwnerController()
            if owner and owner:IsValid() and __addr(owner) == __addr(pc) then return t end
        end
    end
    error("the player has no " .. kind, 3)
end

-- Run a tool's server function and return the transaction report it left on
-- the player's transaction manager. The counters are cleared first: a refused
-- action (no permission, no trust, a bad argument) runs no transaction, and
-- would otherwise hand back the previous action's report.
local function run(ps, kind, fn, args)
    local tm = controller(ps).BrickTransactionManager
    local at = __addr(tm) + offset(tm, "LastTransactionReport")
    __poke(at, string.rep("\0", I.REPORT_COUNTERS_SIZE))
    BR.raw.call(tool(ps, kind), "BRTool_" .. kind, fn, args)
    return decode_report(__peek(at, I.REPORT_COUNTERS_SIZE + 0x10))
end

-- BMC_* collections in the game instance's list, by BR.brick.MATERIAL name
local MATERIAL_ASSET = {
    Plastic = "BMC_Plastic", Glass = "BMC_Glass", TranslucentPlastic = "BMC_TranslucentPlastic",
    Glow = "BMC_Glow", Metal = "BMC_Metallic", Hologram = "BMC_Hologram",
}

-- The tools name a material by its index in UBRGameInstance.BrickMaterials,
-- which also holds the hidden and ghost materials the tools refuse.
local function material_index(name)
    local asset = MATERIAL_ASSET[name or "Plastic"]
    if not asset then error("no material " .. tostring(name), 3) end
    local found
    single("BRGameInstance").BrickMaterials:ForEach(function(i, m)
        if m:get():GetFName():ToString() == asset then found = i - 1; return true end
    end)
    if not found then error("the game has no " .. asset, 3) end
    return found
end

-- FColor is stored B, G, R, A
local function color_bytes(c, alpha)
    c = c or { 255, 255, 255 }
    return string.pack("BBBB", c[3], c[2], c[1], alpha)
end

-- BRPlacementContext onto the world grid: type ExistingBrickGrid, the grid
-- component, an identity transform (FTransform: rotation, translation,
-- scale, each 4 doubles) and no joint brick
local function world_grid_context()
    local grid = BR.world.global_grid().BrickGridComponent
    return string.pack("<B", 0) .. string.rep("\0", 7) .. BR.raw.ptr(grid)
        .. string.pack("<dddd", 0, 0, 0, 1) .. string.pack("<dddd", 0, 0, 0, 0) .. string.pack("<dddd", 1, 1, 1, 0)
        .. string.rep("\0", 8)
end

--- Place bricks with the player's Placer. opts: position {x, y, z} (grid units,
--- the brick's center), asset (default "PB_DefaultBrick"), size {x, y, z}
--- (half extents; procedural bricks only), orientation (default BR.brick.Z_UP),
--- color {r, g, b}, material (a BR.brick.MATERIAL name, default "Plastic"),
--- alpha (material alpha, default 5), count {x, y, z} (a volume: the game lays
--- out ceil(count / 2) copies along each axis, as the placer's drag sends it;
--- default one), spacing {x, y, z} (extra gap between copies), signs {x, y, z}
--- (1 or -1: which way the copies go from position, default +). Returns the
--- transaction report; it is all zeros when the game refused.
function act.place(ps, opts)
    if not opts.position then error("opts.position is required", 2) end
    local x, y, z = table.unpack(opts.position)
    local size = opts.size or { 0, 0, 0 }
    local count = opts.count or { 1, 1, 1 }
    return run(ps, "Placer", "ServerPlaceSimpleBrickVolume", {
        Context = world_grid_context(),
        BrickType = BR.raw.ptr(BR.brick.asset(opts.asset or "PB_DefaultBrick")) .. BR.raw.ivec(table.unpack(size)),
        ColorAndAlpha = color_bytes(opts.color, opts.alpha or 5),
        MaterialIndex = string.pack("<i4", material_index(opts.material)),
        Position = BR.raw.ivec(x, y, z),
        JointStartPosition = string.pack("<ddd", x, y, z),
        Orientation = string.char(opts.orientation or BR.brick.Z_UP),
        InstanceSize = BR.raw.ivec(table.unpack(size)),
        InstanceSpacing = BR.raw.ivec(table.unpack(opts.spacing or { 0, 0, 0 })),
        VolumeSize = BR.raw.ivec(table.unpack(count)),
        VolumeSigns = BR.raw.ivec(table.unpack(opts.signs or { 1, 1, 1 })),
        bMirrorMode = "\0",
    })
end

--- Paste a cached prefab (opts.prefab, a hash from BR.prefab.cached) with the
--- player's Placer, as a client's paste does. opts: position {x, y, z} (grid
--- units), orientation (default BR.brick.Z_UP), count {x, y, z} and spacing as
--- for act.place, preserve_ownership. Returns the transaction report.
---
--- The placer pastes what it holds as its current placeable, which a client
--- sets by holding the prefab; this sets it, and sends the copy size a client
--- would (half the prefab's size). The game allows a player only so many pastes
--- in a short time (BR.Permission.Prefabs.BypassTimeout lifts that); a paste
--- refused for that leaves an empty report.
function act.place_prefab(ps, opts)
    if not opts.position then error("opts.position is required", 2) end
    local hash = opts.prefab
    if type(hash) ~= "string" then error("opts.prefab is a cached prefab's hash (BR.prefab.cached)", 2) end
    local info = BR.prefab.info(hash)
    if not info then error("no cached prefab " .. hash, 2) end
    local placer = ps.PlacerTool
    assert(placer and placer:IsValid(), "the player has no Placer")
    local at = I.find_field(placer:GetClass(), "CurrentPlaceable"):GetOffset_Internal()
    __poke(__addr(placer) + at, BR.prefab.placeable(hash))
    local x, y, z = table.unpack(opts.position)
    local s = info.size
    local half = { math.max(1, s[1] // 2), math.max(1, s[2] // 2), math.max(1, s[3] // 2) }
    local report
    -- like the inventory calls, the paste acts on the controller's pawn
    I.as_controller(ps, function()
        report = run(ps, "Placer", "ServerPlaceCurrentPrefab", {
            Context = world_grid_context(),
            Position = BR.raw.ivec(x, y, z),
            JointStartPosition = string.pack("<ddd", x, y, z),
            Orientation = string.char(opts.orientation or BR.brick.Z_UP),
            InstanceSize = BR.raw.ivec(table.unpack(half)),
            InstanceSpacing = BR.raw.ivec(table.unpack(opts.spacing or { 0, 0, 0 })),
            VolumeSize = BR.raw.ivec(table.unpack(opts.count or { 1, 1, 1 })),
            VolumeSigns = BR.raw.ivec(1, 1, 1),
            bPreserveOwnership = opts.preserve_ownership and "\1" or "\0",
        })
    end)
    return report
end

--- Delete a brick with the player's Hammer. Returns the transaction report.
function act.hammer(ps, brick)
    return run(ps, "Hammer", "ServerHammerBrick", { BrickHandle = brick })
end

local strokes = 0
--- Paint a brick with the player's Painter. opts: color {r, g, b}, material (a
--- BR.brick.MATERIAL name), alpha (default 5); only what is given changes.
--- Returns the transaction report.
function act.paint(ps, brick, opts)
    strokes = strokes + 1
    local state = color_bytes(opts.color, 255) .. string.pack("<i4", material_index(opts.material))
        .. string.pack("B", opts.alpha or 5) .. "\0\0\0"
    return run(ps, "Painter", "ServerPaintBrick", {
        BrickHandle = brick, ClientColorSelectionState = state, ClientStrokeIndex = string.pack("<i4", strokes),
        bMergePaintStrokes = "\0",
        bPaintColor = opts.color and "\1" or "\0",
        bPaintMaterial = (opts.material or opts.alpha) and "\1" or "\0",
    })
end

--- Show or hide a brick with the player's Applicator. Returns the transaction
--- report.
function act.set_visible(ps, brick, visible)
    return run(ps, "Applicator", "ServerSetVisible", { BrickHandle = brick, bVisible = visible and "\1" or "\0" })
end

--- Set which collision channels a brick blocks (BR.brick.ALL_COLLISION, or 0 for
--- none) with the player's Applicator. Returns the transaction report.
function act.set_collision(ps, brick, channels)
    return run(ps, "Applicator", "ServerSetCollisionChannels", { BrickHandle = brick, CollisionChannels = string.char(channels) })
end

local function port_ref(p)
    local c = BR.component.handle(p.brick, p.type)
    if not c then error("the brick has no " .. tostring(p.type), 3) end
    return c .. string.pack("<I4I4", __fname(p.port), 0)
end

--- Connect an output port to an input port with the player's Connector, or
--- disconnect them if that wire already exists (the tool's own click). `from`
--- and `to` are { brick = handle, type = component type, port = port name },
--- e.g. { brick = h, type = "BrickComponentType_Expr_LogicalAND", port = "bOutput" }.
--- Returns the transaction report (WiresConnected or WiresDisconnected).
function act.wire(ps, from, to)
    return run(ps, "Connector", "ServerConnectOrDisconnectComponentWire", {
        SourcePortRef = port_ref(from), TargetPortRef = port_ref(to),
    })
end

--- Play an emote (a BR.act.EMOTE value) on the player's character, as the emote
--- wheel does; it plays until it ends, the player moves, or BR.act.stop_emote.
function act.emote(ps, emote)
    local path = EMOTE_DIR .. emote .. "." .. emote .. "_C"
    local cls = StaticFindObject(path)
    if not (cls and cls:IsValid()) then
        LoadAsset(path)
        cls = StaticFindObject(path)
    end
    if not (cls and cls:IsValid()) then error("no emote " .. tostring(emote), 2) end
    character(ps):ServerStartEmoting(cls)
end

function act.stop_emote(ps)
    local ch = character(ps)
    ch:ServerStopEmoting()
    -- an emote stays active until the owning client's animation reports it
    -- finished, which a bot never does, so the server is told directly
    local active = {}
    ch.ActiveEmotes:ForEach(function(_, e)
        local c = e:get()
        if c:IsValid() then active[#active + 1] = c end
    end)
    for _, c in ipairs(active) do ch:ServerFinishEmote(c) end
end

--- Say `message` in chat as the player: everyone sees it under the player's
--- name, and it goes through the game's chat handling (commands, BR.event.on("chat")).
function act.say(ps, message)
    controller(ps):ServerPushChatMessage(message)
end

--- Interact with a brick as if the player clicked it (a button stays held until
--- BR.act.stop_interact). `nearby` = false for a click from a distance.
function act.interact(ps, brick, nearby)
    if not BR.brick.valid(brick) then error("invalid brick handle", 2) end
    BR.raw.call(character(ps), "BRCharacter", "ServerMaybeStartInteract", {
        BrickHandle = brick, AnimType = "\0", bIsNearbyInteraction = nearby == false and "\0" or "\1",
    })
end

function act.stop_interact(ps)
    character(ps):ServerStopAnyInteract()
end

return act

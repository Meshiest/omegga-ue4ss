-- BR.prefab: Prefabs as the game keeps them, and what a player holds: hotbar
-- slots and the template (the slot the placer builds from, which a copy or a
-- brick picked from the catalog fills).
--
-- A prefab is known by its hash. The server caches every prefab it has seen (a
-- player's copy, a file it loaded, one given out), with the hash and the
-- metadata a placer needs; BR.prefab.cached() lists that cache. Files live under
-- Saved/Prefabs as <path>.brz.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local prefab = {}

local CONTROLLER = "/Script/Brickadia.BRPlayerController"

-- FBRInventoryEntryTemplate's fields, from reflection: the struct has an
-- unreflected tail, so it is built as bytes and sent with a raw call.
local tpl
local function template_layout()
    if tpl then return tpl end
    local function walk(path, base, out, prefix)
        StaticFindObject(path):ForEachProperty(function(p)
            local name = prefix .. p:GetFName():ToString()
            out[name] = base + p:GetOffset_Internal()
            if p:GetClass():GetFName():ToString() == "StructProperty" and not name:find("PrefabInfo%.") then
                walk(p:GetStruct():GetFullName():match(" (.*)"), out[name], out, name .. ".")
            end
        end)
        return out
    end
    local off = walk("/Script/Brickadia.BRInventoryEntryTemplate", 0, {}, "")
    local size = I.layout(CONTROLLER .. ":ServerSetInventoryTempSlot").Template.size
    local info = I.layout(CONTROLLER .. ":ServerPastePrefab")
    tpl = { off = off, size = size, info_size = off["Placeable.bPrefabPreserveOwnership"] - off["Placeable.PrefabInfo"], hash_size = info.Hash.size }
    return tpl
end

local function put(buf, offset, bytes) return buf:sub(1, offset) .. bytes .. buf:sub(offset + #bytes + 1) end

-- EBRPlacerPlacementType
local PLACE = { brick = 1, entity = 2, prefab = 3 }

-- a cached prefab's FBRPrefabHashAndMetadata bytes, by hash bytes
local function cached_info(hash)
    local L = template_layout()
    for _, o in ipairs(FindAllOf("BRPrefabCacheInMemoryPrefab") or {}) do
        if o:IsValid() then
            local at = __addr(o) + I.find_field(o:GetClass(), "Info"):GetOffset_Internal()
            local info = __peek(at, L.info_size)
            if info:sub(1, L.hash_size) == hash then return info end
        end
    end
end

local function hash_bytes(h)
    if #h == 64 and h:match("^%x+$") then
        return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
    end
    assert(#h == 32, "a prefab hash is 64 hex digits (BR.prefab.cached lists them)")
    return h
end

-- the registered instance of an entity type (what an entity slot points at)
local function entity_type(name)
    local cls = BR.entity.class(name)
    for _, o in ipairs(FindAllOf(cls:GetFName():ToString()) or {}) do
        if o:IsValid() and o:GetFullName():find(":BRRegistry.", 1, true) then return o end
    end
    error("no registered entity type " .. tostring(name))
end

--- An inventory template as bytes from a description: { brick = asset name,
--- size = {x, y, z} (procedural bricks; default the asset's own) } or
--- { entity = class name } or { prefab = hash (hex) } or { item = item name },
--- with count (default 1) and preserve_ownership (prefabs).
function prefab.template(what)
    local L = template_layout()
    local o = L.off
    local b = string.rep("\0", L.size)
    b = put(b, o.Count, string.pack("<i4", what.count or 1))
    if what.item then
        local class = type(what.item) == "string" and assert(BR.player.item_class(what.item), "no item " .. what.item) or what.item
        return put(b, o.ItemClass, BR.raw.ptr(class))
    end
    b = put(b, o.bIsPlaceable, "\1")
    if what.brick then
        local asset = BR.brick.asset(what.brick)
        local size = what.size
        if not size then
            -- a fixed-size brick carries its own size; a procedural one needs one given
            local ok, hs = pcall(function() return asset:GetBrickType():GetHalfSize() end)
            size = ok and hs and { hs.X, hs.Y, hs.Z } or { 5, 5, 6 }
        end
        b = put(b, o["Placeable.Type"], string.pack("B", PLACE.brick))
        b = put(b, o["Placeable.BrickType.BrickAsset"], BR.raw.ptr(asset))
        return put(b, o["Placeable.BrickType.ProceduralSize"], BR.raw.ivec(size[1], size[2], size[3]))
    elseif what.entity then
        b = put(b, o["Placeable.Type"], string.pack("B", PLACE.entity))
        return put(b, o["Placeable.EntityType"], BR.raw.ptr(entity_type(what.entity)))
    elseif what.prefab then
        local info = assert(cached_info(hash_bytes(what.prefab)), "that prefab isn't in the server's cache (BR.prefab.cached)")
        b = put(b, o["Placeable.Type"], string.pack("B", PLACE.prefab))
        b = put(b, o["Placeable.PrefabInfo"], info)
        return put(b, o["Placeable.bPrefabPreserveOwnership"], what.preserve_ownership and "\1" or "\0")
    end
    error("a template is { brick = }, { entity = }, { prefab = } or { item = }")
end

local as_controller = I.as_controller

--- Put something in a hotbar slot (0-based): BR.prefab.template's description,
--- e.g. { brick = "B_1x1_Round" }, { entity = "Entity_Ball" }, { prefab = hash },
--- { item = "Weapon_Pistol" }. The game checks the player may hold it.
function prefab.set_slot(ps, slot, what)
    -- an item from the template's bytes reaches the client but not the
    -- server's inventory (seen on CL16507: the slot stayed empty and the client
    -- held a model-less pistol it couldn't put away); the reflected call works
    if what.item then return BR.player.give(ps, slot, what.item, what.count) end
    local t = prefab.template(what)
    as_controller(ps, function(pc)
        BR.raw.call(pc, "BRPlayerController", "ServerSetInventorySlot", { Slot = string.pack("<i4", slot), Template = t })
    end)
end

--- Put something on the player's template, the slot the placer builds from (as
--- picking a brick from the catalog or copying a selection does). A prefab goes
--- there the way a paste does.
function prefab.set_template(ps, what)
    if what.prefab then
        local hash = hash_bytes(what.prefab)
        assert(cached_info(hash), "that prefab isn't in the server's cache (BR.prefab.cached)")
        as_controller(ps, function(pc)
            BR.raw.call(pc, "BRPlayerController", "ServerPastePrefab", { Hash = hash,
                bWithOwnership = what.preserve_ownership and "\1" or "\0", bInTemp = "\1", PasteInfo = string.rep("\0", 24) })
        end)
        return
    end
    local t = prefab.template(what)
    as_controller(ps, function(pc) BR.raw.call(pc, "BRPlayerController", "ServerSetInventoryTempSlot", { Template = t }) end)
end

--- Empty the player's template.
function prefab.clear_template(ps)
    as_controller(ps, function(pc) pc:ServerClearInventoryTempSlot() end)
end

local function hex(bytes) return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

--- The prefabs the server has cached, oldest first: { hash (hex), bricks,
--- entities, components, wires, size = {x, y, z} }.
function prefab.cached()
    local L = template_layout()
    local out = {}
    for _, o in ipairs(FindAllOf("BRPrefabCacheInMemoryPrefab") or {}) do
        if o:IsValid() then
            local at = __addr(o) + I.find_field(o:GetClass(), "Info"):GetOffset_Internal()
            local c = o.Info.Counts
            out[#out + 1] = {
                hash = hex(__peek(at, L.hash_size)),
                bricks = c.NumBricks, entities = c.NumEntities, components = c.NumComponents, wires = c.NumWires,
                size = { c.Size.X, c.Size.Y, c.Size.Z },
            }
        end
    end
    return out
end

--- A cached prefab's details (as BR.prefab.cached lists them) by hash, or nil.
function prefab.info(hash)
    hash = hash:lower()
    for _, c in ipairs(prefab.cached()) do if c.hash == hash then return c end end
end

--- The FBRPlaceable bytes for a cached prefab: what a placer holds as its
--- current placeable when a player holds the prefab (BR.act.place_prefab uses it).
function prefab.placeable(hash)
    local L = template_layout()
    local t = prefab.template({ prefab = hash })
    return t:sub(L.off.Placeable + 1, L.off["Placeable.bPrefabPreserveOwnership"] + 1)
end

--- Copy the bricks in a box onto a connected player's template, as their
--- selector's copy does: `center` and `size` in grid units (size is the box's
--- full size). The server caches the copy as a prefab, so it shows in
--- BR.prefab.cached afterwards.
function prefab.copy(ps, center, size, grid)
    assert(BR.player.connected(ps), "only a connected player has a template to copy onto")
    local pc = assert(BR.player.controller(ps), "no controller")
    local selector
    for _, t in ipairs(FindAllOf("BRTool_Selector") or {}) do
        local owner = t:IsValid() and t:GetOwner()
        if owner and owner:IsValid() and __addr(owner) == __addr(pc) then selector = t end
    end
    assert(selector, "they have no selector")
    -- the selector takes the grid's BrickGridComponent, not the grid actor
    selector:ServerCopySelection((grid or BR.world.global_grid()).BrickGridComponent, { X = center[1], Y = center[2], Z = center[3] },
        { X = size[1], Y = size[2], Z = size[3] }, true, false)
end

local function check_path(path)
    assert(type(path) == "string" and path ~= "" and not path:find('["\r\n]') and not path:find("%.%."), "bad prefab path")
end

--- Save the bricks in a box to Saved/Prefabs/<path>.brz: `center` and `extent`
--- (half size) in grid units. opts.entities includes entities.
function prefab.save(path, center, extent, opts)
    check_path(path)
    BR.server.console(string.format('br.Prefab.SaveRegion "%s" %d %d %d %d %d %d %s', path,
        center[1], center[2], center[3], extent[1], extent[2], extent[3], (opts and opts.entities) and "true" or "false"))
end

--- Give a connected player the prefab file Saved/Prefabs/<path>.brz on their
--- template, as the game's br.Prefab.GiveToPlayer does; it is cached, so it
--- shows in BR.prefab.cached afterwards. Not for bots: the game finds the player
--- by id, and every bot has the same empty one. For a bot, BR.prefab.set_template
--- with the cached hash does the same.
function prefab.give(ps, path, preserve_ownership)
    check_path(path)
    assert(BR.player.connected(ps), "only a connected player can be given a prefab file")
    BR.server.console(string.format('br.Prefab.GiveToPlayer "%s" "%s" %s', path, BR.player.id(ps), preserve_ownership and "true" or "false"))
end

return prefab

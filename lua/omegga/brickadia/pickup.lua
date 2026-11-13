-- BR.pickup: Item, ammo and health pickups in the world: placing them, dropping a
-- player's item as one, deciding per player who may take them, and hearing who
-- did.
--
-- A pickup is taken through its HandlePickupAttempt(Pawn), a Blueprint native
-- event that the Blueprint pickups override (health and ammo do their own
-- thing), so the game calls it through ProcessEvent and a hook can refuse it.
-- Refusing leaves the pickup as it was, enabled for everyone else. A player
-- standing in a pickup that refused them gets no new attempt until they step
-- out and back in.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local pickup = {}

local ATTEMPT = "/Script/Brickadia.BRPickupBase:HandlePickupAttempt"
local SCRIPT = "/Script/Brickadia."

-- gates, listeners and the pickups that go away once taken live in _G, and the
-- hooks are installed once per Lua state, so a BR_RELOAD keeps them; each
-- reload replaces shared.run with its own
_G.BR_PICKUP = _G.BR_PICKUP or { gates = {}, listeners = {}, consume = {}, pending = {} }
local shared = _G.BR_PICKUP

local function valid(o) return o ~= nil and o:IsValid() end

-- pickup class for an item class name ("Weapon_Pistol_C"), from the pickup
-- classes' defaults
local by_item
local function item_pickups()
    if by_item then return by_item end
    by_item = {}
    local base = StaticFindObject(SCRIPT .. "BRItemPickupBase")
    ForEachUObject(function(o)
        if o:GetClass():GetFName():ToString() == "BlueprintGeneratedClass" and o:IsChildOf(base) then
            local cdo = o:GetCDO()
            local item = cdo and cdo.ItemClass
            if valid(item) then by_item[item:GetFName():ToString()] = o end
        end
    end)
    return by_item
end

local function find_class(name)
    local c = FindObject("BlueprintGeneratedClass", name)
    if valid(c) then return c end
end

--- The pickup class for `what`: a pickup class name ("BP_Pickup_Ammo_Light",
--- "BP_ItemPickup_Pistol"), a short name ("Pistol", "Ammo_Light",
--- "Health_Small"), an item class name ("Weapon_Pistol"), or a class.
function pickup.class(what)
    if type(what) ~= "string" then return what end
    if what:sub(1, 1) == "/" then
        local c = StaticFindObject(what)
        return valid(c) and c or nil
    end
    local name = what:gsub("_C$", "")
    return find_class(name .. "_C")
        or find_class("BP_ItemPickup_" .. name .. "_C")
        or find_class("BP_Pickup_" .. name .. "_C")
        or item_pickups()[name .. "_C"]
end

-- the PlayerState whose character is at `addr`, if any
local function player_of(addr)
    for _, ps in ipairs(BR.player.list()) do
        local ch = BR.player.character(ps)
        if ch and __addr(ch) == addr then return ps, ch end
    end
    for _, ps in ipairs(BR.bot.list()) do
        local ch = BR.player.character(ps)
        if ch and __addr(ch) == addr then return ps, ch end
    end
end

local function count_of(ch, class_name)
    local n = 0
    for _, e in ipairs(BR.player.inventory(ch)) do if e.item == class_name then n = n + 1 end end
    return n
end

function shared.run(self, params)
    local addr = string.unpack("<I8", params, 1)
    local ps, ch = player_of(addr)
    if not ps then return nil end
    for _, gate in ipairs(shared.gates) do
        local ok, allow = pcall(gate, ps, self)
        if not ok then
            I.report("BR.pickup.gate", allow)
        elseif allow == false then
            return false
        end
    end
    if #shared.listeners == 0 and not shared.consume[__addr(self)] then return nil end
    -- what the attempt changes tells whether it worked: a pickup that turns
    -- itself off, or one more of its item in the inventory
    local item = self.ItemClass
    local item_name = valid(item) and item:GetFName():ToString() or nil
    shared.pending[__addr(self)] = { ps = ps, ch = ch, item = item_name, enabled = self:IsPickupEnabled(),
        count = item_name and count_of(ch, item_name) or 0 }
    return nil
end

function shared.after(self)
    local key = __addr(self)
    local before = shared.pending[key]
    shared.pending[key] = nil
    if not before or not valid(before.ch) then return end
    local taken = (before.enabled and not self:IsPickupEnabled())
        or (before.item ~= nil and count_of(before.ch, before.item) > before.count)
    if not taken then return end
    for _, fn in ipairs(shared.listeners) do
        local ok, err = pcall(fn, before.ps, self, before.item)
        if not ok then I.report("BR.pickup.on", err) end
    end
    if shared.consume[key] then
        shared.consume[key] = nil
        self:K2_DestroyActor()
    end
end

-- A connected player's pickup starts at the pickup's overlap callback;
-- HandlePickupAttempt is only reached for bots (seen on CL16507), so gates are
-- asked at the overlap too. Refusing the overlap means the player has to step
-- out and back in once a gate lets them.
local OVERLAP = "/Script/Brickadia.BRPickupBase:HandleComponentOverlap"

function shared.run_overlap(self, params)
    if #shared.gates == 0 then return nil end
    local at = __fn_layout(OVERLAP).OtherActor.offset
    local ps = player_of(string.unpack("<I8", params, at + 1))
    if not ps then return nil end
    for _, gate in ipairs(shared.gates) do
        local ok, allow = pcall(gate, ps, self)
        if not ok then
            I.report("BR.pickup.gate", allow)
        elseif allow == false then
            return false
        end
    end
    return nil
end

local function hook()
    if not shared.hooked then
        shared.hooked = true
        BR.event.hook(ATTEMPT, function(self, params) return shared.run(self, params) end)
        BR.event.after(ATTEMPT, function(self) shared.after(self) end)
    end
    if not shared.overlap_hooked then
        shared.overlap_hooked = true
        BR.event.hook(OVERLAP, function(self, params) return shared.run_overlap(self, params) end)
    end
end

--- Refuse pickups by a condition: fn(player, pickup) returning false stops that
--- player taking that pickup, which stays enabled for everyone else. Any gate
--- refusing is enough. Returns a function that removes the gate.
---
---   -- TTT: only the dropper's own team can take a dropped traitor item
---   BR.pickup.gate(function(ps, p) if dropped_by_traitor[__addr(p)] then return is_traitor(ps) end end)
function pickup.gate(fn)
    hook()
    table.insert(shared.gates, fn)
    return function()
        for i, g in ipairs(shared.gates) do if g == fn then table.remove(shared.gates, i) break end end
    end
end

--- Call fn(player, pickup, item) whenever someone takes a pickup; item is the
--- item class name ("Weapon_Pistol_C"), or nil for ammo and health. Returns a
--- function that stops it.
function pickup.on(fn)
    hook()
    table.insert(shared.listeners, fn)
    return function()
        for i, f in ipairs(shared.listeners) do if f == fn then table.remove(shared.listeners, i) break end end
    end
end

-- the pickup fields the game's item gates set, from BR.player.tune's names
local function apply(p, opts)
    if opts.respawn ~= nil then p:SetAutoRespawnTime(opts.respawn) end
    if opts.multi ~= nil then p.bAllowMultiPickup = opts.multi end
    if opts.damage then p.DamageMultiplier = opts.damage end
    if opts.speed then p.WeaponSpeedMultiplier = opts.speed end
    if opts.name then p.ItemNameOverride = FText(opts.name) end
    if opts.projectile_scale then p.ProjectileScaleMultiplier = opts.projectile_scale end
    if opts.projectile then
        local c = opts.projectile
        if type(c) == "string" then c = assert(find_class(c:find("_C$") and c or (c .. "_C")), "no projectile class " .. c) end
        p.ProjectileOverride = c
    end
    if opts.colors then
        local colors = {}
        for i, c in ipairs(opts.colors) do colors[i] = { R = c[1], G = c[2], B = c[3], A = c[4] or 255 } end
        p.MeshColors = colors
        p:ApplyMeshColors()
    end
    if opts.once then shared.consume[__addr(p)] = true hook() end
    p:ForceNetUpdate()
end

--- Place a pickup at position {x, y, z}. `what` as BR.pickup.class takes it.
--- opts: respawn (seconds until it comes back after being taken; 0 never),
--- once (removed once taken), multi (a player may take several), and the
--- item's tuning as BR.player.tune names it: damage, speed, name, projectile,
--- projectile_scale, colors. Returns the pickup actor.
function pickup.spawn(what, position, opts)
    opts = opts or {}
    local class = assert(pickup.class(what), "no pickup for " .. tostring(what))
    local p = BR.world.spawn(class)
    -- spawned from Lua it doesn't replicate, so no client would see it
    -- (seen on CL16507); the game's own drops do
    p:SetReplicates(true)
    BR.world.teleport(p, position[1], position[2], position[3])
    apply(p, opts)
    return p
end

--- Take the item in a player's slot (0-based) out of their inventory and leave
--- it as a pickup where they stand, its tuning (damage, speed, name, projectile,
--- colours) kept. It goes away once someone takes it unless opts.once is false;
--- opts.position puts it elsewhere; other opts as BR.pickup.spawn. Returns the
--- pickup, or nil if the slot holds no item.
function pickup.drop(ps, slot, opts)
    opts = opts or {}
    local ch = assert(BR.player.character(ps), "they have no character")
    local e = ch:GetCharacterInventoryEntry(slot)
    local item = e and e.ItemInstance
    if not valid(item) then return nil end
    local class = assert(item_pickups()[item:GetClass():GetFName():ToString()], "no pickup for " .. item:GetClass():GetFName():ToString())
    local at = opts.position
    if not at then
        local l = ch:K2_GetActorLocation()
        at = { l.X, l.Y, l.Z }
    end
    local kept = { damage = item.DamageMultiplier, speed = item.WeaponSpeedMultiplier, respawn = 0, once = true }
    local WEAPON = StaticFindObject(SCRIPT .. "BRWeaponBase")
    if item:IsA(WEAPON) then
        kept.projectile_scale = item.ProjectileScaleMultiplier
        if valid(item.ProjectileOverride) then kept.projectile = item.ProjectileOverride end
    end
    for k, v in pairs(opts) do kept[k] = v end
    if kept.once == false then kept.once = nil end
    BR.player.clear_slot(ps, slot)
    local p = BR.world.spawn(class)
    BR.world.teleport(p, at[1], at[2], at[3])
    apply(p, kept)
    return p
end

--- Every pickup in the world. (Walking the object list would also find
--- pickups already destroyed but not yet garbage collected.)
function pickup.list()
    local found = {}
    StaticFindObject("/Script/Engine.Default__GameplayStatics")
        :GetAllActorsOfClass(BR.world.context(), StaticFindObject(SCRIPT .. "BRPickupBase"), found)
    local out = {}
    for _, a in ipairs(found) do out[#out + 1] = a:get() end
    return out
end

return pickup

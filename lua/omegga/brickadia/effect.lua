-- BR.effect: Timed status effects on players: regeneration, poison, size, and any
-- a mod defines. An effect is applied to a player's character for a duration,
-- stacks by its own rule, can tick, and ends when its time runs out, when it is
-- removed, or with the character (death, respawn, leaving).
--
-- Effects change what the server decides: health, and replicated character
-- state like size. Movement speed is client-predicted, so speed and jump
-- effects belong in team rules (BR.team.rule), where clients get the same
-- values; changing them on the server alone makes players rubber-band.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local effect = {}

local defs = {}
-- character address -> { [name] = instance }
_G.BR_EFFECTS = _G.BR_EFFECTS or {}
local active = _G.BR_EFFECTS

local function call(def, what, self, ...)
    local fn = def[what]
    if not fn then return end
    local ok, err = pcall(fn, self, ...)
    if not ok then I.report("BR.effect " .. self.name .. " " .. what, err) end
end

--- Define an effect. spec:
---   apply(self): it starts (self.stacks, self.strength are set)
---   tick(self, seconds): every spec.interval seconds while it lasts
---   remove(self): it ends, for any reason
---   restack(self): its stacks or strength changed by another apply
---   interval: seconds between ticks (default 1)
---   stack: what applying it again does: "refresh" (the default: restart the
---     duration), "add" (one more stack, up to max_stacks, and a fresh
---     duration), "max" (keep the longer duration and the greater strength)
---   max_stacks (default 1 for refresh, 10 for add)
--- self: { name, player, character, stacks, strength, expires (BR.timer.now
--- time, or nil for no end), data = {} for the effect's own state }.
function effect.define(name, spec)
    assert(type(name) == "string", "an effect needs a name")
    spec.name = name
    spec.interval = spec.interval or 1
    spec.stack = spec.stack or "refresh"
    spec.max_stacks = spec.max_stacks or (spec.stack == "add" and 10 or 1)
    defs[name] = spec
end

local function finish(key, name)
    local list = active[key]
    local self = list and list[name]
    if not self then return end
    list[name] = nil
    if self.cancel then self.cancel() end
    call(self.def, "remove", self)
end

--- Apply effect `name` to a player for opts.duration seconds (nil: until
--- removed). opts.strength (default 1) is the effect's own measure (health per
--- second for regen and poison, the scale for size); opts.stacks (default 1).
--- Returns the effect's self, or nil if the player has no character.
function effect.apply(ps, name, opts)
    opts = opts or {}
    local def = assert(defs[name], "no effect " .. tostring(name) .. " (BR.effect.define it)")
    local ch = BR.player.character(ps)
    if not (ch and ch:IsValid()) then return nil end
    local key = __addr(ch)
    active[key] = active[key] or {}
    local now = BR.timer.now()
    local expires = opts.duration and (now + opts.duration) or nil
    local self = active[key][name]
    if self then
        if def.stack == "add" then
            self.stacks = math.min(def.max_stacks, self.stacks + (opts.stacks or 1))
            self.expires = expires
        elseif def.stack == "max" then
            self.strength = math.max(self.strength, opts.strength or 1)
            if self.expires and (not expires or expires > self.expires) then self.expires = expires end
        else
            self.strength = opts.strength or self.strength
            self.expires = expires
        end
        call(def, "restack", self)
        return self
    end
    self = { name = name, def = def, player = ps, character = ch, stacks = math.min(def.max_stacks, opts.stacks or 1),
        strength = opts.strength or 1, expires = expires, data = {} }
    active[key][name] = self
    call(def, "apply", self)
    -- one timer per effect: it ticks, and ends the effect once it has expired or
    -- the character is gone (a timer owned by the character ends with it)
    local last = now
    self.cancel = BR.timer.every(math.min(def.interval, 0.1), function()
        local t = BR.timer.now()
        if self.expires and t >= self.expires then
            finish(key, name)
            return false
        end
        if t - last >= def.interval then
            call(def, "tick", self, t - last)
            last = t
        end
    end, { owner = ch })
    return self
end

--- End effect `name` on a player now (nil: every effect).
function effect.remove(ps, name)
    local ch = BR.player.character(ps)
    if not ch then return end
    local key = __addr(ch)
    if name then finish(key, name) return end
    for n in pairs(active[key] or {}) do finish(key, n) end
end

--- The player's effects: { [name] = self }.
function effect.of(ps)
    local ch = BR.player.character(ps)
    local out = {}
    for n, self in pairs(ch and active[__addr(ch)] or {}) do out[n] = self end
    return out
end

-- Effects a character had when it died or left: their timers ended with the
-- character, so they are cleared here, without remove calls on a body that's gone.
local function sweep()
    for key, list in pairs(active) do
        local any
        for _, self in pairs(list) do
            any = self
            break
        end
        if not any or not any.character:IsValid() then active[key] = nil end
    end
end

effect.define("regen", {
    interval = 0.5,
    tick = function(self, dt)
        local ch = self.character
        local hp, max = BR.player.health(ch)
        if hp > 0 then BR.player.set_health(ch, math.min(max, hp + self.strength * self.stacks * dt)) end
    end,
})

effect.define("poison", {
    interval = 0.5,
    stack = "add",
    tick = function(self, dt)
        local ch = self.character
        local hp = BR.player.health(ch)
        if hp > 0 then BR.player.set_health(ch, math.max(0, hp - self.strength * self.stacks * dt)) end
    end,
})

local function set_scale(ch, scale)
    ch.CharacterScale = scale
    ch:OnRep_CharacterScale()
    ch:ForceNetUpdate()
end

effect.define("size", {
    stack = "max",
    apply = function(self) self.data.before = self.character.CharacterScale set_scale(self.character, self.strength) end,
    restack = function(self) set_scale(self.character, self.strength) end,
    remove = function(self) if self.character:IsValid() then set_scale(self.character, self.data.before or 1) end end,
})

if _G.BR_EFFECT_SWEEP then _G.BR_EFFECT_SWEEP() end
_G.BR_EFFECT_SWEEP = BR.event.tick((function()
    local wait = 0
    return function(dt)
        wait = wait - dt
        if wait > 0 then return end
        wait = 5
        sweep()
    end
end)())

return effect

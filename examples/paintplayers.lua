-- Paint players: spraying another player with the painter tool turns their
-- avatar the painter's colour for a few seconds. A demo of hooking a Blueprint's
-- RPCs and of changing an avatar from the server; run it in the bridge (an
-- omegga plugin's emitPlugin('exec', ...)):
--
--   local Paint = dofile("<omegga>/plugins/ue4ss/examples/paintplayers.lua")
--   Paint.start()   -- painting players works from now on
--   Paint.stop()    -- stop, and give everyone their own colours back
--
-- The painter's trigger, aim and colour live on the client. What reaches the
-- server is three RPCs on the tool's Blueprint, Tool_Painter_C: ServerFirePaint
-- (trigger held), ServerUpdateLaser (where the beam ends) and
-- ServerSetPaintColor. The native ABRTool_Painter has a bFiring flag, but the
-- server never sets it.
local Paint = {}

-- how long a player keeps a colour after the beam leaves them
local SECONDS = 5

local PAINTER = "/Game/Tools/Painter/Tool_Painter.Tool_Painter_C:"
-- BRPlayerAvatarManagerComponent.CustomizedAvatar (FBRPlayerAvatarCustomizationV3)
-- is a TArray of 56-byte parts whose Colors, at +24, is a fixed array of eight
-- FColors. UE4SS reads only the first element of a fixed array, so the colours
-- are written in place and the game is told the avatar changed.
local AVATAR_OFFSET, PART_SIZE, COLORS_OFFSET, COLORS = 192, 56, 24, 8

-- kept across a reload of this file: the hooks can't be removed, so they are
-- installed once and do nothing while stopped
_G.PAINT_PLAYERS = _G.PAINT_PLAYERS or { tools = {}, painted = {}, on = false }
local S = _G.PAINT_PLAYERS

local function now()
    return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(BR.world.context())
end

-- the avatar's parts: the component, the array's data and its length
local function avatar(pc)
    local comp = pc.PlayerAvatarComponent
    if not (comp and comp:IsValid()) then return nil end
    local data, num = string.unpack("<I8i4", __peek(__addr(comp) + AVATAR_OFFSET, 12))
    if data == 0 or num <= 0 or num > 64 then return nil end
    return comp, data, num
end

local function write_colors(comp, data, num, colors)
    for i = 0, num - 1 do __poke(data + i * PART_SIZE + COLORS_OFFSET, colors[i]) end
    comp:UpdatePlayerAvatar(comp.CustomizedAvatar)
end

-- bgra: one FColor's bytes, as the RPC carries it (B, G, R, A)
local function paint(pc, bgra)
    local comp, data, num = avatar(pc)
    if not comp then return end
    local key = __addr(pc)
    local p = S.painted[key]
    if not p then
        local saved = {}
        for i = 0, num - 1 do saved[i] = __peek(data + i * PART_SIZE + COLORS_OFFSET, COLORS * 4) end
        p = { pc = pc, data = data, num = num, saved = saved }
        S.painted[key] = p
    end
    -- the player saved a new avatar meanwhile: leave theirs alone
    if p.data ~= data or p.num ~= num then return end
    p.expires = now() + SECONDS
    if p.color == bgra then return end
    p.color = bgra
    local fill = {}
    for i = 0, num - 1 do fill[i] = string.rep(bgra, COLORS) end
    write_colors(comp, data, num, fill)
end

local function restore(key)
    local p = S.painted[key]
    S.painted[key] = nil
    if not (p and p.pc:IsValid()) then return end
    local comp, data, num = avatar(p.pc)
    if comp and data == p.data and num == p.num then write_colors(comp, data, num, p.saved) end
end

local function tool_state(tool)
    local key = __addr(tool)
    local t = S.tools[key]
    if not t then
        t = { tool = tool }
        S.tools[key] = t
    end
    return t
end

local function install_hooks()
    if S.hooked then return end
    S.hooked = true
    BR.event.hook(PAINTER .. "ServerFirePaint", function(self, params)
        if S.on and self:IsValid() then tool_state(self).firing = params:byte(1) ~= 0 end
    end)
    BR.event.hook(PAINTER .. "ServerUpdateLaser", function(self, params)
        if S.on and self:IsValid() then tool_state(self).laser = { string.unpack("<ddd", params) } end
    end)
    BR.event.hook(PAINTER .. "ServerSetPaintColor", function(self, params)
        if S.on and self:IsValid() then tool_state(self).color = params:sub(1, 4) end
    end)
end

-- Where along the segment o + v*s (s in 0..1) it first enters a character's
-- capsule, taken as an upright cylinder of the capsule's radius and full
-- height; nil if it misses.
local function enters(ox, oy, oz, vx, vy, vz, target)
    local cap = target.CapsuleComponent
    if not (cap and cap:IsValid()) then return nil end
    local radius, half = cap:GetScaledCapsuleRadius(), cap:GetScaledCapsuleHalfHeight()
    local c = target:K2_GetActorLocation()
    local px, py = ox - c.X, oy - c.Y
    local a = vx * vx + vy * vy
    if a < 1e-9 then return nil end
    local b = 2 * (px * vx + py * vy)
    local disc = b * b - 4 * a * (px * px + py * py - radius * radius)
    if disc < 0 then return nil end
    local root = math.sqrt(disc)
    for _, s in ipairs({ (-b - root) / (2 * a), (-b + root) / (2 * a) }) do
        if s >= 0 and s <= 1 then
            local z = oz + vz * s
            if z >= c.Z - half and z <= c.Z + half then return s end
        end
    end
    return nil
end

-- The player the beam of a firing painter `t` meets first, or nil. The beam
-- doesn't stop on characters, so its end is wherever it would hit a brick (or
-- 300 m out). That end arrives relative to the tool, in the aim's own frame (x
-- along the aim, y right, z up), so it is turned by the holder's control
-- rotation and added to the tool's location.
local function beam_target(t, pc, ch)
    local o = t.tool:K2_GetActorLocation()
    local r = BR.math.rot(pc:GetControlRotation())
    local f, rt, up = r:forward(), r:right(), r:up()
    local lx, ly, lz = t.laser[1], t.laser[2], t.laser[3]
    local vx = f.x * lx + rt.x * ly + up.x * lz
    local vy = f.y * lx + rt.y * ly + up.y * lz
    local vz = f.z * lx + rt.z * ly + up.z * lz
    local best, best_s
    for _, ps in ipairs(BR.player.list()) do
        local target = BR.player.character(ps)
        if target and target:IsValid() and __addr(target) ~= __addr(ch) then
            local s = enters(o.X, o.Y, o.Z, vx, vy, vz, target)
            if s and (not best_s or s < best_s) then best, best_s = ps, s end
        end
    end
    return best
end

local function tick()
    local time = now()
    for key, p in pairs(S.painted) do
        if time >= p.expires then restore(key) end
    end
    for key, t in pairs(S.tools) do
        if not t.tool:IsValid() then
            S.tools[key] = nil
        elseif t.firing and t.laser then
            local pc = t.tool:GetOwner()
            local ch = pc and pc:IsValid() and pc.Pawn
            local ps = ch and ch:IsValid() and beam_target(t, pc, ch)
            local target_pc = ps and ps:GetOwner()
            if target_pc and target_pc:IsValid() then
                -- the colour arrives when it's picked; a painter used since
                -- before start() gets a random one until then
                t.color = t.color or string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), 255)
                paint(target_pc, t.color)
            end
        end
    end
end

function Paint.start()
    install_hooks()
    S.on = true
    if S.stop_tick then S.stop_tick() end
    S.stop_tick = BR.timer.every(0.1, tick)
end

function Paint.stop()
    S.on = false
    if S.stop_tick then S.stop_tick() end
    S.stop_tick = nil
    for key in pairs(S.painted) do restore(key) end
    S.tools = {}
end

return Paint

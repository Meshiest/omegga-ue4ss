-- BR.sound: Playing the game's sounds to players: on everyone's screen (2D), to
-- chosen players, or from a point in the world that fades with distance.
--
-- Sounds are named as the game's audio browser names them: the one-shot sounds
-- the Play Audio gates use ("OSA_GrenadeLauncher_Fire", "OBA_Deathmatch_Round_Start")
-- and the looping ambience and music audio emitters use ("BA_AMB_Component_Fires_Fireplace_1").
-- BR.enums.list("sound") lists them.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local sound = {}

local catalog
local function descriptors()
    if catalog then return catalog end
    catalog = {}
    for _, cn in ipairs({ "/Script/Brickadia.BrickOneShotAudioDescriptor", "/Script/Brickadia.BrickAudioDescriptor" }) do
        local c = StaticFindObject(cn)
        ForEachUObject(function(o)
            if o:IsA(c) then
                local name = o:GetFName():ToString()
                if not name:find("^Default__") then catalog[name] = o end
            end
        end)
    end
    return catalog
end

--- Every sound name, sorted.
function sound.list()
    local out = {}
    for name in pairs(descriptors()) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- a USoundBase from a name (or a path, or the object)
local function resolve(s)
    if type(s) ~= "string" then return s end
    if s:sub(1, 1) == "/" then
        local o = StaticFindObject(s)
        assert(o and o:IsValid(), "no sound " .. s)
        return o.Sound and o.Sound:IsValid() and o.Sound or o
    end
    local d = descriptors()[s]
    if not d or not d:IsValid() then
        catalog = nil
        d = descriptors()[s]
    end
    assert(d and d:IsValid(), "no sound " .. s .. " (BR.sound.list or BR.enums.list(\"sound\") lists them)")
    return d.Sound
end

-- Unreal's duration for a sound that loops forever (INDEFINITELY_LOOPING_DURATION)
local LOOPING = 10000

-- A looping sound (the ambient ones a Speaker brick plays) started this way
-- can't be stopped from the server: every client keeps playing it until they
-- leave. So only sounds that end are played.
local function one_shot(snd, name)
    local ok, duration = pcall(function() return snd.Duration end)
    if ok and type(duration) == "number" and duration >= LOOPING then
        error(tostring(name) .. " loops forever, and a looping sound can't be stopped once played; use a Speaker brick", 3)
    end
    return snd
end

--- Play a sound with no position (as if in the listener's ears) to `target`:
--- "all" (everyone, one multicast), a PlayerState, or a list of them (bots
--- skipped). opts: volume (default 1), pitch (default 1), start (seconds in).
function sound.play(target, s, opts)
    opts = opts or {}
    local snd = one_shot(resolve(s), s)
    local volume, pitch, start = opts.volume or 1, opts.pitch or 1, opts.start or 0
    if target == "all" then
        I.game_state():MulticastPlaySound2D(snd, volume, pitch, start, nil)
        return
    end
    local list = type(target) == "table" and target or { target }
    for _, ps in ipairs(list) do
        if BR.player.connected(ps) then BR.player.controller(ps):ClientPlaySound2D(snd, volume, pitch, start, nil) end
    end
end

--- Play a sound at a world position ({x, y, z}) for everyone near enough to
--- hear it; it fades with distance as the sound's own settings say. opts:
--- volume, pitch, start.
function sound.at(position, s, opts)
    opts = opts or {}
    I.game_state():MulticastPlaySoundAtLocation(one_shot(resolve(s), s), { X = position[1], Y = position[2], Z = position[3] },
        { Pitch = 0, Yaw = 0, Roll = 0 }, opts.volume or 1, opts.pitch or 1, opts.start or 0, nil, nil, nil)
end

return sound

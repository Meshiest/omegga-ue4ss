-- Zombies: bots that hunt the nearest living player. A demo of BR.bot and
-- BR.nav; run it in the bridge (an omegga plugin's emitPlugin('exec', ...)):
--
--   local Z = dofile("<omegga>/plugins/ue4ss/examples/zombies.lua")
--   Z.start(5)   -- five zombies at the spawn
--   Z.stop()     -- remove them
--
-- Each zombie walks straight at its victim when nothing is in the way, finds a
-- path around walls when something is, and hugs whoever it reaches.
local Z = {}

-- how often a zombie looks for its victim again, and how close it has to get
local RETARGET, REACH = 1.0, 40
-- each zombie's path search gets this many traces a tick, so a horde stays cheap
local SEARCH_BUDGET = 60

_G.ZOMBIES = _G.ZOMBIES or {}

local function location(ps)
    local ch = BR.player.character(ps)
    if not ch then return nil end
    local v = ch:K2_GetActorLocation()
    return { v.X, v.Y, v.Z }
end

local function is_zombie(ps)
    for _, z in ipairs(_G.ZOMBIES) do
        if z.ps:IsValid() and __addr(z.ps) == __addr(ps) then return true end
    end
    return false
end

-- every player with a living character, bots included, that is not a zombie
local function victims()
    local out = {}
    local function add(ps)
        if not is_zombie(ps) and BR.player.character(ps) then out[#out + 1] = ps end
    end
    for _, ps in ipairs(BR.player.list()) do add(ps) end
    for _, ps in ipairs(BR.bot.list()) do add(ps) end
    return out
end

local function nearest(from)
    local best, best_d
    for _, ps in ipairs(victims()) do
        local p = location(ps)
        local dx, dy = p[1] - from[1], p[2] - from[2]
        local d = dx * dx + dy * dy
        if not best_d or d < best_d then best, best_d = ps, d end
    end
    return best, best_d and math.sqrt(best_d)
end

local function hunt(z)
    local here = location(z.ps)
    if not here then return end
    local victim, dist = nearest(here)
    if not victim then
        BR.bot.stop(z.ps)
        return
    end
    local there = location(victim)
    if dist <= REACH then
        BR.bot.stop(z.ps)
        BR.bot.look_at(z.ps, there)
        BR.act.emote(z.ps, BR.act.EMOTE.Hug)
        return
    end
    BR.bot.look(z.ps)
    if BR.nav.clear(here, there) then
        BR.bot.move_to(z.ps, there, { radius = REACH })
    elseif not z.searching then
        z.searching = true
        local function done() z.searching = false end
        BR.bot.path_to(z.ps, there, { radius = REACH, budget = SEARCH_BUDGET, on_arrive = done, on_fail = done })
    end
end

--- Spawn `n` zombies and set them hunting.
function Z.start(n)
    for i = 1, n do
        local ps = BR.bot.spawn("Zombie " .. (#_G.ZOMBIES + 1))
        _G.ZOMBIES[#_G.ZOMBIES + 1] = { ps = ps, wait = math.random() * RETARGET }
    end
    if not _G.ZOMBIES_TICK then
        _G.ZOMBIES_TICK = BR.event.tick(function(dt)
            for _, z in ipairs(_G.ZOMBIES) do
                if z.ps:IsValid() then
                    z.wait = z.wait - dt
                    if z.wait <= 0 then
                        z.wait = RETARGET
                        hunt(z)
                    end
                end
            end
        end)
    end
    return #_G.ZOMBIES
end

--- Remove every zombie.
function Z.stop()
    if _G.ZOMBIES_TICK then _G.ZOMBIES_TICK() end
    _G.ZOMBIES_TICK = nil
    for _, z in ipairs(_G.ZOMBIES) do
        if z.ps:IsValid() then BR.bot.remove(z.ps) end
    end
    _G.ZOMBIES = {}
end

return Z

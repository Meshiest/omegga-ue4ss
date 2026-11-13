-- BR.npc: The game's own AI bots, spawned by Bot Spawn bricks.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local npc = {}

--- The game's AI bots alive now (destroyed ones left out).
function npc.list()
    local out = {}
    for _, o in ipairs(FindAllOf("BP_FigureV2_Bot_C") or {}) do
        if I.alive(o) then out[#out + 1] = o end
    end
    return out
end

_G.BR_NPC = _G.BR_NPC or { spawn = {}, seen = nil }
local S = _G.BR_NPC

--- fn(npc) when one of the game's AI bots appears (a Bot Spawn brick spawning
--- or respawning it), within about half a second. NPCs alive when this is first
--- called don't count. Returns a function that stops it.
function npc.on_spawn(fn)
    table.insert(S.spawn, fn)
    if not S.polling then
        S.polling = true
        S.seen = {}
        for _, n in ipairs(npc.list()) do S.seen[__addr(n)] = true end
        BR.timer.every(0.5, function()
            local now = {}
            for _, n in ipairs(npc.list()) do
                local key = __addr(n)
                now[key] = true
                if not S.seen[key] then
                    for _, f in ipairs(S.spawn) do
                        local ok, err = I.call("npc.on_spawn", f, n)
                        if not ok then I.report("BR.npc.on_spawn", err) end
                    end
                end
            end
            S.seen = now
        end)
    end
    return function()
        for i, f in ipairs(S.spawn) do if f == fn then table.remove(S.spawn, i) break end end
    end
end

--- fn(npc, info) when one of the game's AI bots dies: info as the death event
--- gives it (damage, damage_type, killer, cause, killer_player). Returns a
--- function that stops it.
function npc.on_death(fn)
    return BR.event.on("death", function(player, info)
        if player then return nil end
        local ch = info.character
        local is_npc = ch and ch:IsValid() and ch:GetClass():GetFName():ToString() == "BP_FigureV2_Bot_C"
        if is_npc then fn(ch, info) end
        return nil
    end)
end

return npc

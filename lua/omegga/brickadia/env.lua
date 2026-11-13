-- BR.env: The world's environment, a group at a time: sky (time of day,
-- weather, sun, fog), ground, water, ambience, space, studio (lighting) and
-- terrain. A change calls the group's own setter on the server (SetTimeOfDay,
-- SetRain, ...), as the Set Environment Property gate does, and the group's
-- actor replicates it. Whether every setting reaches clients has not been seen
-- on a client yet (docs/client-checks.md).
local I = require("omegga.brickadia.internal")
local BR = I.BR
local cdo = I.cdo
local env = {}

-- the game's environment library finds each group's actor; it has no getter
-- for terrain
local GETTERS = { sky = "GetSky", ground = "GetGround", water = "GetWater", ambience = "GetAmbience", space = "GetSpace", studio = "GetStudio" }
local GROUPS = "sky, ground, water, ambience, space, studio or terrain"

local function group_actor(group)
    local a
    if group == "terrain" then
        for _, o in ipairs(FindAllOf("BRTerrainEnvironment") or {}) do
            if o:IsValid() and not o:GetFullName():find("Default__") then a = o break end
        end
    else
        local getter = GETTERS[group]
        if not getter then error("a group is " .. GROUPS, 3) end
        local lib = cdo("BRLuauEnvironmentLibrary")
        a = lib[getter](lib, BR.world.context())
    end
    if not I.alive(a) then error("this world has no " .. group .. " environment", 3) end
    return a
end

-- the group's class and its parents, most derived first
local function classes(actor)
    local out = {}
    local cls = actor:GetClass()
    while cls and cls:IsValid() do
        out[#out + 1] = cls
        cls = cls:GetSuperStruct()
    end
    return out
end

-- UE4SS hands back a stand-in for any name, so a function is only called once
-- the class is known to have it
local function has_function(actor, name)
    for _, cls in ipairs(classes(actor)) do
        local path = cls:GetFullName():match("^%S+%s+(.+)$")
        local f = path and StaticFindObject(path .. ":" .. name)
        if f and f:IsValid() then return true end
    end
    return false
end

local function has_field(actor, name)
    local found = false
    for _, cls in ipairs(classes(actor)) do
        cls:ForEachProperty(function(p) if p:GetFName():ToString() == name then found = true end end)
        if found then return true end
    end
    return false
end

--- The settings a group can change: the names its setters take (TimeOfDay,
--- Rain, FogColor, ...), sorted.
function env.settings(group)
    local seen, out = {}, {}
    for _, cls in ipairs(classes(group_actor(group))) do
        cls:ForEachFunction(function(f)
            local n = f:GetFName():ToString()
            if n:sub(1, 3) == "Set" and #n > 3 and not seen[n] then
                seen[n] = true
                out[#out + 1] = n:sub(4)
            end
        end)
    end
    table.sort(out)
    return out
end

--- Change settings of a group, as many as `values` names:
---
---   BR.env.set("sky", { TimeOfDay = 9.5, Rain = 0.5, FogColor = { R = 0.2, G = 0.3, B = 0.4, A = 1 } })
---   BR.env.set("ground", { GroundColor = { R = 0.2, G = 0.5, B = 0.2, A = 1 } })
---
--- Values are what each setter takes (a number, a boolean, a colour table).
--- An unknown setting is an error before anything changes.
function env.set(group, values)
    if type(values) ~= "table" then error("BR.env.set takes a table of settings", 2) end
    local a = group_actor(group)
    for setting in pairs(values) do
        if type(setting) ~= "string" or not has_function(a, "Set" .. setting) then
            error(group .. " has no setting " .. tostring(setting) .. " (BR.env.settings lists them)", 2)
        end
    end
    for setting, value in pairs(values) do a["Set" .. setting](a, value) end
end

--- A setting's current value: from the group's getter (GetTimeOfDay) when it
--- has one, otherwise its field of that name. A colour comes back as
--- { R, G, B, A }.
function env.get(group, setting)
    local a = group_actor(group)
    local v
    if type(setting) == "string" and has_function(a, "Get" .. setting) then
        v = a["Get" .. setting](a)
    elseif type(setting) == "string" and has_field(a, setting) then
        v = a[setting]
    else
        error(group .. " has no setting " .. tostring(setting), 2)
    end
    -- a struct comes back as a view into the actor; colours are copied out
    if type(v) == "userdata" then
        local ok, r = pcall(function() return { R = v.R, G = v.G, B = v.B, A = v.A } end)
        if ok and type(r.R) == "number" then return r end
    end
    return v
end

return env

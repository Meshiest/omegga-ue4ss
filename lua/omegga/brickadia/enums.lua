-- BR.enums: The names the API takes as strings (brick assets, items, rule kinds,
-- explosions, permissions...), listed from the running game, and written out as
-- LuaLS aliases so an editor completes them.
--
-- The lists come from what the game has loaded: a dedicated server loads its
-- whole brick and item catalog, so they are complete once the world is up.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local enums = {}

local function sorted_keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- names of loaded objects of `class_path` (instances, or with `subclasses`
-- the classes deriving from it), without the "Default__" objects
local function loaded(class_path, subclasses, strip)
    local base = StaticFindObject(class_path)
    assert(base and base:IsValid(), "no class " .. class_path)
    local class = StaticFindObject("/Script/CoreUObject.Class")
    local seen = {}
    ForEachUObject(function(o)
        local name = o:GetFName():ToString()
        if name:find("^Default__") or name:find("^SKEL_") or name:find("^REINST_") then return end
        if subclasses then
            if o:IsA(class) and o ~= base and o:IsChildOf(base) then
                seen[strip and (name:gsub(strip, "")) or name] = true
            end
        elseif o:IsA(base) then
            seen[name] = true
        end
    end)
    return sorted_keys(seen)
end

local function emoji()
    local gi = FindFirstOf("BRGameInstance")
    if not gi or not gi:IsValid() then return {} end
    local rows = {}
    StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary"):GetDataTableRowNames(gi.EmojiSet, rows)
    local out = {}
    for i = 1, #rows do out[i] = rows[i]:get():ToString() end
    table.sort(out)
    return out
end

--- Every list, by kind: the alias it becomes, what takes it, and how it is found.
enums.KINDS = {
    { kind = "brick_asset", alias = "BR.BrickAsset", doc = "a brick asset name (BR.brick.asset, BR.brick.builder's asset)",
      list = function() return loaded("/Script/Brickadia.BrickAsset") end },
    { kind = "component", alias = "BR.ComponentType", doc = "a component type name (BR.component.type)",
      list = function()
          local out = {}
          for _, t in ipairs(BR.component.types()) do out[#out + 1] = t:GetFName():ToString() end
          table.sort(out)
          return out
      end },
    { kind = "item", alias = "BR.Item", doc = "an item class name without _C (BR.player.give, BR.bot.give)",
      list = function()
          -- the abstract bases (BRItemBase, BP_ItemBase...) can't be given
          local out = {}
          for _, n in ipairs(loaded("/Script/Brickadia.BRItemBase", true, "_C$")) do
              if not n:find("Base$") and not n:find("^BR") then out[#out + 1] = n end
          end
          return out
      end },
    { kind = "entity", alias = "BR.EntityClass", doc = "an entity class name without _C (BR.entity.spawn, tx.place_entity)",
      list = function()
          local out = {}
          for _, n in ipairs(loaded("/Script/Brickadia.BREntityTypeBase", true, "_C$")) do
              if not n:find("^BR") then out[#out + 1] = n end
          end
          return out
      end },
    { kind = "explosion", alias = "BR.Explosion", doc = "an explosion kind (BR.world.explode's kind)",
      list = function() return BR.world.explosion_kinds() end },
    { kind = "team_rule", alias = "BR.TeamRule", doc = "a team rule kind (BR.team.rule, BR.world.rule)",
      list = function() return BR.team.rule_kinds() end },
    { kind = "game_rule", alias = "BR.GameRule", doc = "a game-wide rule kind (BR.world.rule)",
      list = function() return BR.world.rule_kinds() end },
    { kind = "permission", alias = "BR.Permission", doc = "a game permission tag (BR.perm)",
      list = function() return BR.perm.game_tags() end },
    { kind = "material", alias = "BR.Material", doc = "a brick material (BR.brick.MATERIAL)",
      list = function() return sorted_keys(BR.brick.MATERIAL) end },
    { kind = "collision", alias = "BR.Collision", doc = "a brick collision channel (BR.brick.COLLISION)",
      list = function() return sorted_keys(BR.brick.COLLISION) end },
    { kind = "emote", alias = "BR.Emote", doc = "an emote (BR.act.EMOTE)",
      list = function() return sorted_keys(BR.act.EMOTE) end },
    { kind = "emoji", alias = "BR.Emoji", doc = "a chat emoji name, as :name: in chat",
      list = emoji },
    { kind = "sound", alias = "BR.Sound", doc = "a sound (BR.sound.play, BR.sound.at)",
      list = function() return BR.sound.list() end },
    { kind = "font", alias = "BR.Font", doc = "a font (BR.ui's font)",
      list = function() return loaded("/Script/Brickadia.BrickFontDescriptor") end },
}

--- The names of one kind (see enums.KINDS), sorted.
function enums.list(kind)
    for _, k in ipairs(enums.KINDS) do
        if k.kind == kind then return k.list() end
    end
    error("no enum kind " .. tostring(kind), 2)
end

--- Every kind's names: { [kind] = { names } }.
function enums.all()
    local out = {}
    for _, k in ipairs(enums.KINDS) do out[k.kind] = k.list() end
    return out
end

local function quote(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end

--- The lists as a LuaLS definition file: one `---@alias` per kind, so a
--- parameter typed BR.BrickAsset completes the game's names. `build` names the
--- game build they came from, for the header (default: BR.server.build()).
function enums.render(build)
    build = build or BR.server.build()
    local lines = {
        "---@meta",
        "-- Generated by BR.enums.render" .. (build and (" from " .. build) or "") .. " (npm run enums); regenerate after a game update.",
        "",
    }
    for _, k in ipairs(enums.KINDS) do
        local names = k.list()
        lines[#lines + 1] = "--- " .. k.doc .. " (" .. #names .. ")"
        if #names == 0 then
            lines[#lines + 1] = "---@alias " .. k.alias .. " string"
        else
            lines[#lines + 1] = "---@alias " .. k.alias
            for _, n in ipairs(names) do lines[#lines + 1] = "---| " .. quote(n) end
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

--- Write enums.render's file to `path`. Returns the number of names written.
function enums.write(path, build)
    local text = enums.render(build)
    local tmp = path .. ".tmp"
    local f = assert(io.open(tmp, "wb"))
    f:write(text)
    f:close()
    assert(os.rename(tmp, path))
    local _, n = text:gsub("\n%-%-%-| ", "")
    return n
end

return enums

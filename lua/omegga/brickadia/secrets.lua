-- BR.secrets: Values a server admin supplies to mods (webhook URLs, API keys,
-- tuning) without putting them in the mod's code or its store. They live in
-- Saved/LuaSecrets.json, which the admin edits and nothing in Lua writes:
--
--   { "discord.webhook": "https://...", "arena.rounds": 5 }
--
-- Keys are any strings; a dotted prefix per mod keeps them apart. The file is
-- read again when it changes, so an edit takes effect without a restart.
local json = require("omegga.json")
local secrets = {}

local cache, stamp

local function file()
    return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString()
        .. "LuaSecrets.json"
end

local function load()
    local f = io.open(file(), "rb")
    if not f then
        cache, stamp = {}, nil
        return cache
    end
    local text = f:read("a")
    f:close()
    -- the content itself tells whether it changed: Lua can't read a file's mtime
    if text == stamp then return cache end
    local ok, value = pcall(json.decode, text)
    if not ok or type(value) ~= "table" then
        print("[BR.secrets] LuaSecrets.json is not a JSON object; no secrets until it is\n")
        value = {}
    end
    cache, stamp = value, text
    return cache
end

--- The value the admin set for `key`, or `default` when there is none.
function secrets.get(key, default)
    local v = load()[key]
    if v == nil then return default end
    return v
end

--- Like get, but an error naming the key and the file when it isn't set: for
--- values a mod can't run without.
function secrets.require(key)
    local v = load()[key]
    if v == nil then error("no secret " .. key .. " (set it in " .. file() .. ")", 2) end
    return v
end

--- Where the admin keeps them.
function secrets.path() return file() end

return secrets

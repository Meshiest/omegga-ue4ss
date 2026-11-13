-- BR.config: Settings a server admin edits for a mod, in LuaConfig/<name>.json
-- in omegga's data directory. The file is written with the mod's defaults the
-- first time (and when a later version adds a setting), so it always lists
-- every setting with its current value. An edit takes effect without a
-- restart: the file is read again when it changes (checked at most every 2 s).
local json = require("omegga.json")
local config = {}

-- set by the plugin's launch env, so configs land in omegga's data directory
-- wherever the game keeps its own Saved files
local function dir()
    local d = os.getenv("OMEGGA_UE4SS_CONFIG")
    assert(d and d ~= "", "OMEGGA_UE4SS_CONFIG isn't set; was the server started by the ue4ss omegga plugin?")
    return d .. "/"
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

local function write(path, values)
    local folder = path:match("^(.*/)")
    local probe = io.open(folder .. ".probe", "wb")
    if not probe then
        os.execute("mkdir -p '" .. folder:gsub("'", "'\\''") .. "'")
        probe = io.open(folder .. ".probe", "wb")
    end
    if probe then probe:close() end
    local f = assert(io.open(path .. ".tmp", "wb"))
    f:write(json.encode(values))
    f:close()
    assert(os.rename(path .. ".tmp", path))
end

--- The settings `name` (letters, digits, '_', '-', '.') with `defaults` for the
--- ones the admin hasn't set: c.get(key), c.all() (a copy of every setting),
--- c.path(). A setting the file has but `defaults` doesn't is kept and returned.
---
---   local cfg = BR.config.open("arena", { rounds = 5, prize = "Pistol" })
---   for i = 1, cfg.get("rounds") do ... end
function config.open(name, defaults)
    assert(type(name) == "string" and name:match("^[%w_%-%.]+$") and not name:match("^%."),
        "a config name is letters, digits, '_', '-' and '.'")
    defaults = defaults or {}
    local path = dir() .. name .. ".json"
    local values, text_seen, checked = {}, nil, -math.huge

    local function refresh(force)
        local now = os.time()
        if not force and now - checked < 2 then return end
        checked = now
        local text = read(path)
        if text == text_seen and not force then return end
        text_seen = text
        local ok, parsed = pcall(json.decode, text or "")
        if not ok or type(parsed) ~= "table" then
            if text then print("[BR.config] " .. name .. ".json is not a JSON object; using the defaults\n") end
            parsed = {}
        end
        local merged, missing = {}, false
        for k, v in pairs(defaults) do
            if parsed[k] == nil then merged[k], missing = v, true else merged[k] = parsed[k] end
        end
        for k, v in pairs(parsed) do if merged[k] == nil then merged[k] = v end end
        values = merged
        -- a new or incomplete file gets every setting written out for the admin
        if (not text or missing) and (ok or not text) then
            write(path, merged)
            text_seen = read(path)
        end
    end
    refresh(true)

    local c = {}
    function c.get(key)
        refresh(false)
        return values[key]
    end
    function c.all()
        refresh(false)
        local out = {}
        for k, v in pairs(values) do out[k] = v end
        return out
    end
    function c.path() return path end
    return c
end

return config

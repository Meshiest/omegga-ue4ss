-- BR.server: Server-wide chat, console commands, logs and permission roles.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local single = I.single
local server = {}

function server.chat(message) BR.world.game_mode():PushChatMessage(message) end

function server.console(command)
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(BR.world.game_mode(), command, nil)
end

--- The last `n` lines of the server log that contain `pattern` (plain text).
function server.log_tail(n, pattern)
    local saved = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString()
    local f = assert(io.open(saved .. "Logs/Brickadia.log", "rb"))
    local lines = {}
    for line in f:lines() do
        if not pattern or line:find(pattern, 1, true) then
            lines[#lines + 1] = (line:gsub("\r$", ""))
            if #lines > n then table.remove(lines, 1) end
        end
    end
    f:close()
    return lines
end

--- The current world's name ("build", "arena/v2": its path under
--- Saved/Worlds without .brdb), from the last world bundle the game logged
--- opening, else the -World it was started with; nil if neither says.
function server.world()
    local name
    for _, line in ipairs(server.log_tail(50, "bundle at ")) do
        local w = line:match("bundle at .-/Worlds/(.-)%.brdb")
        if w then name = w end
    end
    if name then return name end
    local f = io.open("/proc/self/cmdline", "rb")
    if f then
        local cmd = f:read("a"):gsub("%z", " ")
        f:close()
        name = cmd:match('%-World="([^"]+)"') or cmd:match("%-World=(%S+)")
    end
    return name
end

--- The game build ("Release-EA3-CL-16507"), from the line the game logs at
--- startup, or nil if the log doesn't have it.
function server.build()
    local saved = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory():ToString()
    local f = io.open(saved .. "Logs/Brickadia.log", "rb")
    if not f then return nil end
    for line in f:lines() do
        local build = line:match("^LogInit: Build: (%S+)")
        if build then
            f:close()
            return build
        end
    end
    f:close()
end

--- The watchdog's budget in milliseconds: a mod callback the bridge runs
--- (ticks, timers, event handlers, hooks) that takes longer is stopped with a
--- Lua error, reported like any other, so an endless loop doesn't freeze the
--- server. Default 5000. Pass a number to change it (0 turns it off); returns
--- the budget before.
function server.watchdog(ms) return __watchdog(ms) end

function server.roles()
    local pm = single("BRPermissionsManager")
    local roles = { pm.OwnerRole.Name:ToString(), pm.DefaultRole.Name:ToString() }
    pm.CustomRoles:ForEach(function(_, role) roles[#roles + 1] = role:get().Name:ToString() end)
    return roles
end

-- frame times over the last second, measured from the tick listener below
_G.BR_SERVER_FRAMES = _G.BR_SERVER_FRAMES or { list = {}, sum = 0 }
local frames = _G.BR_SERVER_FRAMES
local function watch_frames()
    if frames.stop then return end
    frames.stop = BR.event.tick(function(dt)
        local list = frames.list
        list[#list + 1] = dt
        frames.sum = frames.sum + dt
        while frames.sum > 1 and #list > 1 do frames.sum = frames.sum - table.remove(list, 1) end
    end)
end

--- How the server is doing: players and bots connected, bricks on the world
--- grid, dynamic grids, ticks per second and the slowest frame over the last
--- second (ms; measured from the first call on), uptime (seconds of game
--- time), and the Lua memory of this state (KB).
function server.stats()
    watch_frames()
    local lib = StaticFindObject("/Script/Brickadia.Default__BRLuauGridLibrary")
    local bricks = string.unpack("<i4", BR.raw.call(lib, "BRLuauGridLibrary", "GetCount", { Self = BR.raw.ptr(BR.world.global_grid()) }).ReturnValue)
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local grids = {}
    GS:GetAllActorsOfClass(BR.world.context(), StaticFindObject("/Script/Brickadia.BrickGridDynamicActor"), grids)
    local slowest = 0
    for _, dt in ipairs(frames.list) do slowest = math.max(slowest, dt) end
    return {
        players = #BR.player.list(),
        bots = #BR.bot.list(),
        bricks = bricks,
        grids = #grids,
        tick_rate = frames.sum > 0 and (#frames.list / frames.sum) or nil,
        slowest_frame_ms = #frames.list > 0 and slowest * 1000 or nil,
        uptime = GS:GetTimeSeconds(BR.world.context()),
        lua_kb = collectgarbage("count"),
    }
end

return server

-- BR.voice: Audio through voice chat, as if a player said it. Brickadia's voice
-- chat runs in native code with no UFunctions: each client's voice channel hands
-- the server Opus frames, and a routing function sends them on to every client in
-- earshot, who hear them from the talker's character (distance, voice effects and
-- mutes included). BR.voice calls that routing function with frames of its own
-- (__voice_route), so any player, a bot included, can be made to speak.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local voice = {}

-- The routing function isn't reflected. The voice channel's ReceivedBunch (vtable
-- slot 91 of UBRVoiceChannel) calls it with every frame a client sends, as
--   mov rcx, [rsp+0x30]; mov r8d, [rsp+0x10]; lea rdx, [rsp+0x20]; call route
-- (position, talk burst, frame), which is what this looks for.
local RECEIVED_BUNCH_SLOT = 91
local CALL_SITE = "\x48\x8b\x4c\x24\x30\x44\x8b\x44\x24\x10\x48\x8d\x54\x24\x20\xe8"
local SCAN_BYTES = 0x800

-- Brickadia's voice frames are 20 ms of 24 kHz mono, counted in samples
voice.FRAME_SECONDS = 0.02
local FRAME_SAMPLES = 480

local route_address
local function route()
    if route_address then return route_address end
    local cdo = StaticFindObject("/Script/Brickadia.Default__BRVoiceChannel")
    if not (cdo and cdo:IsValid()) then error("no BRVoiceChannel class", 3) end
    local vtable = string.unpack("<I8", __peek(__addr(cdo), 8))
    local received = string.unpack("<I8", __peek(vtable + RECEIVED_BUNCH_SLOT * 8, 8))
    local code = __peek(received, SCAN_BYTES)
    local at = code:find(CALL_SITE, 1, true)
    if not at then error("the voice routing call wasn't found; the game changed", 3) end
    -- call rel32: the target is relative to the end of the instruction
    local rel = string.unpack("<i4", code, at + #CALL_SITE)
    route_address = received + (at - 1) + #CALL_SITE + 4 + rel
    return route_address
end

--- The Opus frames (packets) in an Ogg Opus file, as made by
---   ffmpeg -i <audio> -ac 1 -ar 24000 -c:a libopus -frame_duration 20 -application voip <out.ogg>
--- The two header packets are left out.
function voice.ogg_frames(path)
    local f = io.open(path, "rb")
    if not f then error("can't open " .. tostring(path), 2) end
    local data = f:read("a")
    f:close()
    local packets, partial, at = {}, "", 1
    while at <= #data do
        if data:sub(at, at + 3) ~= "OggS" then error("not an Ogg file: " .. path, 2) end
        -- page header: 27 bytes, the segment count last, then the segment table
        local segments = data:byte(at + 26)
        local body = at + 27 + segments
        for i = 0, segments - 1 do
            local len = data:byte(at + 27 + i)
            partial = partial .. data:sub(body, body + len - 1)
            body = body + len
            -- a segment shorter than 255 ends its packet
            if len < 255 then
                packets[#packets + 1] = partial
                partial = ""
            end
        end
        at = body
    end
    -- OpusHead and OpusTags
    table.remove(packets, 1)
    table.remove(packets, 1)
    return packets
end

-- per talker, by PlayerState address: where its sample count and talk burst are
_G.BR_VOICE_TALKERS = _G.BR_VOICE_TALKERS or {}
local talkers = _G.BR_VOICE_TALKERS

--- Have `ps` (any player's PlayerState, a bot's included) say `frames` (Opus
--- frames, e.g. from BR.voice.ogg_frames), one every 20 ms like a microphone
--- would send them. Players near the talker's character hear it from there, as
--- they hear the player's own voice. opts.done(ps) runs after the last frame.
--- Returns a function that stops it.
function voice.say(ps, frames, opts)
    opts = opts or {}
    if #frames == 0 then error("no frames", 2) end
    local fn = route()
    local key = __addr(ps)
    local t = talkers[key] or { position = 0, burst = 0 }
    talkers[key] = t
    -- a new talk burst, as when a player presses push-to-talk again
    t.burst = t.burst + 1
    local sent, elapsed = 0, 0
    local stop
    local function finish()
        stop()
        if opts.done then
            local ok, err = pcall(opts.done, ps)
            if not ok then I.report("BR.voice.say", err) end
        end
    end
    stop = BR.event.tick(function(dt)
        if not ps:IsValid() then return stop() end
        elapsed = elapsed + dt
        local due = math.min(#frames, math.floor(elapsed / voice.FRAME_SECONDS) + 1)
        while sent < due do
            sent = sent + 1
            __voice_route(fn, BR.world.context(), ps, frames[sent], t.position, t.burst)
            t.position = t.position + FRAME_SAMPLES
        end
        if sent >= #frames then finish() end
    end)
    return stop
end

--- Say an Ogg Opus file (see BR.voice.ogg_frames for making one).
function voice.play(ps, path, opts)
    return voice.say(ps, voice.ogg_frames(path), opts)
end

-- Capture: the bridge copies every frame the routing function routes (a
-- client's, or BR.voice's own) and hands them over each tick. One tick handler
-- per server feeds every capture listener; in _G so a BR_RELOAD keeps them.
_G.BR_VOICE_LISTENERS = _G.BR_VOICE_LISTENERS or {}
local listeners = _G.BR_VOICE_LISTENERS
local token = {}

local function pump()
    local d = _G.BR_VOICE_PUMP
    if d and d.token == token then return end
    if d then d.stop() end
    __voice_capture(route())
    -- the bridge keeps copying frames once capture has started, listener or
    -- not: drop what piled up before this pump, and keep draining while
    -- nobody listens, so a new listener never gets someone's old speech
    __voice_take()
    _G.BR_VOICE_PUMP = { token = token, stop = BR.event.tick(function()
        local frames = __voice_take()
        if #frames == 0 or next(listeners) == nil then return end
        for _, f in ipairs(frames) do
            if f.talker and f.talker:IsValid() then
                for _, fn in pairs(listeners) do
                    local ok, err = pcall(fn, f.talker, f.frame, f.position, f.burst)
                    if not ok then I.report("BR.voice.capture", err) end
                end
            end
        end
    end) }
end

--- Call fn(ps, frame, position, burst) for every voice frame anyone says (a
--- player's, or BR.voice's own): `frame` is the Opus frame as sent, `position`
--- the talker's running sample count and `burst` their talk-burst counter.
--- Returns a function that stops it.
function voice.capture(fn)
    local key = {}
    listeners[key] = fn
    pump()
    return function() listeners[key] = nil end
end

-- Opus frame length in 48 kHz samples, from the packet's TOC byte (RFC 6716 3.1):
-- the config picks the frame duration, the code how many frames the packet holds
local DURATIONS = { -- in 48 kHz samples, by config // 4 groups
    silk = { 480, 960, 1920, 2880 }, hybrid = { 480, 960 }, celt = { 120, 240, 480, 960 },
}
local function opus_samples(frame)
    local toc = frame:byte(1)
    local config = toc >> 3
    local per
    if config < 12 then per = DURATIONS.silk[config % 4 + 1]
    elseif config < 16 then per = DURATIONS.hybrid[config % 2 + 1]
    else per = DURATIONS.celt[config % 4 + 1] end
    local code = toc & 3
    local count = code == 0 and 1 or (code == 3 and ((frame:byte(2) or 0) & 0x3f) or 2)
    return per * count
end

-- Ogg's CRC32: polynomial 0x04c11db7, not reflected, initial 0
local crc_table
local function ogg_crc(data)
    if not crc_table then
        crc_table = {}
        for i = 0, 255 do
            local r = i << 24
            for _ = 1, 8 do
                r = (r & 0x80000000) ~= 0 and ((r << 1) ~ 0x04c11db7) or (r << 1)
            end
            crc_table[i] = r & 0xffffffff
        end
    end
    local crc = 0
    for i = 1, #data do
        crc = ((crc << 8) & 0xffffffff) ~ crc_table[((crc >> 24) ~ data:byte(i)) & 0xff]
    end
    return crc
end

-- one Ogg page holding one packet
local function ogg_page(packet, granule, serial, sequence, flags)
    local lacing = {}
    local n = #packet
    while n >= 255 do
        lacing[#lacing + 1] = string.char(255)
        n = n - 255
    end
    lacing[#lacing + 1] = string.char(n)
    local head = "OggS" .. string.pack("<BBi8I4I4I4B", 0, flags, granule, serial, sequence, 0, #lacing)
    local page = head .. table.concat(lacing) .. packet
    local crc = ogg_crc(page)
    return page:sub(1, 22) .. string.pack("<I4", crc) .. page:sub(27)
end

--- Write Opus frames as an Ogg Opus file any audio player opens.
function voice.write_ogg(path, frames)
    local serial = math.random(0, 0x7fffffff)
    -- OpusHead: version 1, mono, no pre-skip, 24 kHz input, no gain, mapping 0
    local out = { ogg_page("OpusHead" .. string.pack("<BBI2I4i2B", 1, 1, 0, 24000, 0, 0), 0, serial, 0, 2) }
    out[2] = ogg_page("OpusTags" .. string.pack("<I4", 12) .. "omegga-ue4ss" .. string.pack("<I4", 0), 0, serial, 1, 0)
    local granule = 0
    for i, frame in ipairs(frames) do
        granule = granule + opus_samples(frame)
        out[#out + 1] = ogg_page(frame, granule, serial, i + 1, i == #frames and 4 or 0)
    end
    local f = io.open(path, "wb")
    if not f then error("can't write " .. tostring(path), 2) end
    f:write(table.concat(out))
    f:close()
end

-- the recorder's buffers, by PlayerState address: { name, id, frames = { { at, frame } } }
_G.BR_VOICE_RECORDINGS = _G.BR_VOICE_RECORDINGS or {}
local recordings = _G.BR_VOICE_RECORDINGS

--- Keep the last opts.seconds (default 60) of everything each player says, for
--- BR.voice.clip; older speech, a departed player's included, is dropped.
--- Returns a function that stops recording (the buffers stay as they are).
function voice.recorder(opts)
    opts = opts or {}
    local keep = opts.seconds or 60
    local clock = 0
    local stop_tick = BR.event.tick(function(dt)
        clock = clock + dt
        for key, r in pairs(recordings) do
            while #r.frames > 0 and clock - r.frames[1].at > keep do table.remove(r.frames, 1) end
            if #r.frames == 0 then recordings[key] = nil end
        end
    end)
    local stop_capture = voice.capture(function(ps, frame)
        local key = __addr(ps)
        local ok, info = pcall(BR.player.info, ps)
        local name, id = ok and (info.display_name or info.name) or nil, ok and info.id or nil
        local r = recordings[key]
        -- a PlayerState can reuse a departed player's address; never mix two
        -- people's speech in one recording
        if not r or r.name ~= name or r.id ~= id then
            r = { frames = {}, name = name, id = id }
            recordings[key] = r
        end
        r.frames[#r.frames + 1] = { at = clock, frame = frame }
    end)
    return function()
        stop_tick()
        stop_capture()
    end
end

--- What the recorder holds: { key, name, id, seconds } per player, including
--- players who have since left (clip those by key).
function voice.recorded()
    local out = {}
    for key, r in pairs(recordings) do
        local samples = 0
        for _, f in ipairs(r.frames) do samples = samples + opus_samples(f.frame) end
        out[#out + 1] = { key = key, name = r.name, id = r.id, seconds = samples / 48000 }
    end
    return out
end

--- Write what the recorder holds for a player (`who`: their PlayerState, or a
--- key from BR.voice.recorded) to an Ogg Opus file at `path`: the last
--- opts.seconds of it, default all. Silence between talk bursts is left out.
--- Returns how many seconds of speech it wrote, or nil when there is none.
function voice.clip(who, path, opts)
    opts = opts or {}
    local r = recordings[type(who) == "number" and who or __addr(who)]
    if not r or #r.frames == 0 then return nil end
    local since = opts.seconds and (r.frames[#r.frames].at - opts.seconds) or -math.huge
    local frames, samples = {}, 0
    for _, f in ipairs(r.frames) do
        if f.at >= since then
            frames[#frames + 1] = f.frame
            samples = samples + opus_samples(f.frame)
        end
    end
    if #frames == 0 then return nil end
    voice.write_ogg(path, frames)
    return samples / 48000
end

return voice

-- BR.ui: Text and panels on players' screens, drawn with the call the Controller
-- Display Text gate makes (ClientDisplayText), with no gate in the world.
--
-- Each element keeps its whole state here and is resent in full on every
-- change, since the client replaces an element (by its PersistentId) with what
-- it is sent. A change sent with a transition animates from the old state to
-- the new one on the client, so moving, growing, recolouring or fading
-- something is one call. Elements shown to "all" are also sent to players who
-- join later.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local ui = {}

--- Screen anchors by name, as {x, y} fractions of the screen.
ui.ANCHOR = {
    top_left = { 0, 0 }, top = { 0.5, 0 }, top_right = { 1, 0 },
    left = { 0, 0.5 }, center = { 0.5, 0.5 }, right = { 1, 0.5 },
    bottom_left = { 0, 1 }, bottom = { 0.5, 1 }, bottom_right = { 1, 1 },
}
ui.EASING = { linear = 0, ease_in = 1, ease_out = 2, ease_in_out = 3 }
ui.ALIGN = { left = 0, center = 1, right = 2 }
ui.TYPEFACE = { regular = 0, bold = 1, italic = 2, bold_italic = 3 }

-- Size of the "█" glyph at FontSize 100, in screen units at 1080p, which a
-- panel is scaled from (measured for TTT's role card).
local BLOCK, BLOCK_W, BLOCK_H = "█", 80, 156

local function vec(v, names, what)
    if type(v) == "string" then v = names and names[v] or error("no " .. what .. " " .. v, 3) end
    if type(v) == "number" then return { X = v, Y = v } end
    return { X = v[1] or v.x or 0, Y = v[2] or v.y or 0 }
end

local function color(c)
    if c == nil then return nil end
    if type(c) == "string" then
        local hex = c:gsub("^#", "")
        c = { tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16), #hex >= 8 and tonumber(hex:sub(7, 8), 16) or 255 }
    end
    return { R = c[1], G = c[2], B = c[3], A = c[4] or 255 }
end

local function lookup(map, v, what)
    if v == nil or type(v) == "number" then return v end
    return map[v] or error("no " .. what .. " " .. tostring(v), 3)
end

local fonts = {}
local function font(name)
    if name == nil or type(name) ~= "string" then return name end
    local f = fonts[name]
    if f and f:IsValid() then return f end
    f = StaticFindObject("/Game/UI/Shared/Fonts/" .. name .. "." .. name)
    assert(f and f:IsValid(), "no font " .. name .. " (BR.enums.list(\"font\") lists them)")
    fonts[name] = f
    return f
end

-- an element's options as BRDisplayTextParams
local function params(id, o, motion)
    local anchor = vec(o.anchor or "top_left", ui.ANCHOR, "anchor")
    local p = {
        PersistentId = id,
        Text = o.text or "",
        Anchor = anchor,
        Position = { X = o.x or 0, Y = o.y or 0 },
        -- by default an element hangs off its anchor the way the anchor implies:
        -- a "bottom_right" element grows up and left from its point
        Pivot = o.pivot and vec(o.pivot, ui.ANCHOR, "pivot") or anchor,
        Scale = vec(o.scale or 1),
        Angle = o.angle or 0,
        ZOrder = o.z or 0,
        FontSize = o.size or 24,
        FontColor = color(o.color or { 255, 255, 255, 255 }),
        OutlineSize = o.outline or 0,
        OutlineColor = color(o.outline_color or { 0, 0, 0, 255 }),
        WrapWidth = o.wrap or 0,
        Justification = lookup(ui.ALIGN, o.align, "align") or 0,
        Typeface = lookup(ui.TYPEFACE, o.typeface, "typeface") or 0,
        LetterSpacing = o.spacing or 0,
        Skew = o.skew or 0,
        LineHeight = o.line_height or 1,
        Lifetime = o.lifetime or 0,
        Transition = motion and motion.transition or 0,
        Easing = lookup(ui.EASING, motion and motion.easing, "easing") or 0,
    }
    if o.shadow then
        p.ShadowOffset = vec(o.shadow)
        p.ShadowColor = color(o.shadow_color or { 0, 0, 0, 160 })
    end
    if o.font then p.Font = font(o.font) end
    return p
end

-- a panel is a scaled block glyph tinted with the font colour
local function panel_opts(o)
    local out = {}
    for k, v in pairs(o) do out[k] = v end
    out.text, out.size, out.outline = BLOCK, 100, 0
    out.scale = { (o.w or 100) / BLOCK_W, (o.h or 100) / BLOCK_H }
    return out
end

-- State that outlives a reload of this module: elements shown to everyone,
-- replayed to players who join, and the next free id.
_G.BR_UI = _G.BR_UI or { next_id = 1100000, global = {} }
local state = _G.BR_UI

local function targets(target)
    if target == "all" then return BR.player.list() end
    if type(target) == "table" then return target end
    return { target }
end

-- The client keeps at most 32 display texts. One with a new id when it already
-- has 32 makes it drop the oldest, silently (ABRPlayerController's
-- ClientDisplayText handler; the number is compiled into the client, so the
-- server can't raise it). Updating an id it has doesn't count. To say when that
-- happens, every ClientDisplayText and ClientRemoveDisplayText the server sends
-- is mirrored here, the world's Display Text gates' included.
ui.LIMIT = 32
state.screens = state.screens or {}
local ADD = "/Script/Brickadia.BRPlayerController:ClientDisplayText"
local REMOVE = "/Script/Brickadia.BRPlayerController:ClientRemoveDisplayText"
-- PersistentId and Lifetime in FBRDisplayTextParams (ClientDisplayText's only
-- parameter), found by name so a game update that moves them doesn't break this
-- (looked up on the first text, not while modules load: the world isn't there yet)
local ID_AT, LIFETIME_AT
local function text_offsets()
    if ID_AT then return ID_AT, LIFETIME_AT end
    local st = StaticFindObject("/Script/Brickadia.BRDisplayTextParams")
    assert(st and st:IsValid(), "no BRDisplayTextParams")
    local base = I.layout(ADD).Params.offset
    ID_AT = base + I.find_field(st, "PersistentId"):GetOffset_Internal()
    LIFETIME_AT = base + I.find_field(st, "Lifetime"):GetOffset_Internal()
    return ID_AT, LIFETIME_AT
end

-- a controller's texts, oldest first: { id, expires (os.time) or false }
local function live(key)
    local list = state.screens[key] or {}
    state.screens[key] = list
    local now = os.time()
    for i = #list, 1, -1 do
        if list[i].expires and list[i].expires <= now then table.remove(list, i) end
    end
    return list
end

local function count_texts()
    if state.counting then return end
    state.counting = true
    BR.event.hook(ADD, function(pc, params)
        local id_at, lifetime_at = text_offsets()
        local id = string.unpack("<i4", params, id_at + 1)
        local lifetime = string.unpack("<f", params, lifetime_at + 1)
        local list = live(__addr(pc))
        local entry
        for _, e in ipairs(list) do if e.id == id then entry = e end end
        if not entry then
            if #list >= ui.LIMIT then
                local dropped = table.remove(list, 1)
                local now = os.time()
                -- at most one line a minute: a gate firing every tick must not
                -- flood the log, and this runs inside every text the server sends,
                -- so it never scans for the gate (BR.ui.sources does, when asked)
                if (state.warned or 0) + 60 <= now then
                    state.warned = now
                    local ps = pc.PlayerState
                    local who = (ps and ps:IsValid()) and BR.player.info(ps).display_name or "a player"
                    I.report("BR.ui", string.format("%s has %d texts on screen, the most a client keeps; text %d%s replaced the oldest (%d). BR.ui.sources(%d) names the gate that sent it",
                        who, ui.LIMIT, id, state.sending and " from BR.ui" or "", dropped.id, id))
                end
            end
            entry = { id = id, ours = state.sending == true }
            list[#list + 1] = entry
        end
        entry.expires = lifetime > 0 and (os.time() + math.ceil(lifetime)) or false
    end)
    BR.event.hook(REMOVE, function(pc, params)
        local id = string.unpack("<i4", params, 1)
        local list = live(__addr(pc))
        for i, e in ipairs(list) do if e.id == id then table.remove(list, i) break end end
    end)
    -- a player who leaves takes their screen along
    BR.event.on("leave", function(ps)
        -- the game can report a leave whose PlayerState is already gone
        if not (ps and ps:IsValid()) then return end
        local pc = BR.player.controller(ps)
        if pc then state.screens[__addr(pc)] = nil end
    end)
end
count_texts()

--- How many display texts a player's client holds now (of BR.ui.LIMIT): BR.ui's
--- and the world's Display Text gates', counted since this module loaded.
function ui.count(ps)
    local pc = BR.player.controller(ps)
    return pc and #live(__addr(pc)) or 0
end

-- the world's Display Text gates, found by scanning every brick (about 90 ms
-- for 5,000 bricks), so kept for a while
local GATE = "BrickComponentType_Exec_PlayerState_DisplayText"
local function gates(refresh)
    local now = os.time()
    if refresh or not state.gates or now - state.gates.at > 30 then
        local t = BR.component.type(GATE)
        local found = {}
        local all = BR.brick.in_box({ -2000000000, -2000000000, -2000000000 }, { 2000000000, 2000000000, 2000000000 }, { max = 1000000 })
        for _, h in ipairs(all) do
            if BR.component.handle(h, t) then found[#found + 1] = h end
        end
        state.gates = { at = now, list = found, type = t }
    end
    return state.gates
end

--- The Display Text gates that send text `id` (the gate's TextId, or the id it
--- last used, TextIdOut), each as { brick, owner } with owner as
--- BR.brick.owner gives it: for finding who puts text on players' screens.
--- opts.refresh rescans the world rather than use the list from the last 30 s.
function ui.sources(id, opts)
    local g = gates(opts and opts.refresh)
    local out = {}
    for _, h in ipairs(g.list) do
        if BR.brick.valid(h) then
            local ok, a, b = pcall(function()
                return BR.component.get(h, g.type, "TextId"), BR.component.get(h, g.type, "TextIdOut")
            end)
            if ok and (a == id or b == id) then out[#out + 1] = { brick = h, owner = BR.brick.owner(h) } end
        end
    end
    return out
end

--- The display texts a player's client holds, oldest first: { id, expires (an
--- os.time, or false), from = "BR.ui" or "world" }. With opts.sources, each
--- world text also gets `sources` (BR.ui.sources).
function ui.texts(ps, opts)
    local pc = BR.player.controller(ps)
    local out = {}
    for _, e in ipairs(pc and live(__addr(pc)) or {}) do
        local t = { id = e.id, expires = e.expires, from = e.ours and "BR.ui" or "world" }
        if opts and opts.sources and not e.ours then t.sources = ui.sources(e.id) end
        out[#out + 1] = t
    end
    return out
end

local function send(ps, p)
    if not BR.player.connected(ps) then return end
    -- the hook above files what it sees during this call as BR.ui's own
    state.sending = true
    local ok, err = pcall(function() BR.player.controller(ps):ClientDisplayText(p) end)
    state.sending = false
    if not ok then error(err, 0) end
end

-- players who join get every element shown to "all", once their client is up;
-- hooked when the first such element is made, so loading this module costs nothing
local function watch_joins()
    if state.joins then return end
    state.joins = BR.event.on("join", function(ps)
        BR.timer.after(2, function()
            for _, el in pairs(state.global) do el:show_to(ps) end
        end, { owner = ps })
    end)
end

local function element(target, opts, panel)
    assert(type(opts) == "table", "an element needs options")
    local id = opts.id
    if not id then
        id = state.next_id
        state.next_id = state.next_id + 1
    end
    local el = { id = id, opts = {}, target = target }
    for k, v in pairs(opts) do el.opts[k] = v end
    local function render(motion) return params(id, panel and panel_opts(el.opts) or el.opts, motion) end
    local function show(motion)
        local p = render(motion)
        for _, ps in ipairs(targets(el.target)) do send(ps, p) end
    end

    --- Change some options and resend; motion = { transition = seconds, easing =
    --- "ease_out" } animates from the old state to the new one.
    function el:set(changes, motion)
        for k, v in pairs(changes or {}) do el.opts[k] = v end
        show(motion)
        return el
    end

    --- Move to (x, y), over `seconds` if given.
    function el:move(x, y, seconds, easing)
        return el:set({ x = x, y = y }, { transition = seconds, easing = easing })
    end

    --- Take it off the screen.
    function el:remove()
        for _, ps in ipairs(targets(el.target)) do
            if BR.player.connected(ps) then BR.player.controller(ps):ClientRemoveDisplayText(id) end
        end
        state.global[id] = nil
    end

    --- Send it to one more player, as it is now (late joiners get "all" elements by themselves).
    function el:show_to(ps) send(ps, render(nil)) end

    if target == "all" then
        state.global[id] = el
        watch_joins()
    end
    show(opts.transition and { transition = opts.transition, easing = opts.easing } or nil)
    if (opts.lifetime or 0) > 0 and target == "all" then
        BR.timer.after(opts.lifetime, function() if state.global[id] == el then state.global[id] = nil end end)
    end
    return el
end

--- Text on the screens of `target` (a PlayerState, a list of them, or "all",
--- which includes players who join later). opts:
---   text (rich text markup works: <b>, <color="ff8800">...</>), x, y (screen
---   units at 1080p from the anchor), anchor (a BR.ui.ANCHOR name or {x, y},
---   default "top_left"), pivot (default the anchor), size (font size, default
---   24), color ({r, g, b, a} or "rrggbb[aa]"), outline (size), outline_color,
---   shadow ({x, y} offset), shadow_color, scale (number or {x, y}), angle, z,
---   wrap (width), align ("left", "center", "right"), font (a BR.enums "font"
---   name), typeface ("bold", ...), spacing, skew, line_height, lifetime
---   (seconds; 0 stays until removed), transition and easing (for this first
---   send), id (a fixed PersistentId, to replace an element across reloads).
--- Returns the element: el:set(changes, { transition, easing }), el:move(x, y,
--- seconds, easing), el:remove(), el.id.
function ui.text(target, opts) return element(target, opts, false) end

--- A solid rectangle: opts.w and opts.h (screen units), color, and the
--- placement options of BR.ui.text (x, y, anchor, pivot, z, angle...).
--- Change its size with el:set({ w = ..., h = ... }, { transition = ... }).
function ui.panel(target, opts) return element(target, opts, true) end

--- Remove an element by id from a player's screen (or "all" connected players).
function ui.remove(target, id)
    for _, ps in ipairs(targets(target)) do
        if BR.player.connected(ps) then BR.player.controller(ps):ClientRemoveDisplayText(id) end
    end
    if target == "all" then state.global[id] = nil end
end


-- Dialogs. The game's Message Box gate shows one with ClientShowWireMessageBoxDialog
-- and gets the answer back in ServerWireMessageBoxAnswered (or FailedToOpen),
-- matched by a request id. BR asks with ids from a range of its own and takes
-- its answers out of that call before the game sees them, so gates' dialogs
-- are unaffected.

ui.DIALOG = { ok = 0, yes_no = 1, ok_cancel = 2, text = 3 }

_G.BR_UI_DIALOGS = _G.BR_UI_DIALOGS or { next = 0xB0000000, pending = {} }
local dialogs = _G.BR_UI_DIALOGS
local CONTROLLER = "/Script/Brickadia.BRPlayerController"

local function answer(id, accepted, text)
    local d = dialogs.pending[id]
    if not d then return false end
    dialogs.pending[id] = nil
    if d.cancel_timeout then d.cancel_timeout() end
    local ok, err = pcall(d.fn, accepted, text)
    if not ok then I.report("BR.ui.ask", err) end
    return true
end

local function watch_answers()
    if dialogs.hooked then return end
    dialogs.hooked = true
    local L = __fn_layout(CONTROLLER .. ":ServerWireMessageBoxAnswered")
    BR.event.hook(CONTROLLER .. ":ServerWireMessageBoxAnswered", function(_, p)
        local id = string.unpack("<I4", p, L.RequestID.offset + 1)
        -- answered after its timeout: the dialog was BR's, so the game doesn't see it either
        if dialogs.late and dialogs.late[id] then
            dialogs.late[id] = nil
            return false
        end
        if not dialogs.pending[id] then return nil end
        local accepted = p:byte(L.bAccepted.offset + 1) ~= 0
        local text = BR.raw.fstring(p:sub(L.Text.offset + 1, L.Text.offset + 16))
        answer(id, accepted, text)
        return false
    end)
    local F = __fn_layout(CONTROLLER .. ":ServerWireMessageBoxFailedToOpen")
    BR.event.hook(CONTROLLER .. ":ServerWireMessageBoxFailedToOpen", function(_, p)
        local id = string.unpack("<I4", p, F.RequestID.offset + 1)
        if not dialogs.pending[id] then return nil end
        answer(id, nil, "failed")
        return false
    end)
end

--- Ask a connected player something with the game's dialog box, and call
--- fn(accepted, text) with the answer: accepted is true or false (OK/Yes or
--- Cancel/No), and text what they typed for a "text" dialog. If the dialog
--- couldn't open, or opts.timeout seconds pass first, fn(nil, "failed" or
--- "timeout"). opts: title, message, kind ("ok", "yes_no", "ok_cancel",
--- "text"; default "ok"), timeout, from (the owner index the dialog names as
--- its source; default the server's). Returns the request id.
function ui.ask(ps, opts, fn)
    assert(BR.player.connected(ps), "only a connected player can be asked")
    assert(type(fn) == "function", "ui.ask needs a function for the answer")
    watch_answers()
    local id = dialogs.next
    dialogs.next = dialogs.next + 1
    local d = { fn = fn }
    dialogs.pending[id] = d
    if opts.timeout then
        -- the game has no way to close a dialog from the server, so it stays on
        -- the player's screen; their answer, when it comes, is dropped
        d.cancel_timeout = BR.timer.after(opts.timeout, function()
            if answer(id, nil, "timeout") then
                dialogs.late = dialogs.late or {}
                dialogs.late[id] = true
            end
        end)
    end
    BR.player.controller(ps):ClientShowWireMessageBoxDialog(id, opts.from or BR.player.owner_index(),
        FText(opts.title or ""), FText(opts.message or ""), lookup(ui.DIALOG, opts.kind or "ok", "dialog kind"))
    return id
end

return ui

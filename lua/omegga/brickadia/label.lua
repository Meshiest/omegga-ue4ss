-- BR.label: Text in the world: a label at a point, as the Text Display component
-- draws it, optionally always facing the viewer and shown to one player or one
-- team only. Each label is a small brick with no collision carrying the
-- component, owned by the server's stand-in. How labels look has not been seen
-- on a client yet (docs/client-checks.md).
local I = require("omegga.brickadia.internal")
local BR = I.BR
local label = {}

local TYPE = "Component_TextDisplay"
local BILLBOARD = { none = 0, full = 1, in_plane = 2 }
-- EBRTextMaterial
local MATERIAL = { unlit = 0, graffiti = 1, plastic = 2, metallic = 3, glow = 4, translucent_plastic = 5, glass = 6 }

local function fields(opts)
    local f = {}
    if opts.text ~= nil then f.Text = tostring(opts.text) end
    if opts.billboard ~= nil then f.Billboard = assert(BILLBOARD[opts.billboard], "billboard is none, full or in_plane") end
    if opts.color then
        local c = opts.color
        f.bOverrideColor = true
        f.Color = { R = c[1], G = c[2], B = c[3], A = c[4] or 255 }
    end
    if opts.outline then
        f.OutlineWidth = opts.outline
        if opts.outline_color then
            local c = opts.outline_color
            f.bOverrideOutlineColor = true
            f.OutlineColor = { R = c[1], G = c[2], B = c[3], A = c[4] or 255 }
        end
    end
    if opts.scale then f.WidthScale = opts.scale end
    if opts.offset then f.Offset = { X = opts.offset[1], Y = opts.offset[2], Z = opts.offset[3] } end
    if opts.foreground ~= nil then f.bForeground = opts.foreground end
    if opts.material ~= nil then
        f.Material = assert(MATERIAL[opts.material], "material is unlit, graffiti, plastic, metallic, glow, translucent_plastic or glass")
    end
    return f
end

--- A label at position {x, y, z} (grid units). opts: text, billboard ("full":
--- always faces the viewer; "in_plane"; default "full"), color ({r, g, b, a}),
--- outline (width) and outline_color, scale (text width scale), offset {x, y, z}
--- from the point, foreground (drawn over the world), material ("unlit": the
--- same brightness in any light; "glow", "metallic", ...). Returns the label:
--- l:set(opts) changes any of those, l:remove(), l.brick (its brick handle),
--- l.text (the text it shows).
function label.create(position, opts)
    opts = opts or {}
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.billboard = o.billboard or "full"
    local b = BR.brick.builder({ size = { 5, 5, 2 }, visible = false, collision = false })
    local h = assert(BR.brick.place(b, position[1], position[2], position[3]), "the label's brick was refused there")
    BR.brick.transaction(BR.player.server(), function(tx) tx.attach(BR.brick.id(h), BR.component.type(TYPE)) end)
    local f = fields(o)
    f.bEnabled = true
    BR.component.set(h, TYPE, f)
    local l = { brick = h, text = o.text }
    function l:set(changes)
        BR.component.set(h, TYPE, fields(changes))
        if changes.text ~= nil then l.text = tostring(changes.text) end
    end
    function l:remove()
        if BR.brick.valid(h) then BR.brick.transaction(BR.player.server(), function(tx) tx.delete(BR.brick.id(h)) end) end
    end
    return l
end

return label

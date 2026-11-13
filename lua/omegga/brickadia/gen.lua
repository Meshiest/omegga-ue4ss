-- BR.gen: Procedural generation: a seeded random number generator, noise,
-- checks for free space, and generators that build terrain and mazes in one
-- transaction. Worlds are saved whole, so generation runs when a mod decides
-- (a round start, a command), not as chunks load.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local gen = {}

-- a 64-bit FNV-1a hash, to turn a string seed into a number
local function hash(s)
    local h = -3750763034362895579 -- 0xcbf29ce484222325
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = h * 1099511628211
    end
    return h
end

local RNG = {}
RNG.__index = RNG

-- PCG32 (pcg-random.org): 64-bit state, 32-bit output. Lua 5.4 integers wrap
-- at 64 bits and `>>` is a logical shift, which is the arithmetic PCG needs.
function RNG:next()
    local old = self.state
    self.state = old * 6364136223846793005 + self.inc
    local xorshifted = (((old >> 18) ~ old) >> 27) & 0xffffffff
    local rot = old >> 59
    return ((xorshifted >> rot) | (xorshifted << ((-rot) & 31))) & 0xffffffff
end

--- A number in [0, 1).
function RNG:float() return self:next() / 4294967296 end

--- An integer from a to b, both included.
function RNG:int(a, b)
    assert(b >= a, "int(a, b) needs a <= b")
    return a + math.floor(self:float() * (b - a + 1))
end

--- True with probability p.
function RNG:chance(p) return self:float() < p end

--- A random element of a list.
function RNG:pick(list) return list[self:int(1, #list)] end

--- Shuffle a list in place (and return it).
function RNG:shuffle(list)
    for i = #list, 2, -1 do
        local j = self:int(1, i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

--- A random number generator from a seed (a number or a string): the same seed
--- gives the same sequence on every server, unlike math.random. rng:next()
--- (32-bit integer), rng:float(), rng:int(a, b), rng:chance(p), rng:pick(list),
--- rng:shuffle(list).
function gen.rng(seed)
    if seed == nil then seed = os.time() end
    local s = type(seed) == "string" and hash(seed) or math.tointeger(seed) or hash(tostring(seed))
    local r = setmetatable({ state = 0, inc = (s << 1) | 1 }, RNG)
    r:next()
    r.state = r.state + s
    r:next()
    return r
end

-- Perlin's improved noise (2002): gradients from a permutation of 0..255
local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end
local function lerp(t, a, b) return a + t * (b - a) end
local function grad(h, x, y, z)
    h = h & 15
    local u = h < 8 and x or y
    local v = h < 4 and y or ((h == 12 or h == 14) and x or z)
    return ((h & 1) == 0 and u or -u) + ((h & 2) == 0 and v or -v)
end

--- A noise function from a seed: noise(x, y, z?) returns a smooth value in
--- about [-1, 1] that changes over a distance of about 1, so scale the inputs
--- (x / 50) for features 50 units across. The same seed gives the same noise.
function gen.noise(seed)
    local r = gen.rng(seed or 0)
    local p = {}
    for i = 0, 255 do p[i] = i end
    for i = 255, 1, -1 do
        local j = r:int(0, i)
        p[i], p[j] = p[j], p[i]
    end
    for i = 0, 255 do p[256 + i] = p[i] end
    return function(x, y, z)
        z = z or 0
        local X, Y, Z = math.floor(x) & 255, math.floor(y) & 255, math.floor(z) & 255
        x, y, z = x - math.floor(x), y - math.floor(y), z - math.floor(z)
        local u, v, w = fade(x), fade(y), fade(z)
        local A, B = p[X] + Y, p[X + 1] + Y
        local AA, AB, BA, BB = p[A] + Z, p[A + 1] + Z, p[B] + Z, p[B + 1] + Z
        return lerp(w,
            lerp(v, lerp(u, grad(p[AA], x, y, z), grad(p[BA], x - 1, y, z)),
                lerp(u, grad(p[AB], x, y - 1, z), grad(p[BB], x - 1, y - 1, z))),
            lerp(v, lerp(u, grad(p[AA + 1], x, y, z - 1), grad(p[BA + 1], x - 1, y, z - 1)),
                lerp(u, grad(p[AB + 1], x, y - 1, z - 1), grad(p[BB + 1], x - 1, y - 1, z - 1))))
    end
end

--- Layered noise (fractal Brownian motion): `noise` (from gen.noise) summed over
--- opts.octaves (default 4), each at opts.lacunarity (2) times the frequency
--- and opts.gain (0.5) times the strength of the last. Returns about [-1, 1].
function gen.fbm(noise, x, y, z, opts)
    opts = opts or {}
    local octaves, lacunarity, gain = opts.octaves or 4, opts.lacunarity or 2, opts.gain or 0.5
    local sum, amp, freq, norm = 0, 1, 1, 0
    for _ = 1, octaves do
        sum = sum + amp * noise(x * freq, y * freq, (z or 0) * freq)
        norm = norm + amp
        amp, freq = amp * gain, freq * lacunarity
    end
    return sum / norm
end

--- Whether the box from `min` to `max` ({x, y, z}, whole grid units) is free of
--- bricks. opts.grid checks another grid.
function gen.fits(min, max, opts)
    return #BR.brick.in_box(min, max, { grid = opts and opts.grid, max = 1 }) == 0
end

--- Up to `count` random points ({x, y}) in the rectangle from min {x, y} to max
--- {x, y}, at least opts.spacing apart (default 0), from rng (a gen.rng). Fewer
--- come back when the area can't fit them (tries 30 times per point).
function gen.scatter(rng, min, max, count, opts)
    local spacing = (opts and opts.spacing) or 0
    local out, tries = {}, 0
    while #out < count and tries < count * 30 do
        tries = tries + 1
        local x = min[1] + rng:float() * (max[1] - min[1])
        local y = min[2] + rng:float() * (max[2] - min[2])
        local ok = true
        for _, q in ipairs(out) do
            local dx, dy = q[1] - x, q[2] - y
            if dx * dx + dy * dy < spacing * spacing then
                ok = false
                break
            end
        end
        if ok then out[#out + 1] = { math.floor(x), math.floor(y) } end
    end
    return out
end

-- builders by size and colour: building one takes several calls, and generated
-- worlds reuse a handful of shapes
local function builders(opts)
    local cache = {}
    return function(size, color)
        local key = table.concat(size, ",") .. "|" .. table.concat(color, ",")
        local b = cache[key]
        if not b then
            b = BR.brick.builder({ size = size, color = color, material = opts.material, owner = opts.owner })
            cache[key] = b
        end
        return b
    end
end

local function blend(a, b, t)
    return { math.floor(a[1] + (b[1] - a[1]) * t + 0.5), math.floor(a[2] + (b[2] - a[2]) * t + 0.5),
        math.floor(a[3] + (b[3] - a[3]) * t + 0.5), 255 }
end

--- Build noise terrain: a grid of `cells` {w, h} columns from `origin` {x, y, z}
--- (the corner, at the ground). opts: cell (a column's half width, default 10),
--- layers (the tallest column, in layers, default 8), layer (a layer's half
--- height, default 2, a plate), scale (cells per noise feature, default 12),
--- seed, octaves, colors ({ low, high }, blended by height), material, owner
--- (brick owner index), player (whose transaction; default the server
--- stand-in). Returns the transaction's report.
function gen.terrain(origin, cells, opts)
    opts = opts or {}
    local cell, layers, layer = opts.cell or 10, opts.layers or 8, opts.layer or 2
    local scale = opts.scale or 12
    local low, high = (opts.colors or {})[1] or { 60, 110, 50 }, (opts.colors or {})[2] or { 150, 140, 120 }
    local noise = gen.noise(opts.seed)
    local get = builders(opts)
    return BR.brick.transaction(opts.player or BR.player.server(), function(tx)
        for i = 0, cells[1] - 1 do
            for j = 0, cells[2] - 1 do
                local n = (gen.fbm(noise, i / scale, j / scale, 0, { octaves = opts.octaves }) + 1) / 2
                local h = math.max(1, math.min(layers, math.floor(n * layers + 0.5)))
                local half = h * layer
                local t = (h - 1) / math.max(1, layers - 1)
                tx.place(get({ cell, cell, half }, blend(low, high, t)),
                    { origin[1] + (2 * i + 1) * cell, origin[2] + (2 * j + 1) * cell, origin[3] + half })
            end
        end
    end)
end

--- A maze of `cells` {w, h} as a grid of booleans (true is a wall), by a
--- randomized depth-first search: every cell reachable, exactly one path
--- between any two. The grid is (2w+1) by (2h+1); grid[x][y], 1-based.
function gen.maze_grid(cells, rng)
    local W, H = cells[1] * 2 + 1, cells[2] * 2 + 1
    local grid = {}
    for x = 1, W do
        grid[x] = {}
        for y = 1, H do grid[x][y] = true end
    end
    local stack = { { 2, 2 } }
    grid[2][2] = false
    while #stack > 0 do
        local c = stack[#stack]
        local options = {}
        for _, d in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }) do
            local nx, ny = c[1] + d[1], c[2] + d[2]
            if nx > 1 and nx < W and ny > 1 and ny < H and grid[nx][ny] then options[#options + 1] = d end
        end
        if #options == 0 then
            stack[#stack] = nil
        else
            local d = rng:pick(options)
            grid[c[1] + d[1] // 2][c[2] + d[2] // 2] = false
            grid[c[1] + d[1]][c[2] + d[2]] = false
            stack[#stack + 1] = { c[1] + d[1], c[2] + d[2] }
        end
    end
    return grid
end

--- Build a maze of `cells` {w, h} from `origin` {x, y, z} (the corner, at the
--- ground). opts: block (a wall block's half width, default 10), height (the
--- walls' half height, default 30), color, material, owner, seed, player (as
--- gen.terrain). Each row's wall runs are merged into single bricks. Returns
--- the transaction's report and the grid (gen.maze_grid).
function gen.maze(origin, cells, opts)
    opts = opts or {}
    local block, height = opts.block or 10, opts.height or 30
    local color = opts.color or { 90, 90, 100, 255 }
    local grid = gen.maze_grid(cells, gen.rng(opts.seed))
    local get = builders(opts)
    local W, H = #grid, #grid[1]
    local report = BR.brick.transaction(opts.player or BR.player.server(), function(tx)
        for y = 1, H do
            local x = 1
            while x <= W do
                if grid[x][y] then
                    local run = 1
                    while x + run <= W and grid[x + run][y] do run = run + 1 end
                    tx.place(get({ block * run, block, height }, color),
                        { origin[1] + (2 * (x - 1) + run) * block, origin[2] + (2 * y - 1) * block, origin[3] + height })
                    x = x + run
                else
                    x = x + 1
                end
            end
        end
    end)
    return report, grid
end

return gen

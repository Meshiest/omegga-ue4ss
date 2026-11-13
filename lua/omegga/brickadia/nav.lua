-- BR.nav: Paths for characters over a brick world. There is no navmesh, so the
-- ground is sampled with traces as the search reaches it: a grid of cells, each
-- cell's floor found by a ray cast down, a capsule-sized sweep for headroom, and
-- a sweep between neighbouring cells for walls. Steps up to the character's step
-- height are walked, higher ledges up to a jump's reach are jumped, drops are
-- fallen down. The search runs a little each tick, so it never holds a tick up.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local nav = {}

-- a Brickadia figure: capsule radius 12 and half height 23 (it stands 25 above the
-- floor), MaxStepHeight 16, a jump rises about 58
nav.CHARACTER = { radius = 12, height = 50, step = 16, jump = 50, drop = 200 }

local CELL = 20
-- traces a search may make per tick; each costs about 50 microseconds
local BUDGET = 200
-- WalkableFloorZ: floors steeper than 51 degrees are not walkable
local WALKABLE_Z = 0.63

local C = nav.CHARACTER

-- what the ground and walls are made of: bricks, physics bodies and the map;
-- not characters (they move), pickups, projectiles or water
local SOLID = 1 | 2 | 512 | 1024

local function ray(x, y, z, dz, len)
    return BR.world.raycast({ x, y, z }, { 0, 0, dz }, { distance = len, targets = SOLID })
end

local function sweep(from, to, radius)
    local dx, dy, dz = to[1] - from[1], to[2] - from[2], to[3] - from[3]
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len == 0 then return nil end
    return BR.world.sweep(from, { dx, dy, dz }, radius, { distance = len, targets = SOLID })
end

-- The floor a character standing near height `z` would find at (x, y): the first
-- walkable surface below z + a jump. Returns its height, or nil.
local function floor_at(x, y, z)
    local top = z + C.jump + 2
    local hit = ray(x, y, top, -1, C.jump + 2 + C.drop)
    if not hit or hit.normal[3] < WALKABLE_Z then return nil end
    return hit.position[3]
end

-- whether a standing capsule fits on the floor at (x, y, fz)
local function fits(x, y, fz)
    local r = C.radius - 1
    return sweep({ x, y, fz + r + 2 }, { x, y, fz + C.height - r }, r) == nil
end

-- whether a character can get from floor point a to floor point b: a sphere the
-- character's width, swept at the height it would be at over the higher floor
local function crossable(a, b)
    local r = C.radius - 1
    local z = math.max(a[3], b[3]) + r + 2
    return sweep({ a[1], a[2], z }, { b[1], b[2], z }, r) == nil
end

local function key(ix, iy, z) return ix .. "," .. iy .. "," .. math.floor(z / 4 + 0.5) end

-- a binary heap of nodes by f
local function heap_push(h, n)
    h[#h + 1] = n
    local i = #h
    while i > 1 do
        local p = i // 2
        if h[p].f <= h[i].f then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end

local function heap_pop(h)
    local top = h[1]
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local i = 1
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            if l <= #h and h[l].f < h[m].f then m = l end
            if r <= #h and h[r].f < h[m].f then m = r end
            if m == i then break end
            h[m], h[i] = h[i], h[m]
            i = m
        end
    end
    return top
end

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local function dist(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- A search in progress, between `from` and `to` (floor points). It can't run as
-- a coroutine that yields between batches: UE4SS calls fail on a coroutine's own
-- Lua thread. So its state lives here, and expand() takes it a node at a time.
local function new_search(from, to, max_nodes)
    local start = { ix = math.floor(from[1] / CELL + 0.5), iy = math.floor(from[2] / CELL + 0.5),
        x = from[1], y = from[2], z = from[3], g = 0 }
    start.f = dist(start.x, start.y, start.z, to[1], to[2], to[3])
    return {
        to = to, max_nodes = max_nodes, expanded = 0,
        goal_ix = math.floor(to[1] / CELL + 0.5), goal_iy = math.floor(to[2] / CELL + 0.5),
        open = { start }, seen = { [key(start.ix, start.iy, start.z)] = start },
    }
end

-- Expand the best open node. Returns the number of traces it cost, and, once the
-- search is over, "found" with the path or "none".
local function expand(st)
    local n = heap_pop(st.open)
    if not n then return 0, "none" end
    if n.closed then return 0 end
    n.closed = true
    local to = st.to
    if n.ix == st.goal_ix and n.iy == st.goal_iy and math.abs(n.z - to[3]) <= C.jump then
        local path = {}
        while n do
            table.insert(path, 1, { n.x, n.y, n.z, jump = n.jump })
            n = n.parent
        end
        path[#path] = { to[1], to[2], to[3], jump = path[#path].jump }
        return 0, "found", path
    end
    st.expanded = st.expanded + 1
    if st.expanded > st.max_nodes then return 0, "none" end
    local traces = 0
    local open_dirs = {}
    for _, off in ipairs(NEIGHBOURS) do
        local diagonal = off[1] ~= 0 and off[2] ~= 0
        -- no corner cutting: a diagonal needs both of its sides open
        if not diagonal or (open_dirs[off[1] .. ",0"] and open_dirs["0," .. off[2]]) then
            local ix, iy = n.ix + off[1], n.iy + off[2]
            local x, y = ix * CELL, iy * CELL
            traces = traces + 3
            local fz = floor_at(x, y, n.z)
            if fz then
                local rise = fz - n.z
                if rise <= C.jump and fits(x, y, fz) and crossable({ n.x, n.y, n.z }, { x, y, fz }) then
                    if not diagonal then open_dirs[off[1] .. "," .. off[2]] = true end
                    local k = key(ix, iy, fz)
                    local jump = rise > C.step
                    local g = n.g + dist(n.x, n.y, n.z, x, y, fz) + (jump and CELL * 2 or 0)
                    local m = st.seen[k]
                    if not m then
                        m = { ix = ix, iy = iy, x = x, y = y, z = fz }
                        st.seen[k] = m
                    end
                    if not m.closed and (m.g == nil or g < m.g) then
                        m.g, m.parent, m.jump = g, n, jump
                        m.f = g + dist(x, y, fz, to[1], to[2], to[3])
                        heap_push(st.open, m)
                    end
                end
            end
        end
    end
    return traces
end

-- Drop waypoints a straight walk can skip: from each kept point, the farthest
-- later point (no jump or step in between) with a clear straight line to it.
local function smooth(path)
    local out = { path[1] }
    local i = 1
    while i < #path do
        local j = i + 1
        for k = #path, i + 2, -1 do
            local level = true
            for m = i + 1, k do
                if path[m].jump or math.abs(path[m][3] - path[i][3]) > C.step then level = false break end
            end
            if level and crossable(path[i], path[k]) then j = k break end
        end
        out[#out + 1] = path[j]
        i = j
    end
    return out
end

local function floor_point(p)
    local fz = floor_at(p[1], p[2], p[3])
    if not fz then return nil end
    return { p[1], p[2], fz }
end

--- Find a walking path from world point `from` to `to` ({x, y, z}; a
--- character's location works, its feet are found from there), a few hundred
--- traces per tick. Calls `done(path)` with a list of floor points
--- { x, y, z, jump = true where it has to jump up to reach it }, or `done(nil)`
--- when there is none within opts.max_nodes cells searched (default 3000).
--- Returns a function that cancels the search.
function nav.find(from, to, done, opts)
    opts = opts or {}
    local budget = opts.budget or BUDGET
    local a, b = floor_point(from), floor_point(to)
    local st = a and b and new_search(a, b, opts.max_nodes or 3000)
    local cancelled = false
    local stop
    local function finish(path)
        stop()
        local ok, err = pcall(done, path)
        if not ok then I.report("BR.nav.find", err) end
    end
    stop = BR.event.tick(function()
        if cancelled then stop() return end
        if not st then return finish(nil) end
        local used = 0
        while used < budget do
            local traces, result, path = expand(st)
            used = used + traces
            if result == "found" then return finish(smooth(path)) end
            if result == "none" then return finish(nil) end
        end
    end)
    return function() cancelled = true end
end

--- Whether a character could walk straight from `from` to `to` (both floor
--- points or character locations) with nothing in the way at its height.
function nav.clear(from, to)
    local a, b = floor_point(from), floor_point(to)
    return a ~= nil and b ~= nil and math.abs(a[3] - b[3]) <= C.step and crossable(a, b)
end

-- A baked graph. Searching by traces costs a few ticks and knows nothing of what
-- a builder means by a route; a baked graph is saved with the build, and a
-- circuit can change it. Each node is a hidden, non-colliding Array Variable gate
-- standing on the floor, holding GRAPH_SLOTS numbers: the cost of the edge to the
-- neighbouring node in each of the eight directions below (0: no edge), then
-- GRAPH_MARK, which tells a node from any other array gate. A circuit setting an
-- element (Set Array Element on the node's variable) changes that edge at once:
-- 0 closes it, a larger cost makes routes avoid it.

local GRAPH_CELL = 40
local GRAPH_MARK = 20261111
local GRAPH_DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local GRAPH_SLOTS = #GRAPH_DIRS + 1
local NODE_ASSET = "B_1x1_Gate_Variable_Array"
-- a 1x1F gate's center sits 2 above the floor it stands on
local NODE_LIFT = 2
nav.GRAPH_DIRECTIONS = GRAPH_DIRS

local function cell_key(ix, iy) return ix .. "," .. iy end

--- Bake a graph into the world: flood out from world point `seed` over every cell
--- a character can reach, opts.radius (default 1000) units around it at most,
--- and place a node gate on each, a few hundred traces a tick. opts.cell: node
--- spacing (default 40). Calls opts.done(count) when finished. Returns a
--- function that cancels it. Nodes from an earlier bake are left alone.
function nav.bake(seed, opts)
    opts = opts or {}
    local cell = opts.cell or GRAPH_CELL
    local radius = opts.radius or 1000
    -- nodes sit on world multiples of the cell size, so separate bakes line up
    local sx, sy = math.floor(seed[1] / cell + 0.5), math.floor(seed[2] / cell + 0.5)
    local start = floor_point({ sx * cell, sy * cell, seed[3] })
    if not start then error("no floor under the seed point", 2) end
    local ox, oy = seed[1], seed[2]
    local function pos(ix, iy) return ix * cell, iy * cell end
    local nodes, queue, head = { [cell_key(sx, sy)] = { ix = sx, iy = sy, z = start[3] } }, { { sx, sy } }, 1
    local placing, placed, writes = nil, 0, {}
    local stop
    local cancelled = false
    stop = BR.event.tick(function()
        if cancelled then return stop() end
        local used = 0
        while used < BUDGET and head <= #queue do
            local ix, iy = table.unpack(queue[head])
            head = head + 1
            local n = nodes[cell_key(ix, iy)]
            local x, y = pos(ix, iy)
            n.costs = {}
            for d, off in ipairs(GRAPH_DIRS) do
                local jx, jy = ix + off[1], iy + off[2]
                local nx, ny = pos(jx, jy)
                local cost = 0
                local diagonal = off[1] ~= 0 and off[2] ~= 0
                if (nx - ox) ^ 2 + (ny - oy) ^ 2 <= radius * radius
                    and (not diagonal or (n.costs[off[1] == 1 and 1 or 2] > 0 and n.costs[off[2] == 1 and 3 or 4] > 0)) then
                    used = used + 3
                    local fz = floor_at(nx, ny, n.z)
                    if fz and fz - n.z <= C.jump and fits(nx, ny, fz) and crossable({ x, y, n.z }, { nx, ny, fz }) then
                        local dz = fz - n.z
                        cost = math.sqrt((nx - x) ^ 2 + (ny - y) ^ 2 + dz * dz) + (dz > C.step and cell * 2 or 0)
                        local k = cell_key(jx, jy)
                        if not nodes[k] then
                            nodes[k] = { ix = jx, iy = jy, z = fz }
                            queue[#queue + 1] = { jx, jy }
                        end
                    end
                end
                n.costs[d] = cost
            end
        end
        if head <= #queue then return end
        -- searched; place the gates, a batch a tick, and fill each in on the tick
        -- after (a brick placed this tick has no component data yet)
        for _, w in ipairs(writes) do BR.var.write_array(w.handle, w.costs) end
        writes = {}
        if not placing then
            placing = {}
            for _, n in pairs(nodes) do placing[#placing + 1] = n end
        end
        for _ = 1, 50 do
            local n = table.remove(placing)
            if not n then
                if #writes > 0 then return end
                stop()
                if opts.done then opts.done(placed) end
                return
            end
            local x, y = pos(n.ix, n.iy)
            local h = BR.brick.place(BR.brick.builder({
                asset = NODE_ASSET, visible = false, collision = false,
            }), math.floor(x + 0.5), math.floor(y + 0.5), math.floor(n.z + 0.5) + NODE_LIFT)
            if h then
                n.costs[GRAPH_SLOTS] = GRAPH_MARK
                writes[#writes + 1] = { handle = h, costs = n.costs }
                placed = placed + 1
            end
        end
    end)
    return function() cancelled = true end
end

local graph_cache
--- Every baked node in the world: { handle, x, y, z (the floor), costs } by
--- cell, read from the node gates. Cached; pass true to read the world again
--- (after a bake). Costs are read fresh by BR.nav.route either way.
function nav.graph(reload)
    if graph_cache and not reload then return graph_cache end
    local g = { nodes = {}, by_cell = {}, cell = GRAPH_CELL }
    local asset = BR.brick.asset(NODE_ASSET)
    for _, h in ipairs(BR.brick.in_grid()) do
        local info = BR.brick.info(h)
        if info.asset and info.asset:IsValid() and __addr(info.asset) == __addr(asset) then
            local ok, values = pcall(BR.var.read_array, h)
            if ok and #values == GRAPH_SLOTS and values[GRAPH_SLOTS] == GRAPH_MARK then
                local p = info.position
                local n = { handle = h, x = p[1], y = p[2], z = p[3] - NODE_LIFT }
                g.nodes[#g.nodes + 1] = n
            end
        end
    end
    for _, n in ipairs(g.nodes) do
        n.ix = math.floor(n.x / g.cell + 0.5)
        n.iy = math.floor(n.y / g.cell + 0.5)
        local k = cell_key(n.ix, n.iy)
        g.by_cell[k] = g.by_cell[k] or {}
        table.insert(g.by_cell[k], n)
    end
    graph_cache = g
    return g
end

--- Remove the baked nodes within `radius` units of world point `center` (all of
--- them when no center is given). Returns how many went.
function nav.unbake(center, radius)
    local lib = StaticFindObject("/Script/Brickadia.Default__BRLuauBrickLibrary")
    local removed = 0
    for _, n in ipairs(nav.graph(true).nodes) do
        if not center or (n.x - center[1]) ^ 2 + (n.y - center[2]) ^ 2 <= radius * radius then
            BR.raw.call(lib, "BRLuauBrickLibrary", "DeleteBrick", { Self = n.handle, WorldContextObject = BR.raw.ptr(BR.world.context()) })
            removed = removed + 1
        end
    end
    graph_cache = nil
    return removed
end

-- the node in cell (ix, iy) nearest height z, within a jump of it
local function node_at(g, ix, iy, z)
    local best, bd
    for _, n in ipairs(g.by_cell[cell_key(ix, iy)] or {}) do
        local d = math.abs(n.z - z)
        if d <= C.jump + C.step and (not bd or d < bd) then best, bd = n, d end
    end
    return best
end

local function nearest_node(g, p)
    local ix = math.floor(p[1] / g.cell + 0.5)
    local iy = math.floor(p[2] / g.cell + 0.5)
    for ring = 0, 3 do
        local best, bd
        for dx = -ring, ring do
            for dy = -ring, ring do
                if math.max(math.abs(dx), math.abs(dy)) == ring then
                    for _, n in ipairs(g.by_cell[cell_key(ix + dx, iy + dy)] or {}) do
                        local d = (n.x - p[1]) ^ 2 + (n.y - p[2]) ^ 2 + (n.z - p[3]) ^ 2
                        if not bd or d < bd then best, bd = n, d end
                    end
                end
            end
        end
        if best then return best end
    end
end

--- A path over the baked graph from world point `from` to `to` (character
--- locations work), by Dijkstra on the edge costs the node gates hold now:
--- { x, y, z, jump = true where it climbs } floor points, or nil when the nodes
--- near them are not connected. Synchronous: no traces, only the graph.
function nav.route(from, to)
    local g = nav.graph()
    if #g.nodes == 0 then return nil end
    local a, b = nearest_node(g, from), nearest_node(g, to)
    if not a or not b then return nil end
    local dist, prev, done = { [a] = 0 }, {}, {}
    local open = { { n = a, f = 0 } }
    while #open > 0 do
        local top = heap_pop(open)
        local n = top.n
        if not done[n] then
            done[n] = true
            if n == b then break end
            local ok, costs = pcall(BR.var.read_array, n.handle)
            if ok then
                for d, off in ipairs(GRAPH_DIRS) do
                    local cost = costs[d]
                    if cost and cost > 0 then
                        -- the neighbour is the node in that cell at about this height
                        local m = node_at(g, n.ix + off[1], n.iy + off[2], n.z)
                        if m and not done[m] then
                            local nd = dist[n] + cost
                            if not dist[m] or nd < dist[m] then
                                dist[m], prev[m] = nd, n
                                heap_push(open, { n = m, f = nd })
                            end
                        end
                    end
                end
            end
        end
    end
    if not dist[b] then return nil end
    local path = {}
    local n = b
    while n do
        local p = prev[n]
        table.insert(path, 1, { n.x, n.y, n.z, jump = p ~= nil and n.z - p.z > C.step })
        n = p
    end
    path[#path + 1] = { to[1], to[2], to[3] }
    return path
end

return nav

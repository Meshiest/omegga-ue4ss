-- BR.metrics: Prometheus metrics from Lua mods. Each update goes to the omegga
-- plugin, which keeps them in its own registry, so they are scraped from
-- omegga's metrics endpoint as omegga_plugin_ue4ss_<name>. Names are lowercase
-- letters, digits and underscores; a name keeps the kind it was first used as.
-- Every update is one message to omegga, so count in Lua and send now and then
-- for something that changes every tick.
local metrics = {}

local function send(update)
    local ok, omegga = pcall(require, "omegga")
    if ok and omegga and omegga.emit then omegga.emit("metric", update) end
end

-- opts: help, labels (the label names its updates may use; omegga needs them
-- up front), buckets (histograms)
local function check(name, opts)
    assert(type(name) == "string" and name:match("^[a-z][a-z0-9_]*$"), "a metric name is lowercase letters, digits and _")
    opts = opts or {}
    return { help = opts.help, label_names = opts.labels, buckets = opts.buckets }
end

local function update(base, fields)
    for k, v in pairs(base) do fields[k] = v end
    return fields
end

--- A counter: c.inc(n?, labels?) adds n (default 1); c.reset(). opts: help,
--- labels (the label names updates may use, e.g. { "team" }).
function metrics.counter(name, opts)
    local base = check(name, opts)
    local c = {}
    function c.inc(n, labels) send(update(base, { kind = "counter", op = "inc", name = name, value = n or 1, labels = labels })) end
    function c.reset() send(update(base, { kind = "counter", op = "reset", name = name })) end
    return c
end

--- A gauge: g.set(v, labels?), g.inc(n?, labels?), g.dec(n?, labels?), g.reset().
--- opts as for counter.
function metrics.gauge(name, opts)
    local base = check(name, opts)
    local g = {}
    function g.set(v, labels) send(update(base, { kind = "gauge", op = "set", name = name, value = v, labels = labels })) end
    function g.inc(n, labels) send(update(base, { kind = "gauge", op = "inc", name = name, value = n or 1, labels = labels })) end
    function g.dec(n, labels) send(update(base, { kind = "gauge", op = "dec", name = name, value = n or 1, labels = labels })) end
    function g.reset() send(update(base, { kind = "gauge", op = "reset", name = name })) end
    return g
end

--- A histogram: h.observe(v, labels?), h.reset(). opts as for counter, plus
--- buckets: upper bounds in ascending order (omegga adds +Inf).
function metrics.histogram(name, opts)
    local base = check(name, opts)
    local h = {}
    function h.observe(v, labels) send(update(base, { kind = "histogram", op = "observe", name = name, value = v, labels = labels })) end
    function h.reset() send(update(base, { kind = "histogram", op = "reset", name = name })) end
    return h
end

return metrics

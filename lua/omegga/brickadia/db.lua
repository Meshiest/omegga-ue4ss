-- BR.db: SQLite databases for what outgrows a JSON store: logs, history,
-- leaderboards over time. Each name is a file, Saved/LuaDatabases/<name>.sqlite.
--
-- Queries run in the ue4ss omegga plugin; the game thread can't wait for the
-- answer, so each call takes a callback, which runs on the game thread once
-- the answer is back (a tick or two later). Calls on one database run in the
-- order they were made.
local I = require("omegga.brickadia.internal")
local db = {}

local function call(name, op, sql, params, fn)
    local Omegga = require("omegga")
    Omegga.call("ue4ss", "sql", { name, op, sql, params or {} }, function(ok, result)
        if not fn then
            if not ok then I.report("BR.db " .. name, result) end
            return
        end
        local called, err = pcall(fn, ok, result)
        if not called then I.report("BR.db " .. name .. " callback", err) end
    end)
end

--- The database `name` (letters, digits, '_', '-', '.'), created on first use:
---   d.exec(sql, fn?)              a script of statements (a schema); fn(ok, err)
---   d.run(sql, params?, fn?)      one statement; fn(ok, { changes, last_id } or err)
---   d.query(sql, params?, fn)     fn(ok, rows or err); rows are { column = value } tables
--- params is a list for the statement's `?`s: numbers, strings, booleans (1/0).
--- Without fn, a failed exec or run is reported in omegga's console.
---
---   local h = BR.db.open("history")
---   h.exec("create table if not exists kills (killer text, victim text, at integer)")
---   h.run("insert into kills values (?, ?, ?)", { a, b, os.time() })
---   h.query("select killer, count(*) as n from kills group by killer order by n desc limit 5", {},
---       function(ok, rows) for _, r in ipairs(rows) do print(r.killer, r.n) end end)
function db.open(name)
    assert(type(name) == "string" and name:match("^[%w_%-%.]+$") and not name:match("^%."),
        "a database name is letters, digits, '_', '-' and '.'")
    return {
        name = name,
        exec = function(sql, fn) call(name, "exec", sql, nil, fn) end,
        run = function(sql, params, fn) call(name, "run", sql, params, fn) end,
        query = function(sql, params, fn)
            assert(type(fn) == "function", "query needs a callback for its rows")
            call(name, "query", sql, params, fn)
        end,
    }
end

return db

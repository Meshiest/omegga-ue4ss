# Interop: Lua mods and omegga plugins

UE4SS Lua mods and omegga plugins can call each other and exchange events. A full working
example, an omegga plugin with its own UE4SS mod, is in
[`examples/interop-demo`](../examples/interop-demo); copy it into `plugins/` and watch the
`[demo]` lines.

## From an omegga plugin

Get the plugin once (`ue4ss` is this plugin's doc.json name). `emitPlugin` spreads its
arguments: `emitPlugin(event, a, b)`, not `emitPlugin(event, [a, b])`.

```js
const ue4ss = await omegga.getPlugin('ue4ss');

// run Lua in the bridge mod; `BR` and `Omegga` are globals there
await ue4ss.emitPlugin('exec', 'return BR.brick.count()');   // { ok: true, result: 12 }

// the same inside one mod's own Lua state (its globals; each mod is a separate state)
await ue4ss.emitPlugin('mods');                                // ['BrickadiaBridge', 'Zombies', ...]
await ue4ss.emitPlugin('exec', 'return wave', 'Zombies');      // { ok: true, result: 3 }

// call a Lua handler registered with Omegga.handle, in whichever mod registered it
await ue4ss.emitPlugin('call', 'greet', 'world');            // { ok: true, result: 'hello world' }

// receive Lua events as pluginEvent('ue4ss:<event>', from, data); '*' for all
await ue4ss.emitPlugin('subscribe', 'my-plugin', 'watch');
await ue4ss.emitPlugin('unsubscribe', 'my-plugin', 'watch');

// every Lua event is also an omegga event (unsafe plugins)
omegga.on('ue4ss:watch', data => { /* ... */ });
```

Replies are `{ ok: true, result }` or `{ ok: false, error }`; a Lua error becomes `error`.
Values cross as JSON: UObjects arrive as their full name, functions as strings, and Lua tables
with keys `1..n` become arrays.

A mod can take code only if it requires the `omegga` module (which registers an
`exec@<ModName>` handler), and only its globals are in reach: a `local` in the mod's main script
is not, as with any Lua chunk. `mods` lists the mods that can.

Subscribers pass their own plugin name: omegga reports every unsafe plugin's `emitPlugin`
caller as `'unsafe'`, so the plugin can't tell who is asking.

## From Lua

Any mod, in any mods folder, can use the module:

```lua
local Omegga = require("omegga")

-- fire-and-forget to omegga
Omegga.emit("door", { open = true, by = "lever 3" })

-- call an omegga plugin's pluginEvent(event, from, ...args); the callback runs on the game thread
Omegga.call("my-plugin", "lookup_player", { "cake" }, function(ok, result)
    if ok then print(result.displayName) else print("failed: " .. tostring(result)) end
end)

-- make a Lua function callable from plugins (runs on the game thread)
Omegga.handle("greet", function(who) return "hello " .. who end)

-- poll a value and emit `watch` { name, value, previous } when it changes
Omegga.watch("lamp", 50, function() return BR.brick.visible(lamp_brick) end)
Omegga.unwatch("lamp")
```

`Omegga.id` is this mod's interop id (each mod is its own Lua state). `Omegga.plain(v)` is the
JSON-safe copy used for everything sent.

### HTTP routes

`Omegga.route(method, path, fn, opts)` answers HTTP requests to `/api/v1/plugin/ue4ss<path>` on
omegga's web server (omegga's [plugin HTTP routes](https://github.com/brickadia-community/omegga/blob/master/docs/plugins/README.md#plugin-http-routes)).
`fn(request)` runs on the game thread:

```lua
-- GET /api/v1/plugin/ue4ss/players: a web UI login is needed
Omegga.route("GET", "/players", function(req)
    local names = {}
    for _, ps in ipairs(BR.player.list()) do names[#names + 1] = BR.player.info(ps).display_name end
    return names
end)

-- POST /api/v1/plugin/ue4ss/hook/...: no login, so the route checks a secret itself
Omegga.route("POST", "/hook/*", function(req)
    if req.headers["x-secret"] ~= SECRET then return { status = 403, body = "no" } end
    BR.server.chat(tostring(req.body.text))
end, { public = true })
```

- `request` has `method`, `path` (below `/api/v1/plugin/ue4ss`), `query`, `headers` (lowercase
  names), `body` (parsed JSON, the text of a text or form body, or nil), `user` (the web UI
  user, `{ id, username }`, or nil) and `ip`.
- A route needs a web UI login unless `opts.public`. For logged-in requests, a POST, PUT, PATCH
  or DELETE from another site's page is refused.
- `method` is a word like `GET`, or `*` for any. A path ending in `/*` also takes everything
  below it; of several matches the longest path wins.
- `fn` returns a string (a text body), a table with `status`, `headers` and `body`, any other
  table (a JSON body) or nothing (204). An error answers 500 and is logged in omegga's console.
  omegga waits 10 seconds for an answer.
- Routes are handlers (`Omegga.handle`) under the names `http:<METHOD> <path>` and
  `http-public:<METHOD> <path>`, so a later route with the same method and path wins.

### Chat commands

A mod takes chat commands the same way: `commands` in its `doc.json` (shaped like an omegga
plugin's), and `Omegga.on("cmd:<name>", fn)` in Lua, which gets the player's name and the words
omegga split from the line. The ue4ss plugin registers the declared names with omegga, so the
player isn't told the command doesn't exist. `BR.command.register` wraps this with the player's
PlayerState, permissions and replies (docs/lua-api.md, Chat commands).

```json
{ "commands": [{ "name": "heal", "description": "heal yourself", "args": [] }] }
```

### Console commands

A mod adds commands to omegga's console (listed in its `/help`) the way an omegga plugin
does: a `doc.json` next to its `Scripts/` folder with `consoleCommands`, and a handler in Lua.

```json
{ "consoleCommands": [
  { "name": "arena", "description": "start or stop a round", "args": [
    { "name": "action", "description": "start or stop", "required": true } ] } ] }
```

```lua
Omegga.on("consolecmd:arena", function(action)
    if action == "start" then start_round() return "round started" end
    return { "usage: /arena start|stop", "rounds so far: " .. rounds }
end)
```

The handler gets the typed words and runs on the game thread; what it returns (text, a list of
lines, or a table as JSON) is printed in the console. The ue4ss plugin reads the `doc.json`
files when it loads, so a new or changed one shows up after `/plugins reload ue4ss`. A name a
built-in omegga command, another plugin or an earlier mod already has is skipped with a warning.

The plugin's own `/lua` command lists the mods (`/lua mods`) and runs Lua in the bridge
(`/lua exec <code>`) or in one mod's state (`/lua exec <Mod> <code>`). There is no reload: UE4SS's
`RestartMod` hung the game thread on the first call into the restarted mod.

## Reacting to component changes

Brickadia's component logic is native code that doesn't go through UFunctions, so UE4SS has
nothing to hook when a gate's output changes. What works is a **signal brick**: wire the
output into a `Component_BrickPropertyChanger` on a brick, then watch that brick's property,
which a native getter can read.

```lua
local AND, CHANGER = "BrickComponentType_Expr_LogicalAND", "Component_BrickPropertyChanger"
local ps, owner = BR.player.server(), BR.player.owner_index()
local gate   = BR.brick.place(BR.brick.builder({ asset = "B_1x1_Gate_Expr_LogicalAND", owner = owner }), 0, 0, 6)
local signal = BR.brick.place(BR.brick.builder({ asset = "PB_DefaultBrick", size = { 5, 5, 6 }, owner = owner }), 40, 0, 6)
BR.brick.transaction(ps, function(tx)
    tx.attach(BR.brick.id(signal), BR.component.type(CHANGER))
    tx.connect(BR.brick.id(gate), BR.component.output_port(AND, "bOutput"), BR.brick.id(signal), BR.component.input_port(CHANGER, "bVisibility"))
end)
Omegga.watch("gate", 50, function() return BR.brick.visible(signal) end)
-- plugins now get ue4ss:watch { name = "gate", value = true/false, previous = ... }
```

- The property updates one engine tick after the gate changes; a 50 ms poll sees it promptly.
  (`Omegga.watch` is the one part of the interop that polls, since it samples a getter.)
- The changer also takes `Color`, `Color.R`/`G`/`B`/`A`, `MaterialAlpha`, `Material` and the
  collision flags, so numeric values (0-255) can travel too: setting `Color.R` to 200 (double)
  and `Color.G` to 150 (integer) reads back through `BRLuauBrickLibrary:GetColor` as R 200,
  G 150 (FColor bytes are B, G, R, A).
- The changer only acts when its input changes; before the first change the brick shows its
  placed state.
- Event components (`Event_ChatCommand`, `Event_Gamemode_ControllerJoined`, `CharacterDied`,
  zone enter/leave, ...) have exec outputs, not bools. Untested idea: drive a toggle or latch gate
  from the exec and wire its bool into the signal brick. `BR.component.ports(type)` lists their outputs.

Other things a watch can poll cheaply: `BR.brick.count()`, a brick's position or color, entity
transforms (`BRLuauEntityLibrary:GetTransform`), `#BR.npc.list()`.

## UE4SS hooks

`RegisterHook("/Script/Brickadia.BRGameModeBase:PushChatMessage", function(self, msg) ... end)`
works for calls that go through ProcessEvent (tested: a call from Lua fires it). Native C++
calling the same function directly bypasses it, and Brickadia's component logic is native. Combine a hook with
`Omegga.emit` to forward such calls:

```lua
RegisterHook("/Script/Brickadia.BRGameModeBase:PushChatMessage", function(self, msg)
    Omegga.emit("chat_pushed", { message = msg:get():ToString() })
end)
```

UE4SS console commands (`RegisterConsoleCommandGlobalHandler`) register fine, but the
dedicated server's stdin console doesn't route through the hook UE4SS uses, so omegga's
`writeln`/`/cmd` gets "Command not recognized". Use `emitPlugin('call', ...)` instead.

## Transport

The BrickadiaBridge C++ mod listens on a Unix socket, `data/UE4SS/bridge.sock`
(`$OMEGGA_UE4SS_SOCKET` in the game). It is created owner-only and only accepts clients
running as the server's user, since a client can run code in the server. Each message is one
line:

| Direction | Line |
|-----------|------|
| client → game | `<target>\t<json>`; the target is `BrickadiaBridge` (exec) or a mod's `Omegga.id` |
| game → client | `<json>` |

| Message | From | Meaning |
|---------|------|---------|
| `{ t: "exec", id, lua }` | plugin → `BrickadiaBridge` | run Lua |
| `{ t: "call", id, name, args }` | plugin → mod | call an `Omegga.handle` handler |
| `{ t: "reply", id, ok, result \| error }` | plugin → mod | answer to `Omegga.call` |
| `{ t: "result", id, ok, result \| error }` | Lua → the asking client | answer to exec or call |
| `{ t: "event", mod, event, data }` | Lua → every client | `Omegga.emit` |
| `{ t: "call", mod, id, plugin, event, args }` | Lua → every client | `Omegga.call`; the plugin answers |
| `{ t: "register", mod, name }` | Lua → every client | `Omegga.handle`; sent again to each client that connects |
| `{ t: "undeliverable", target, message }` | C++ mod → client | no listener for the target (mod stopped) |

The mod reads the socket on its own thread and hands messages to Lua from a `UEngine::Tick`
pre-callback, on the game thread, at the start of the next tick: a round trip is one server
frame (16.7 ms at 60 Hz, measured). Lua's sends are queued and written by the socket thread,
so a slow client never stalls the game. Clients other than the plugin (the acceptance tool,
scripts) can connect at the same time; answers go to the client that asked.

Lua mods use `__bridge_listen(name, fn)` and `__bridge_send(conn, line)` (registered in
every mod); `omegga.lua` wraps them. The plugin reconnects after a game restart; handler
routes are re-announced on every connection, so they never go stale.

## Caveats

- Handlers can be called before the map is loaded. Anything touching the world should check
  `BR.world.ready()` (the demo has a `ready` handler that plugins poll).
- A JS call into Lua times out after 30 s (`{ ok: false, error: '... did not answer ...' }`).
- An exception escaping a plugin's callback stops omegga's server, so the bridge client catches
  and logs everything; do the same in subscribers.
- Lua's `json` treats empty tables as `{}`; send `{ n = 0 }`-style objects rather than relying on
  empty arrays.

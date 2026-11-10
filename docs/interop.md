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
await ue4ss.emitPlugin('exec', 'return BR.brick_count()');   // { ok: true, result: 12 }

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
Omegga.watch("lamp", 50, function() return BR.is_visible(lamp_brick) end)
Omegga.unwatch("lamp")
```

`Omegga.id` is this mod's interop id (each mod is its own Lua state). `Omegga.plain(v)` is the
JSON-safe copy used for everything sent.

## Reacting to component changes

Brickadia's component logic is native code that doesn't go through UFunctions, so UE4SS has
nothing to hook when a gate's output changes. What works is a **signal brick**: wire the
output into a `Component_BrickPropertyChanger` on a brick, then watch that brick's property,
which a native getter can read.

```lua
local AND, CHANGER = "BrickComponentType_Expr_LogicalAND", "Component_BrickPropertyChanger"
local ps, owner = BR.player(), BR.owner_index()
local gate   = BR.place(BR.builder({ asset = "B_1x1_Gate_Expr_LogicalAND", owner = owner }), 0, 0, 6)
local signal = BR.place(BR.builder({ asset = "PB_DefaultBrick", size = { 5, 5, 6 }, owner = owner }), 40, 0, 6)
BR.transaction(ps, function(tx)
    tx.attach(BR.brick_id(signal), BR.component_type(CHANGER))
    tx.connect(BR.brick_id(gate), BR.output_port(AND, "bOutput"), BR.brick_id(signal), BR.input_port(CHANGER, "bVisibility"))
end)
Omegga.watch("gate", 50, function() return BR.is_visible(signal) end)
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
  from the exec and wire its bool into the signal brick. `BR.ports(type)` lists their outputs.

Other things a watch can poll cheaply: `BR.brick_count()`, a brick's position or color, entity
transforms (`BRLuauEntityLibrary:GetTransform`), `#BR.bots()`.

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
  `BR.ready()` (the demo has a `ready` handler that plugins poll).
- A JS call into Lua times out after 30 s (`{ ok: false, error: '... did not answer ...' }`).
- An exception escaping a plugin's callback stops omegga's server, so the bridge client catches
  and logs everything; do the same in subscribers.
- Lua's `json` treats empty tables as `{}`; send `{ n = 0 }`-style objects rather than relying on
  empty arrays.

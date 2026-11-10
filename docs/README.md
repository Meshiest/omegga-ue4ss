# omegga-ue4ss docs

What this plugin does, the APIs it gives Lua mods and omegga plugins, and what was learned
getting UE4SS to run on the Brickadia Linux server. Everything here was run on a server unless it
says otherwise.

| Page | For |
|------|-----|
| [architecture.md](architecture.md) | How the plugin, omegga, the launch wrapper and UE4SS fit together; files under `data/` |
| [interop.md](interop.md) | Lua mods and omegga plugins calling each other, events, reacting to component changes |
| [lua-api.md](lua-api.md) | The `omegga.brickadia` (`BR`) helpers, with recipes: bricks, gates, wires, component data, custom events, player events, players, entities, raycasts |
| [brickadia-internals.md](brickadia-internals.md) | Opaque struct layouts, world context, transactions and trust, property changelists, WireString, interactions |
| [signatures.md](signatures.md) | How signatures and vtable offsets are verified and corrected per game binary; after a game update |
| [linux-port.md](linux-port.md) | What it took to run UE4SS on this server: the port, its patches, ABI findings |
| [exploring.md](exploring.md) | Finding more of the game's API: object dumps, `dumpq`, testing calls safely |
| [reference/ufunctions.md](reference/ufunctions.md) | Generated list of the UFunctions these docs use |
| [`../types/`](../types) | Lua Language Server annotations for `BR`, `Omegga`, the native helpers and UE4SS's globals; game classes are generated per server ([editor completion](lua-api.md#editor-completion)) |

## Five-minute tour

A UE4SS Lua mod shipped by an omegga plugin (`plugins/my-plugin/mods/MyMod/Scripts/main.lua`
plus an empty `enabled.txt`):

```lua
local Omegga = require("omegga")
local BR = require("omegga.brickadia")

Omegga.handle("place_red_brick", function(x, y)
    assert(BR.ready(), "world not loaded yet")
    local h = assert(BR.place(BR.builder({ asset = "PB_DefaultBrick", size = { 10, 10, 6 }, color = { 255, 0, 0, 255 } }), x, y, 6))
    return BR.brick_info(h).position
end)
```

And the omegga plugin (`plugins/my-plugin/omegga.main.js`):

```js
const ue4ss = await omegga.getPlugin('ue4ss');
const reply = await ue4ss.emitPlugin('call', 'place_red_brick', 0, 0);
// { ok: true, result: [0, 0, 6] }
```

## The rules that bite

- **Never call a method on an invalid UObject.** UE4SS dereferences null and the server dies;
  `pcall` can't catch it. Check `obj:IsValid()`; `BR` helpers already do and raise Lua errors.
  Mods start before the map loads, so wait for `BR.ready()`.
- **Game-thread only.** UObject access from a `LoopAsync` body crashes. Wrap it in
  `ExecuteInGameThread`, as `Omegga.watch` and the handlers already do.
- **Raw values must be the type they claim.** A wrong layout in `BR.call`, or bytes of the wrong
  type in a changelist token, can crash the server. The `BR` helpers build them correctly; test
  anything raw on a scratch server.
- **Opaque structs need raw calls.** Many Brickadia UFunctions take structs UE4SS can't marshal;
  see [lua-api.md](lua-api.md#calling-any-ufunction).
- **Edits need an owner.** Transactions on bricks placed with the default owner come back
  `BricksUntrusted`; place them with `owner = BR.owner_index()`.
- **The world context is the UWorld**, not an actor in it (`BR.world_context()`).

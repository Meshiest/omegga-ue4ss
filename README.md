# omegga-ue4ss

Runs the Brickadia Linux dedicated server under [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS),
as an [omegga](https://github.com/brickadia-community/omegga) plugin. You get Lua and C++ mods
on a headless server, plus a way for omegga plugins to talk to them.

Needs omegga 1.23 or newer

## Install

```sh
omegga install gh:Meshiest/omegga-ue4ss
```

Then restart the server. Reloading the plugin doesn't relaunch the game.

Installing or updating the plugin (its `setup.sh`) downloads the two native binaries built from
its own source, UE4SS and the BrickadiaBridge mod, from this repo's `runtime` release. Each is
fetched on its own and only when the source needs a different build, so an update that changes
only the mod downloads only the mod, and both are installed together or not at all. A server
start doesn't touch the network: it uses what's in `runtime/`, and warns if those binaries were
built from other source (an update installed before CI had published its build; run `setup.sh`
again). `RUNTIME_BASE_URL` points `setup.sh` at another host. You can also build both with
`native/build.sh`; the plugin then uses `runtime/` as it is until you delete it.

Put mods in `data/Mods/`, the same as any UE4SS install (`mods.txt`, or an `enabled.txt` in
each mod). Other omegga plugins can ship UE4SS mods in their own `mods/` folder and they get
loaded too, as long as the plugin is enabled and not sandboxed.

## What happens on start

Before omegga launches the game, the plugin:

1. sets up `data/UE4SS/` (the runtime, layout files, a settings file pointing at the mod
   folders),
2. checks UE4SS's signatures against the exact binary omegga is about to launch, and fixes
   them up if a game update moved something (report in `data/UE4SS/signatures.txt`),
3. marks `data/UE4SS/` ready for that binary.

omegga then starts the game through `bin/launch.sh`. If anything didn't check out (no runtime,
a signature it couldn't find, the binary changed since), the game starts without UE4SS. The
server always comes up.

Crash reporting is turned off on every start with Brickadia's
`-AllowCustomArchivesAndDisableCrashReporterForVersion=CL<changelist>` switch, so a modded
server's crashes don't end up with Brickadia. The changelist has to match the binary, so the
plugin reads it from the binary each time. The game confirms it in its log with
`Custom archives ENABLED and crash reporting DISABLED for this session`. The same switch also
lets unsigned pak files load.

## Using it from other plugins

```ts
const ue4ss = await omegga.getPlugin('ue4ss');
await ue4ss.emitPlugin('exec', 'return 1 + 1');          // { ok: true, result: 2 }
await ue4ss.emitPlugin('call', 'greet', 'world');        // a Lua Omegga.handle('greet', fn)
await ue4ss.emitPlugin('subscribe', 'my-plugin', '*');   // Lua events -> pluginEvent('ue4ss:<event>', ...)
```

On the Lua side, `require("omegga")` handles events, calls and handlers, and
`require("omegga.brickadia")` covers bricks, gates, component settings, custom events, players,
player events (chat, deaths, clicks, building), entities, raycasts and so on. Editors get completion for that and for every game class, from types
UE4SS generates on the server ([docs/lua-api.md](docs/lua-api.md#editor-completion)).
[docs/README.md](docs/README.md) is the place to start, and
[examples/interop-demo](examples/interop-demo) is a small working plugin with its own mod.

## What mods can do

Everything below is in `require("omegga.brickadia")` (the `BR` global), documented in
[docs/lua-api.md](docs/lua-api.md). It runs on the server only: players need no mod, and what
they see arrives through the game's own replication.

**Building and the world**

- Place, read, change and delete bricks in transactions, as the game's tools do (`BR.brick`).
- Scripted brick types: a behaviour that runs for every brick of an asset, however it got
  there or went away (`BR.behavior`).
- Gates and components: ports, inputs, settings, wires, variables, arrays and maps
  (`BR.component`, `BR.wire`, `BR.var`).
- Custom events, sent and received without a gate in the world.
- Entities and dynamic grids: spawning, tags, custom properties, moving them along waypoints
  (`BR.entity`, `BR.mover`).
- Environment: time of day, weather, sky, fog, water, ground and lighting (`BR.env`).
- Labels in the world, prefabs, raycasts, spawning actors and projectiles (`BR.label`,
  `BR.prefab`, `BR.world`).
- Procedural generation: seeded noise, terrain and mazes in one transaction (`BR.gen`).
- Build regions: player plots, no-build areas, banned bricks and components, rules from zone
  bricks (`BR.region`, `BR.zone`).

**Players**

- Who is online, characters, health, movement, teleporting, inventories and item tuning
  (`BR.player`).
- Player events: chat (and rewriting it), joins, deaths, building, clicks, seats, keys,
  emotes and more, most of which a mod can refuse (`BR.event`).
- Screen text and panels, prompts that wait for an answer, hints, camera views and fades
  (`BR.ui`, `BR.player`).
- Chat to everyone or to chosen players, team and private channels (`BR.chat`,
  `BR.server`).
- Sounds in 2D, to chosen players, or from a point in the world (`BR.sound`).
- Audio through voice chat, and capturing what players say (`BR.voice`).
- Timed status effects, item pickups and who may take them (`BR.effect`, `BR.pickup`).
- Teams, leaderboards, permissions and roles (`BR.team`, `BR.leaderboard`, `BR.perm`).
- Moderation: kicks, bans, refusing joins, AFK times and suspicious-play signals (`BR.mod`,
  `BR.afk`, `BR.guard`).

**Bots and AI**

- Bots that are full players (name, avatar, tools, building, chat), driven from Lua:
  walking, following, pathfinding over bricks, aiming and firing (`BR.bot`, `BR.nav`,
  `BR.act`).
- The game's own NPCs from Bot Spawn bricks (`BR.npc`).

**Mod plumbing**

- Chat commands declared in the mod's `doc.json`, with permissions and aliases
  (`BR.command`), and command targets like `@team` (`BR.target`).
- HTTP routes on omegga's web server, under `/api/v1/plugin/ue4ss/`.
- Timers and cron schedules in game time (`BR.timer`).
- Storage: JSON stores, SQLite databases, admin config and secrets files (`BR.store`,
  `BR.db`, `BR.config`, `BR.secrets`).
- Shared state across mods and omegga plugins, removal signals, Prometheus metrics and a
  profiler for slow handlers (`BR.state`, `BR.watch`, `BR.metrics`, `BR.profile`).
- Vector, quaternion and rotator math in plain Lua (`BR.math`).
- Hooks on any UFunction, and raw calls for what the reflected API can't reach (`BR.event`,
  `BR.raw`).

Some things the server can set but clients don't show; [docs/client-checks.md](docs/client-checks.md)
tracks what has been tried with a real client. Among them: voice from a bot isn't heard, a
character's size and a grid's scale don't replicate, and a decal's material stays the default.

## Repo layout

| Path | What |
|------|------|
| `doc.json` | plugin manifest, with the `launch` block |
| `bin/launch.sh` | starts the game with UE4SS when it's ready for that binary, without it otherwise |
| `bin/run_ue4ss.sh` | the Linux port's preload launcher |
| `omegga.main.ts` | the plugin |
| `src/` | setup, signature checks, the socket client |
| `tools/` | not part of the plugin: dev CLIs (verify, acceptance, dumpq, built by `build:dev`), and `fetch-runtime.ts` and `runtime-keys.ts`, which `setup.sh` and CI run with Node's type stripping (checked by `tsconfig.tools.json`) |
| `test/` | unit tests |
| `overlay/` | signatures, memory layouts and the settings template |
| `mods/BrickadiaBridge/` | the bridge mod: Lua `exec`, plus the C++ half that owns the socket and the raw-call helpers |
| `lua/omegga/` | shared Lua libraries, copied to `data/Mods/shared/omegga/` |
| `types/` | Lua Language Server annotations: `omegga.lua` for the plugin's API, `ue4ss.lua` from UE4SS |
| `examples/interop-demo/` | example plugin with a mod |
| `docs/` | how it all works, the Lua API, and notes on Brickadia's internals |
| `native/` | C++ mod source, patches to the Linux port, and `build.sh` |

## Development

```sh
npm install
npm run typecheck                                        # the plugin's types, against the omegga.d.ts omegga copies in on load
npm test                                                 # unit tests
GAME_BINARY=<BrickadiaServer-Linux-Shipping> npm test    # also check signatures against a real binary
npm run verify -- <BrickadiaServer-Linux-Shipping>       # signature report for one build
native/build.sh                                          # build UE4SS and the bridge mod into runtime/
npm run acceptance                                       # end-to-end checks against a running server
npm run dumpq -- data/UE4SS/UE4SS_ObjectDump.txt '^BRLuauGridLibrary$'   # look up API signatures
```

After a game update, run `npm run verify` on the new binary. A `corrected` row still works,
but it means the signature in `overlay/UE4SS_Signatures/` is worth refreshing.

### Building the native runtime yourself

The plugin normally downloads its two native binaries (see [Install](#install)). To build them
instead, for a change to the C++ mod or the UE4SS patches:

1. Install clang 18 or newer, Rust (for UE4SS's patternsleuth), Python 3 with `venv`, and git.
2. Link your GitHub account to an Epic Games account and add an SSH key to GitHub. UE4SS's
   Unreal headers come from `github.com/tc-imba/UEPseudo`, which only Epic-linked accounts can
   read, and `build.sh` clones it over SSH.
3. Run `native/build.sh` (or `just runtime`).

The first run clones tc-imba's Linux port of RE-UE4SS at the commits in `native/patches/*.base`,
applies the patches there, sets up cmake and ninja in a venv, and builds everything into
`native/work/`, which takes a while. Later runs only rebuild what changed, so a mod change
takes about a minute. It finishes by running UE4SS's tests and copying `libUE4SS.so` and
`BrickadiaBridge/main.so` into `runtime/`.

`runtime/` then holds a `.local` marker, and the plugin uses those binaries as they are, never
downloading over them; restart the server to load them. Delete `runtime/` to go back to the
published builds.

### CI

CI (`.github/workflows/ci.yml`) runs the tests on every push. On `main` it builds whichever of the two binaries the `runtime` release doesn't have for this source (keys in
`src/runtime-keys.ts`) and uploads it; a mod-only change rebuilds only the mod, on a cached
UE4SS build. It needs a `GH_REPO_SSH` secret, because the Linux UEPseudo fork is Epic-gated.
Signature checks against the game binary only run locally; the binary can't be redistributed.

## Known gaps

- Hooks that haven't been checked on Linux yet (BeginPlay, EndPlay, AActor::Tick,
  InitGameState, LoadMap, UStruct::Link) are off in the settings template.
- Run outside omegga with UE4SS loaded, the game process can linger after the engine has shut
  down. Under omegga it doesn't matter: omegga sees the engine's exit in the log and ends the
  process.

## License

The plugin is public domain under CC0 1.0 ([LICENSE](LICENSE)). `bin/run_ue4ss.sh` and the
UE4SS runtime come from RE-UE4SS and stay under its MIT license ([LICENSE-UE4SS](LICENSE-UE4SS)).

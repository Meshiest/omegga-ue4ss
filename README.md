# omegga-ue4ss

Runs the Brickadia Linux dedicated server under [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS),
as an [omegga](https://github.com/brickadia-community/omegga) plugin. You get Lua and C++ mods
on a headless server, plus a way for omegga plugins to talk to them.

Needs omegga 1.22 or newer (for the `launch` block in `doc.json`).

## Install

```sh
omegga install gh:Meshiest/omegga-ue4ss
```

Then restart the server. Reloading the plugin doesn't relaunch the game.

On first start the plugin downloads the UE4SS runtime from this repo's release for its version
(`runtimeUrl`). You can also build one with `native/build.sh` and leave it in `runtime/`.

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

## Repo layout

| Path | What |
|------|------|
| `doc.json` | plugin manifest, with the `launch` block |
| `bin/launch.sh` | starts the game with UE4SS when it's ready for that binary, without it otherwise |
| `bin/run_ue4ss.sh` | the Linux port's preload launcher |
| `src/` | the plugin (setup, signature checks, the socket client); this is all `setup.sh` builds |
| `tools/` | dev CLIs: verify, acceptance, dumpq, and `tag.sh` for `just tag` (not shipped) |
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
npm install && npm run build
npm test                                                 # unit tests
GAME_BINARY=<BrickadiaServer-Linux-Shipping> npm test    # also check signatures against a real binary
npm run verify -- <BrickadiaServer-Linux-Shipping>       # signature report for one build
native/build.sh                                          # build runtime/ and the release tarball
npm run acceptance                                       # end-to-end checks against a running server
npm run dumpq -- data/UE4SS/UE4SS_ObjectDump.txt '^BRLuauGridLibrary$'   # look up API signatures
```

After a game update, run `npm run verify` on the new binary. A `corrected` row still works,
but it means the signature in `overlay/UE4SS_Signatures/` is worth refreshing.

CI (`.github/workflows/ci.yml`) runs the tests on every push. On a `v*` tag it builds the runtime
and attaches it to the release. It needs a `GH_REPO_SSH` secret, because the Linux UEPseudo
fork is Epic-gated. `just tag` tags the package.json version and pushes it, since the default
`runtimeUrl` uses that version. Signature checks against the game binary only run locally; the
binary can't be redistributed.

## Known gaps

- Hooks that haven't been checked on Linux yet (BeginPlay, EndPlay, AActor::Tick,
  InitGameState, LoadMap, UStruct::Link) are off in the settings template.
- Run outside omegga with UE4SS loaded, the game process can linger after the engine has shut
  down. Under omegga it doesn't matter: omegga sees the engine's exit in the log and ends the
  process.

## License

The plugin is public domain under CC0 1.0 ([LICENSE](LICENSE)). `bin/run_ue4ss.sh` and the
UE4SS runtime come from RE-UE4SS and stay under its MIT license ([LICENSE-UE4SS](LICENSE-UE4SS)).

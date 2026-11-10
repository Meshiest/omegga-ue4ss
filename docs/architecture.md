# Architecture

```
omegga start
  ├─ loads plugins ─────────────── ue4ss plugin init()
  │                                  prepare(): runtime, data/UE4SS, signatures, vtables
  │                                  connect to the game's bridge socket (and reconnect after restarts)
  ├─ collects doc.json `launch` blocks (omegga >= 1.22)
  └─ spawns: stdbuf -- plugins/ue4ss/bin/launch.sh <game binary> <args>
                          │
                          ├─ add Brickadia's crash reporter switch for this binary's changelist
                          ├─ ready marker matches this binary? no → exec the game unmodded
                          └─ exec data/UE4SS/run_ue4ss.sh <game> → LD_PRELOAD libUE4SS.so
                                                                     │
                     UE4SS: signatures, layouts, settings from data/UE4SS
                     mods from data/Mods, plugins/ue4ss/mods, other plugins' mods/
```

Every layer `exec`s, so the game keeps omegga's child PID and omegga's stop (SIGINT, SIGKILL)
reaches it.

## Omegga's part

omegga 1.22 added one generic feature: a plugin's `doc.json` may contain

```json
"launch": { "wrapper": "bin/launch.sh", "args": ["-NoRemoteFileAccess"], "env": { "K": "${dataDir}/x" } }
```

omegga reads it from every loaded, non-sandboxed plugin just before spawning the game (so a
change takes effect on the next server start), puts the wrapper in front of the game command,
appends the args and adds the env. `${dataDir}` and `${pluginDir}` are expanded. Everything else
in this document lives in the plugin. omegga also has `server.crashreports: false`
(it passes Brickadia's crash reporter switch); this plugin adds that switch itself in
`launch.sh`, because the value is the binary's changelist, which a static `args` can't know.

## The plugin's part

`init()` runs before the game is spawned, on every server start (and on plugin reload, which
doesn't relaunch the game):

1. **Runtime.** `runtime/libUE4SS.so` and `runtime/BrickadiaBridge/main.so`, downloaded once from
   `runtimeUrl` (the GitHub release for the plugin's version) or built by `native/build.sh`.
2. **`data/UE4SS/`**, the UE4SS working directory: `libUE4SS.so`, `run_ue4ss.sh`, layout files,
   a generated `UE4SS-settings.ini`. Files are replaced by write-and-rename, never in place: the
   running game maps `libUE4SS.so`, and a plugin reload must not change it underneath.
3. **Mod folders** in the settings: `data/Mods` (the server owner's), `plugins/ue4ss/mods` (the
   bridge) and the `mods/` of every enabled, non-sandboxed plugin that contains UE4SS mods.
4. **Shared Lua libraries** to `data/Mods/shared/omegga/`, so any mod can
   `require("omegga")` and `require("omegga.brickadia")`.
5. **Signatures and vtables** verified against the exact binary omegga will launch; see
   [signatures.md](signatures.md). Report in `data/UE4SS/signatures.txt`.
6. **Ready marker** `data/UE4SS/ready` = `<binary realpath> <size> <mtime>`, written only when
   everything required checks out. `launch.sh` compares it with the binary it is handed, so a
   Steam update between preparing and launching starts the game without UE4SS rather than with
   stale addresses.
7. **Editor config** `data/Mods/.luarc.json` for Lua Language Server, written once if absent.

After the first map loads (omegga's `mapchange`), the plugin
runs UE4SS's `GenerateLuaTypes()` through the bridge if the game binary differs from the one the
current types were made from ([editor completion](lua-api.md#editor-completion)).

## Files under `data/`

| Path | What |
|------|------|
| `data/Mods/` | the server owner's UE4SS mods (`mods.txt` or `enabled.txt` per mod) |
| `data/Mods/shared/omegga/` | `omegga.lua`, `brickadia.lua`, `json.lua` (managed by the plugin) |
| `data/Mods/.luarc.json` | Lua Language Server settings, written once; yours after that |
| `data/UE4SS/Mods/shared/types/` | generated annotations for every loaded game class; `.binary` names the build they came from |
| `data/UE4SS/UE4SS.log` | UE4SS's log for the current run |
| `data/UE4SS/signatures.txt` | per-symbol verification report for the last prepared binary |
| `data/UE4SS/UE4SS_Signatures/` | the signatures UE4SS loads (shipped AOBs or pinned addresses) |
| `data/UE4SS/bridge.sock` | the BrickadiaBridge C++ mod's socket, for `exec` and interop ([interop.md](interop.md)) |
| `data/UE4SS/crashes/` | UE4SS's signal handler output |
| `data/UE4SS/UE4SS_ObjectDump.txt` | written by `DumpAllObjects()` ([exploring.md](exploring.md)) |

## Failure behaviour

| Situation | Result |
|-----------|--------|
| no runtime, download fails | game starts without UE4SS; reason logged at plugin init |
| a required signature unresolved or conflicting | same |
| a vtable offset doesn't match | same |
| binary changed after prepare (Steam update) | same, logged by `launch.sh` |
| a non-Steam launcher script instead of the game ELF | same |
| a Lua mod errors | UE4SS logs it; the game keeps running |
| a Lua mod touches an invalid UObject or a bad raw call | the game crashes (no UE4SS protection) |

## Known gaps

- Outside omegga, with UE4SS loaded, the process can linger after the engine shuts down (UE4SS
  threads). omegga treats the engine's `LogExit: Preparing to exit.` line as the exit and kills
  the process, so a shutdown from inside the game (console `exit`) still ends cleanly.
- Hooks on vtable slots not verified on Linux (BeginPlay, EndPlay, AActor::Tick, InitGameState,
  LoadMap, UStruct::Link) are disabled in the settings template.
- UE4SS console commands (`RegisterConsoleCommandHandler`) are not reachable from the server's
  stdin console, so omegga can't use them; use the bridge.

# Exploring the game's API

How the APIs in these docs were found, for finding more.

## Dump everything

From any plugin (or a mod), write UE4SS's object dump:

```js
await (await omegga.getPlugin('ue4ss')).emitPlugin('exec', 'DumpAllObjects(); return "ok"');
// -> data/UE4SS/UE4SS_ObjectDump.txt (about 30 MB)
```

Each line is one object: classes, functions, properties (with offsets), structs, enums, live
instances. Search it directly:

```sh
grep -oE 'Class /Script/Brickadia\.[A-Za-z_]+Library' data/UE4SS/UE4SS_ObjectDump.txt | sort -u
grep -oE 'BasicBrick /Game/Bricks/[^ ]*Gate[^ ]*' data/UE4SS/UE4SS_ObjectDump.txt | sort -u
grep -E 'Property /Script/Brickadia\.BRPlayerState:' data/UE4SS/UE4SS_ObjectDump.txt
```

Or list function signatures with resolved types:

```sh
npm run dumpq -- data/UE4SS/UE4SS_ObjectDump.txt '^BRLuauGridLibrary$'
npm run dumpq -- data/UE4SS/UE4SS_ObjectDump.txt '.' '(?i)chat'
# BRLuauGridLibrary:FindInBox(Self: Object<BrickGridActor> @0, Min: Struct<IntVector> @8, ...)
```

`Struct<X>` parameters: check whether `X` has reflected fields (`grep 'Property /Script/Brickadia.X:'`).
None means opaque: use `BR.call`.

## Enums and ports

```lua
-- an enum's names and values
local e = StaticFindObject("/Script/Brickadia.EWireKind")
local out = {}
e:ForEachName(function(name, value) out[#out + 1] = name:ToString() .. "=" .. value end)
return out

-- a component type's ports
return BR.ports("BotSpawn")
```

## Trying a call

1. `__fn_layout("/Script/Brickadia.Class:Function")` shows the buffer: each param's offset and
   size. Compare it with `dumpq`.
2. Build args with `string.pack`, call with `BR.call`, and look at every param's bytes
   afterwards (hex them: `bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)`).
3. If a call does nothing, it usually checked something and returned early: a wrong
   WorldContextObject (must be the UWorld), a zero-count port ref, an untrusted brick, a player
   without a controller. The transaction report says which for transactions.

Test new calls on a scratch server, not a live one: a bad pointer or a method on an invalid
object takes the server down, and `pcall` doesn't catch it.

## When reflection runs out

Native behaviour (what a UFunction checks, struct layouts) was read from the server binary
with `objdump -d -M intel` and the native thunk address the dump prints for each function
(`[f: ...]`). The thunk unpacks params and calls the implementation; the implementation shows
what fields it reads, which values it rejects, and which class it `IsA`-checks. That is how the
port ref layout, the UWorld requirement and the controller requirement were found. The research
notes and tools (`xref.py`, `vtable.py`) live in a separate research repo.

## Open leads

- The player events and helpers against a real client: join and leave, the tool events
  (place, delete, change), emotes, damage, shooting, display text.
- Who dealt damage: the weapon RPCs (`BRWeaponBase:ServerApply*PredictedDamage`) carry it in
  structs not decoded yet.
- Posting to and hooking the custom event bus natively, instead of placing gates. Ruled out
  so far: the `br.DrawDebug.CustomEvents` counters only lead to the debug overlay, and the
  send gate type's vtable overrides look like port setup. Untried: code that reads the game
  mode's `MaxPendingCustomEventsPerGate` (the send queue), and receiver lookup by name near
  the WireString comparison. Its addresses would be build-specific, so it would need resolving
  like the UE4SS signatures, with the gate circuit as the fallback.
- `BRLuauWorldLibrary:OverlapBox` / `OverlapSphere`: array return values, through `BR.call`.
- Changelist tokens beyond leaf values (arrays, maps, enums, object references), for fields
  `BR.set_component` refuses today.
- `BRChatCommandWorldSubsystem:CallChatCommand` and round control on `BRGameModeBase`.

## The changelist method

The property changelist format was mapped by sending one token at a time and reading the
executor's error, which names the token ("Failed to execute token: PushArrayElement
Index=0"). The log reaches the file in batches, so wait about half a second after each call
before reading it. Unknown tags with a zero payload were safe to try at the root frame; a
payload of the wrong type for its tag is not.

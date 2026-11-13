# Brickadia internals used by the bridge

Reverse-engineered from the Linux server binary (stripped, non-PIE x86-64; addresses in this
file are not used at run time) and confirmed by behaviour on the running server. Field offsets
are bytes.

## The API layer

The `BRLuau*Library` classes (`Builder`, `Brick`, `Grid`, `Entity`, `World`, `Transaction`,
`Component`, `Player`, ...) are static UFunction libraries, the native layer that Brickadia
builds its own gameplay scripting on. Call them on their class default object, e.g.
`StaticFindObject("/Script/Brickadia.Default__BRLuauBrickLibrary")`.

Many of their parameters are structs with no reflected fields, which UE4SS's Lua marshalling
silently zeroes. They go through `__raw_call`, which fills a `ParmsSize` buffer at the
offsets reflection reports and runs `ProcessEvent`. Ref and out params come back in the same
buffer.

## WorldContextObject is the UWorld

`BRLuauBuilderLibrary:Place` checks `IsA(UWorld)` on its context and then takes the world's
`BRRegistry`; with any other object it fails without a message. `GetGlobalGrid` returns null
for actors too. Use the world itself (`BR.world.context()`, from grid → level → world).
UE4SS's `UObject:GetWorld()` returned a mis-wrapped object here, so don't use it.

## Opaque structs

| Struct | Size | Layout |
|--------|------|--------|
| `BrickHandle` | 8 | opaque; from `Place`'s `OutBrick`, `FindInBox`, `GetBricks` |
| `BrickPersistentHandle` | 4 | brick id for transactions (`BRLuauBrickLibrary:GetId`) |
| `BREntityPersistentHandle` | 4 | entity/grid id (`BRLuauEntityLibrary:GetId`); the global grid is 1 |
| `BRLuauBuilder` | 0x38 | asset and grid as weak object pointers, colour (`+0x0C`, B G R A), size (`+0x24`, 3 x int32), material alpha (`+0x30`), collision (`+0x31`), owner id, visible. Build it with the `Set*` UFunctions on a zeroed buffer, never by hand |
| `BRLuauPortRef` | 8 | `u32` port FName comparison index (bit 31 set for an output) · `u16 FirstTypeIndex` · `u16 TypeCount` |
| `WireValue` | 0x28 | payload at `+0x00`, `EWireKind` tag byte at `+0x20` |
| `BRLuauTransaction` | 0x30 | `FString MergeTag` · `FString Description` · action recorder pointer `+0x20` · executed flag `+0x28` |
| `BrickTransactionReport` | 0xB8 | 34 `int32` counters (placed, deleted, changed, blocked, skipped, untrusted, not found, invalid; the same for components, wires and entities), then `TArray CustomReportLines` |

### Port refs

A port ref matches the component types whose `u16` type index (at `+0x40` in the component
type object) falls in `[FirstTypeIndex, FirstTypeIndex + TypeCount)`. A ref with `TypeCount`
0 matches nothing, so a Set with it is silently dropped. `BR.component.input_port` uses the type's own
index and a count of 1.

The FName is the component's **property** name: `bInputA`, not a display name like "Input A".
A component type keeps its ports in two sorted maps (a TArray of `{FName, descriptor}` pairs):
inputs at `+0x180` (`BCSWireInputDescriptor`, 0xA8 bytes) and outputs at `+0x190`
(`BCSWirePortDescriptor`). That is how `BR.component.ports` lists them.

`BRLuauComponentLibrary:GetPortName` returns the plain FName text whatever the type fields
say, so it can't validate a ref.

### Wire values

`EWireKind`: Bool 0, Integer 1, Double 2 (the default), Color 3, Vector 4, Rotator 5, Quat 6,
String 7, Enum 8, Object 9, Brick 10, Component 11, Exec 12, Float 13, ... (`/Script/Brickadia.EWireKind`).
Bool, Integer and Double are a byte, int64 and double at `+0`. String (7) owns heap memory at
`+0x08` and is freed by the engine, so it can't be faked from Lua bytes.
Object (9) is a weak object pointer at `+0`: the object's index (the `InternalIndex` at `+0x0C`
of the object) and its serial number, as int32s; serial numbers live in the engine's object
array, so Lua can't build one yet.

## Transactions and trust

`BRLuauTransactionLibrary` records actions into a zeroed `BRLuauTransaction` and applies them
with `Execute(Self, Player)`. `Execute` does nothing (an all-zero report) unless:

1. the transaction hasn't run and recorded something,
2. `Player` is a valid PlayerState **whose Owner is a `BRPlayerController`** (it reads the
   controller's state at `+0x998`); the `BP_PlayerState_C` CDO or a PlayerState without that
   owner is ignored.

Each action is then checked against the brick owner's trust:

| Player | Brick owner | Result |
|--------|-------------|--------|
| spawned PlayerState + spawned controller | 0 (public, the builder default) | `BricksUntrusted` |
| same, with `bIsOwner = true` or `ReplicatedOwnerIndex = 0` | 0 | `BricksUntrusted` |
| same | the controller's index from `BRGameStateBase:IdOrRegisterBrickOwner(pc)` | **applied** |

So `BR.player.server()` spawns a `BP_PlayerController`, takes the `BP_PlayerState` the controller
creates for itself, and registers the controller as a brick owner. Bricks placed by `BR.brick.place`
with that owner index (`BRLuauBuilderLibrary:SetOwnerId`; placing bypasses trust) are the
player's own. Placing through the transaction (`RecordPlace`) with this player placed nothing.

### Permissions and admin gates

Execute also builds a `BrickTransactionPermissionStates` (13 bools: `bBuilding_IgnoreTrust`,
`bBuilding_EditPublic`, ..., `bBuilding_PlaceAdminGates` at `+0xB`) from the permissions of
**the controller's own `PlayerState`**, not the `Player` argument. A connect or set touching an
admin gate (component type flag at `+0xE9`: Broadcast Chat Message, the global custom event
gates, ...) without `bBuilding_PlaceAdminGates` is dropped with no counter at all, only a
report line: "You do not have permission to use admin gates." So:

| Player | Admin gate wire |
|--------|-----------------|
| a second PlayerState merely owned by the controller, even with the Admin role | refused |
| the controller's own PlayerState with the Admin role | connected |
| the controller's own PlayerState with `bIsOwner = true` | connected |

`BR.player.server()` sets `bIsOwner`, which grants every permission whatever the server's roles say
(the Owner role itself can't be given with `SetHasRole`). `BR.brick.transaction` returns the report
lines as `report.lines`: `CustomReportLines` is a TArray of FText at `+0x88`.

Results seen in the report:

| Action | Report |
|--------|--------|
| Set an input to a new value | `ComponentsChanged 1` |
| Set an input to its current value | `ComponentsSkipped 1` |
| Set a wired input | `ComponentsSkipped 1` |
| Set on an untrusted brick | `BricksUntrusted 1` |
| Connect | `WiresConnected 1` |
| Attach a component | `ComponentsAttached 1` |
| Connect or set on an admin gate without the permission | nothing; a report line |

Untested from this player: brick edits that need permissions beyond ownership, undo/redo
(`BRLuauTransactionLibrary:Undo(PlayerState)`), and running as a real connected player's
PlayerState.

## Bricks, assets, entities

- Brick assets: procedural `PB_*` (size from the builder), basic `B_*` (fixed size), e.g.
  `PB_DefaultBrick`, `B_Bot_Spawn_Point`, `B_1x1_Gate_Expr_<Gate>`. Gates generated per
  component: `Expr_LogicalAND/OR/NOT/XOR/...`, `Expr_Math*`, `Expr_Compare*`, `Expr_Bitwise*`,
  `Expr_String_*`, `Event_*` (chat command, player joined/left, death, round start/end, zone
  enter/leave).
- `Component_BrickPropertyChanger` is a component type with no brick asset of its own: attach
  it to any brick (`tx.attach`) and it maps wire inputs to that brick's visibility, collision,
  colour and material.
- Blueprint component types are data-only subclasses: they have no UFunctions of their own,
  so component behaviour can't be hooked.
- Entity types are found by asset name (`BRLuauWorldLibrary:FindEntityType("Entity_Ball")`);
  spawning the type `Entity_Ball_C` creates a `BP_Entity_Ball_C` actor.
- Bots: `BP_FigureV2_Bot_C` pawns controlled by `BP_BRBotController_C`, with no PlayerState.
- Entities are `BREntityActor` actors (`BP_Entity_Ball_C` < `BRPhysicsMeshEntity` <
  `BREntityActor`), not `BREntity` objects, so `BREntity:GetColor` isn't callable on them; the
  `BRLuauEntityLibrary` functions are.

## Exec wires and custom events

- Exec ports are ordinary ports in the component type's lookup maps (`OnChanged`, `Exec`,
  `ExecIn`, `ExecOut`); `RecordConnect` takes them like data ports. Lua can't fire an exec
  input directly, but a **Change Detector** (`B_1x1_Gate_Expr_ChangeDetectorExec`, input
  `Input`, exec output `OnChanged`) fires on the tick after its input gets a new value. Its first
  value only sets the baseline, and a wire made in the same tick as a set isn't live for it.
  `BR.brick.trigger` packages this.
- Send Custom Event (`PB_Gate_Exec_SendCustomEvent`, `...Global`) and the receivers
  (`PB_Gate_Event_Custom`, `...Global`) match on `EventName`, a `WireString` that is component
  data, not a port. Transactions only set ports; the name is written with a property changelist
  (below). Unnamed senders and receivers don't connect. `DataIn1..8` take `tx.set`.
  `BrickComponentType_Event_Custom:GetSenderEventNames(ReceiverBrick)` returned nothing even
  for named receivers, so it isn't a way to read names back.
- Entity custom properties exist only as gates (`Exec_Entity_Set/Get/RemoveCustomProperty`,
  `Key` a WireString input) with no UFunction.

### How a custom event travels

Addresses are from the CL16507 Linux server, for orientation only; anything built on this has to
find them by pattern.

- **Dispatch:** `0x7e4d210(UBRRegistry* reg, u64 name, i32 target, const BCSComponentHandle*
  sender, Payload* payload)` delivers one event. `name` is `FName(EventName)` (comparison index
  and number). `target` is 0 for a global event; a targeted send passes an id read from its
  `Target` object (+0x270). `sender` is the sending component's handle, the same 8 bytes
  `BRLuauComponentLibrary:Get` returns, so the sender's `EventName` and `Target` can be read
  from its component data.
- **Context:** `reg` is the world's `UBRRegistry`. The Send gate reads it from a global (`0x986f430`)
  that holds it only while the circuit simulation ticks and is 0 otherwise. The dispatcher
  requires `reg+0x464 != 0` and `reg+0x460 != 3`. Both read 1 outside the tick too.
- **Payload:** 8 wire values (0x28 bytes each) in an inline array (0x140 bytes), then a heap
  pointer (+0x140, null while inline), count (+0x148) and capacity (+0x14c), then an int (+0x150)
  the dispatcher fills in from the registry entry.
- **Routing:** the sender handle is resolved first, and an invalid one ends the send. Its component
  type's virtual at vtable +0x370 says whether the event is global. The registry key is
  `(name, global ? 0xffffffff00000001 : scope << 32)`, with `scope` taken from the sender's grid
  slot. So for a global event the key doesn't depend on which sender sent it. A map at `reg+0x3d0`
  takes the key to an entry (0x48 bytes; `+0x40` is the id copied into the payload), and a map at
  entry `+0x30` takes `target` to a list of receiver handles.
- **Receiving:** for each receiver, `0x74b81c0(receiver data, resolved handle, payload)` appends to
  a queue in the receiver's component data, past its reflected fields: `+0x228` is an id and
  `+0x230` a TArray of pending events. On its next tick the receiver (`0x74b8540`) copies the
  payload into `DataOut1..8` (`0x6f341a0` copies one wire value) and fires `ExecOut`.
- **Send gate:** `SendCustomEvent` caches the name's FName at +0x198 and the target id at +0x1a0,
  after its reflected fields (which end with `DataIn8`). The FName is built from `EventName` with
  the engine's FName constructor (find-or-add). `Target` is a weak object pointer; the id comes
  from a world subsystem lookup on the target object (`0x779ecc0(object + 0x270)`), so it isn't
  a plain field. The gate resolves it as soon as the Target wire is made, without firing, and it
  is 0 until then. Ids are stable across a restart.
- **Payload ownership:** the caller builds the payload (`TArray<WireValue, TInlineAllocator<8>>`,
  0x158 bytes, always 8 values; an unconnected input is a double 0), and destroys it after the
  call. Receivers copy each value, taking their own reference to a string.
- **Receiver queue:** a receiver keeps at most 64 pending events (the limit checked in the
  enqueue) and plays one per tick; events past the limit are dropped for that receiver.

How BR uses it (`BR.event.custom`, `on_custom`):

- The bridge finds the dispatcher by its opening checks, the same shape in every build seen so
  far with only the registry offsets changing: `cmpb $0, X(%rdi); je; cmpl $3, Y(%rdi); je;
  test %rsi, %rsi; je` (one match in the executable's code), then steps back to the prologue
  after the `int3` padding.
- **Listening** is a detour on the dispatcher. It copies the name, target, sender and the 8 raw
  values (plus each string's text, since a string value only points at it) into a ring of 4096
  events, which each Lua state reads with its own cursor. The detour runs inside the circuit
  tick, so Lua hears events at the start of the next engine tick.
- **Sending** does what the dispatcher does once it has resolved a sender, so no gate is needed
  (`__custom_event_post`). From the game thread, outside the circuit tick, with
  `FindFirstOf("BRRegistry")`, it builds the key itself: `(name, 1, -1)` for a global event, or
  `(name, 0, owner)` for a targeted one, since the scope a sender contributes is its brick's
  owner index. The map at `reg+0x3d0` and each entry's target map are dense (entries
  `0..Num-1` are all live), so they are scanned rather than hashed. Each receiver handle is
  resolved and queued through the same two functions the dispatcher calls, whose addresses
  the bridge reads from the dispatcher's call instructions after checking they are calls. A
  targeted event's id is `BRLuauEntityLibrary:GetId(entity).ElementID`, the same id a Send gate
  caches. The send is recorded for Lua listeners as the detour would. Strings are fresh
  `WireString`s, and the bridge drops the payload's reference afterwards as `TSharedPtr` does
  (controller vtable `{ DestroyObject, dtor, deleting dtor }`, atomic counts at +8 and +0xc), so
  a string nobody received is freed.

### Entity custom properties

`CustomProperties` (`TMap<FWireString, FWireValue>`, +0x2b8 on both `BREntityActor` and
`BrickGridDynamicActor`) is a dense compact map like the registry's: `Num` at +8, entries
`0..Num-1` live from the data pointer, 0x38 bytes each (the key's 16 bytes, then the value).
The Set/Get/Remove Custom Property gates and the applicator edit it. The applicator sends it
as part of an entity changelist (`ServerCopyEntity` fills `Clipboard_Entity`, `ServerPasteEntity`
applies it as a transaction of the owning player, so both need a `BRPlayerController` owner).
In that changelist the map is: push field `CustomProperties` (tag 2), tags 16 and 4, then per
entry tag 127 with the key's `WireString`, tag 25 with the value's wire kind (0 bool, 1 int,
2 double, 7 string; the game leaves it out when the kind is already right), the value's leaf
token (28 bool, 35 int64, 38 double, 42 `WireString`), and two pops (tag 3); then tag 5 and a
pop. A leaf that doesn't match the kind stops the rest of the changelist.

BR writes it without a player controller by appending a
`BrickAction_ApplyChangelistToEntity` to a Luau transaction (`__tx_append`). The transaction
(`FBRLuauTransaction`, 48 bytes) points at a `UBrickTransaction` at +0x20 (made by the first
record, with a reference held through the object array) and is marked run at +0x28. Its
actions are C++ structs with a vtable, built in place in an arena: transaction +0x40 first
page, +0x48 current, +0x5a locked, +0x5c pages, +0x60 actions; a page is 0x7ff0 bytes with
next and prev links, a u16 capacity (0x7fd8), bytes used and action count at +0x10..+0x14, a
fix-up flag at +0x16, data from +0x18, and a table of u16 action offsets growing down from
the end of the data. After filling an action, a record function calls its fourth virtual and
sets the page's fix-up flag when it returns true.

## Permissions

Permissions are gameplay tags under `BR.Permission`. A `BRPermissionsRole` holds `Permissions`
(`BRRoleData_PermissionState { Tag, State }`, `EBRSetPermission`: Allowed 0, Forbidden 1,
Unchanged 2) and `GameplayPermissionOverrides` (by name). Roles list lowest first from
`PermissionsManager:GetAllPermissionsRoles()`: Default, Moderator, Admin, Owner. A character
also carries `TempGameplayPermissions` (`TArray<FGameplayTag>`), which the Set Temp Permission
gate fills.

Every check, from the server's tools, chat and the UFunction alike, is
`BRPlayerState::HasPermission(FGameplayTag)`, which returns a bool. The tag travels by value in
one register (it is an FName). Tags the game marks as gameplay permissions take a path that
asks the owner flag and the role, then a per-player override returning allowed, forbidden or
unchanged. Every other tag asks the roles. The function isn't reflected. The UFunction's native
thunk (`UFunction+0xd8`, `GetFunc()`) reads the parameter and calls it, and that call is the
first direct `call rel32` in the thunk, which is generated code and keeps its shape between
builds.

The bridge detours it. Overrides are kept per player with a weak object pointer, so a
PlayerState that is destroyed and whose memory is reused can't inherit them. The tag is
matched, then each parent by trimming at the last dot. A trace mode records each check with
its result.

## Game mode delegates

`BRGameModeBase` broadcasts its state through dynamic multicast delegates: `OnPlayerJoined`,
`OnPlayerLeft`, `OnPreRespawnPlayer`, `OnRespawnPlayer`, `OnPlayerSwitchTeam`,
`OnPlayerCannotRespawnChanged`, `OnRoundStart`, `OnRoundEnd`, `OnRoundWon`, `OnRoundResolved`,
`OnReset`, `OnSessionStart`, `OnDestructableMemberTakeDamage` and
`OnDestructableMemberDestroyed`. Their signatures are `GameModeDelegate_*__DelegateSignature`
functions in `/Script/Brickadia` (`OnRoundWon`: `Result` `EBRRoundEndResult` at 0, `Players`
and `Teams` TArrays at 8 and 24; `OnPlayerSwitchTeam`: `State`, `OldTeam`, `NewTeam`). Few are
bound by anything on a plain server, so there is nothing to piggyback on.

A broadcast calls each bound object's UFunction through `ProcessEvent` with the signature's
parameters. The bridge binds a dummy object per binding (a `SceneComponent` made in the
`/Script/Engine` package, transient, in the root set so the garbage collector keeps it) by
`ExecuteUbergraph`, which every object has, using the engine's own
`FMulticastDelegateProperty::AddDelegate`. Its ProcessEvent pre-callback recognises the dummy,
passes the parameters on and prevents the call, so nothing runs on the dummy. A `NewObject` with
no outer asserts (`InOuter || (InClass == UPackage::StaticClass() && ...)`), and UE4SS's
`StaticFindObject` won't find `/Engine/Transient` by that path, hence the class's own package.

`OnRespawnPlayer` fires with the new character already possessed, on first spawn and on
respawn. Possession itself (`Controller:ReceivePossess`, `Pawn:ReceivePossessed`) never reaches
`ProcessEvent` here. Bots don't log in, so `OnPlayerJoined` doesn't fire for them, but
`OnPlayerLeft` does.

## Property changelists

`BCSLibrary:ApplyChangelist(WorldContextObject, BrickHandle, ComponentType, Changelist)` runs
`FBRPropertyChangelistExecutor` over the brick's component data, on built-in and attached
components alike. `BRPropertyChangelist` is `{ TArray<BRPropertyChangeToken> Tokens }`, and a
token is 32 bytes: a 0x18-byte payload and a type tag byte at `+0x18`. The executor keeps a
stack of frames (the component struct at the root) and logs every refusal under
`LogBRPropertyChange`, naming the token, which is how the tags were mapped:

| Tag | Token | Payload |
|-----|-------|---------|
| 0 | Null | |
| 1 | ResetToDefault | |
| 2 | PushField | FName |
| 3 | Pop | |
| 6..27 | array, set, map, optional, instanced struct, variant operations (ArrayClear, PushArrayElement, ArraySetNum, MapAddDefault, OptionalSet, PushInstancedStructElement_NewType, ...) | index, count or name |
| 28..44 | SetLeafValue | the value |
| 45..61 | SetLeafField | FName + value |
| 62..181 | set and map keyed operations (SetInsert, SetRemove, PushMapElement, PushMapElement_Add, MapRemove, MapMove), one tag per key type | key |

A leaf tag is 27 plus the value type tag of `BRPropertyValue` (`BRPropertyValueLibrary`
builds those: a 16-byte payload and a type byte at `+0x10`): bool 1, int8 2, uint8 3, int16 4,
uint16 5, int32 6, uint32 7, int64 8, uint64 9, float 10, double 11, FString 12, FName 13,
object 14, `WireString` 15. The leaf type must match the field exactly, and a mismatch is
refused with "Type mismatch or not a leaf property". The payload must really be the type its
tag says: an FString or FText given to the WireString tag (42) crashed the server, because the
type check passed and the bytes were then used as a WireString.

Setting one field is `PushField name, SetLeafValue value, Pop`; nested struct fields push
each level and pop as many. The changelist is only read during the call, so its token array
can be scratch memory.

A component type's data is a reflected UScriptStruct (`BrickComponentData_BotSpawn`,
`BCSComponentVertex_Exec_SendCustomEvent`, `BCSComponentVertex_Expr_BoolBool_Bool`), pointed to
from the type object at `+0x38`. Its fields are the component's ports and settings, so their
types come from reflection. Component data has no plain FString or FName fields: text is
`WireString`.

## WireString

16 bytes: `{ object*, controller* }`, a `TSharedPtr` made with `MakeShared`, so the controller
(`{ vtable, int32 shared, int32 weak }`) sits 0x10 bytes before the object in one 0x28-byte
block from the game's allocator (GMalloc). The game binary exports `operator new[]` and
`delete[]`, but `dlsym(RTLD_DEFAULT)` from the mod finds the C++ runtime's copies first, which
are plain `malloc`/`free`; `__game_alloc` and `__game_free` go through UE4SS's `FMemory`
instead. The object is `{ TArray<char>
text (UTF-8, NUL-terminated, num counts the NUL), uint32 hash, uint32 hashed }`; equality
compares length and `strcmp`, and the hash fields start at zero. `BR.wire.wirestring` builds one with
`__game_alloc` and the controller vtable read off a WireString the game made
(`BRLuauAssetLibrary:GetAssetName`). String wire values (`EWireKind` 7) carry a WireString as
their payload.

## Component storage

`BRLuauComponentLibrary:Get(Type, Brick)` returns a `BCSComponentHandle`, `{ uint32 index,
uint32 generation }`. Every component's data lives in one storage object: a base pointer at
`+0` and a bitmap of pages in use at `+0xC0`. The data is at `base + index * 16`, which is the
start of the component's own data struct (its first bytes, `{ uint32 generation, uint16 type
index }`, are the struct's base fields). Pages are 64 KB; each page's trailer holds its element
stride at `+0xFFF0` (the struct size, 256 for a bot spawner) and a reciprocal for dividing by
it at `+0xFFF8`. A handle is live when its page bit is set, its generation is odd and matches
the slot, and its offset is a whole number of strides into the page, which is what the game
checks and what `__component_data` repeats.

The storage object's address is build-specific, so the C++ mod finds it in the code of
`BRLuauComponentLibrary:GetType`, which loads it with `lea rsi, [rip + storage]; mov rdx,
[rsi + rdx*8 + 0xC0]`. Fields are then read at the offsets reflection gives
(`FProperty:GetOffset_Internal()`).

## Array and map variables

An Array Variable gate's `Value` is a `BRDynamicArray` (48 bytes, no reflected fields):
`{ void* data, int32 num, int32 max, UBRReflectionPropertyInfo* element, ops*, ops*, int64
element size }`. Elements are packed: Int64 and Double take 8 bytes, WireString 16. The info
object's class names the element type (`BRReflectionPropertyInfo_Int64`, `_Double`,
`_WireString`, ...); the two ops pointers are the same for every array of one type. The data
buffer is engine-heap memory: a buffer from `__game_alloc` can replace it (free the old one
with `__game_free`), and the engine grows it later with its own realloc.

A Map Variable gate's `Value` is a `BRDynamicMap` (72 bytes): `{ data, int32 num, int32 max,
key info*, value info*, hash index*, key ops*, value ops*, int32 key size, int32 entry size,
int64 value size }`. Entries are packed `{ key, value }` pairs, the value at `+key size`.
Lookups go through the hash index, whose layout isn't known yet, so keys can't be added or
removed from outside; values can be rewritten in place. The WireString keys' own cached hashes
(`+0x10` of the string object) are not what the index holds.

Both gates have a `MutationVersion` counter after `Value`, which array and map gates bump on
every change.

## Interactions and player events

A client interacting with a brick calls the server RPC
`BRCharacter:ServerMaybeStartInteract(BrickHandle, AnimType, bIsNearbyInteraction)` and
`ServerStopAnyInteract()` when it lets go. RPCs reach the server through ProcessEvent, so a
ProcessEvent pre-callback sees them; UE4SS's `RegisterHook` does too, but drops the
`BrickHandle` (no reflected fields), which is why the C++ mod passes raw parameter bytes
(`__on_call`). Calling the RPC on the server for a character presses the brick: a button's
`bHeld` output switches on.

The other player events hook the same way (the table in [lua-api.md](lua-api.md#player-events)).
Notes from testing them:

- `BRCharacter:MulticastHandleDeath` runs for any death, including `SetDamage(limit)`
  (damage type `DmgType_SelfDestruct`).
- `GameplayStatics:ApplyDamage` on a character on the unaffiliated team applied 0, and
  Brickadia's damage doesn't go through `ReceiveAnyDamage`; `MulticastPlayPainSound` is the
  multicast every hurt character plays.
- Tool RPCs can't be faked from the server: `ServerHammerBrick` on a hammer spawned outside an
  inventory read a null character and crashed. They need a real client to test.
- Targeted custom events (`PB_Gate_Exec_SendCustomEvent`, `Target` set) reach only
  `PB_Gate_Event_Custom` receivers on the target grid entity that have `bIsObjectEvent` set;
  global receivers and receivers on other grids don't hear them. `Target` is a
  `WeakObjectProperty` the changelist executor refuses ("may not be changed by this
  changelist"), and a transaction Set of an object wire value (kind 9 `Object`, with a weak
  or a raw pointer) is skipped, so it is wired from `Internal_ReadBrickGrid` (whose
  `BrickGrid` output is the weak pointer of its own grid). Wires between grids connect and
  carry both exec and data. Kind 27 (`StrongObject`) with a raw pointer crashed the server.
- Exec signals (custom events, gate execs) stay in native code. `BR.event.on_custom` turns them
  into data: the receiver's `ExecOut` drives a Variable Increment gate, whose variable is read
  every tick from component storage, along with the receiver's `DataOut1..8`.

## Players and characters

- `GameState.PlayerArray` holds every PlayerState, including ones spawned by Lua; a connected
  client's controller has a `NetConnection`, a spawned one doesn't.
- A spawned controller gets a character once it is on a team:
  `pc:JoinGameModeTeam(-1, true, false)` (unaffiliated, respawn) spawns a `BP_FigureV2_C`.
  `BRGameModeBase:RestartPlayer` did nothing; `BRPlayerController:RestartPlayer(true)` respawns.
  That is how the player helpers were tested without a client.
- Health is `DamageLimit - Damage` on `BRCharacter` (bots too). `SetDamage(limit)` kills: the
  body stays, `HasLivingCharacter` turns false.
- `ServerSetInventorySlot(slot, { Count, bIsPlaceable, ItemClass })` on the controller fills a
  slot; item classes are `Weapon_*_C` (`/Game/Weapons/Melee/Knife/Weapon_Knife.Weapon_Knife_C`).
  Bots have inventories (10 slots) but no controller to call it on.
- `ClientDisplayText`, `ClientPushStatusMessage`, `ClientShowMessageBoxDialog` and
  `ClientPushChatMessage` are client RPCs. On a controller with no connection, UE runs a client
  RPC locally, which would run client UI code on the dedicated server, so the helpers refuse
  them unless the player is connected. They have not been run against a real client yet.
- UFunction **array return values** (`GetAllTeams`, `GetRoles`) don't come back through UE4SS;
  use counts and getters (`GetNumTeams` + `GetTeam(i)`) or array properties.

## Bots

A bot is a spawned `BP_PlayerController`: no `NetConnection`, a real PlayerState, its own set of
builder tools (`PlayerState.PlacerTool`, and `BRTool_*` actors whose owner is the controller).

- **Removing one:** `K2_DestroyActor` on the controller returns and leaves it standing (still
  valid, not being destroyed, still in `PlayerArray`). `SetLifeSpan(0.01)` takes it, its
  PlayerState and its tools down on the next tick.
- **Tools:** each tool's server RPC (`ServerPlaceSimpleBrickVolume`, `ServerHammerBrick`,
  `ServerPaintBrick`, `ServerSetVisible`, `ServerConnectOrDisconnectComponentWire`) works called
  from Lua on the bot's tool, without wielding it. The checks they run, in order, for the Placer:
  the placement context, the brick asset, the material (`MaterialIndex` indexes
  `UBRGameInstance.BrickMaterials`, whose first three, hidden and ghost, are not
  `bUsableForPainting`), the team's gameplay permission (`BR.Permission.Building.Placer`; a game
  mode team that lists only the sub-permissions refuses), a per-player volume limit, then a
  transaction. `ColorAndAlpha`'s alpha byte is the material alpha (0 to 5); 255 makes every brick
  `BricksInvalid`. Refusals are sent to the controller as status messages (the middle print),
  which a controller with no connection never shows. What happened is left in
  `BrickTransactionManager.LastTransactionReport`.
- **Wires:** `FBCSWirePortRef` is `{ BCSComponentHandle (8 bytes), port FName }`; the component
  handle is what `BRLuauComponentLibrary:Get` returns as `OutComponent`, not the brick handle.
- **Movement (as a client):** a player controller is never local on a dedicated server, so
  `AddMovementInput` on its character does nothing; the server only moves it from the client's
  `ServerMove*` RPCs. Calling `Character:ServerMoveNoBase` works, after
  `PlayerController:ServerAcknowledgePossession(character)` (until a client acknowledges its
  pawn, `NotifyServerReceivedClientData` zeroes the move's acceleration). Timestamps must rise;
  a step of more than half of `MinTimeBetweenTimeStampResets` (240 s) forward is dropped as a
  stale move. `CompressedMoveFlags`: `0x01` jump, `0x02` crouch, `0x04` and `0x10` fly, `0x20`
  sprint. But weapon input (`PendingWeaponSimInputs`: desired slot, `EBRWeaponInputKeys`) only
  travels in the packed move (`ServerMovePacked`), and is rebuilt from every move, so a bot
  driven this way can't use weapons.
- **Driving with an AI controller:** an `AIController` possessing the bot's character is local,
  so movement input, `SetControlRotation`, `Crouch`, `CharacterMovement:SetSprinting`,
  `SetDesiredMainInventoryIndex` (switch weapons) and `Weapon:SetPredictedWeaponInput(key,
  pressed)` (fire 1, reload 4) all apply directly. Possession leaves the character without a
  PlayerState; setting `character.PlayerState` and `PlayerState.PawnPrivate` back keeps team,
  damage and the player helpers working, but then `IsPlayerControlled()` is true and the game
  casts the controller to its player controller, failing into a deliberate null read (a crash,
  seen on equipping and on death). Setting `PlayerState.bIsABot` makes `IsPlayerControlled()`
  false: no crash. Deaths still fire `MulticastHandleDeath`, with no killer controller (the cause,
  a projectile, carries the shooter's `InstigatorState`), and the game doesn't respawn the bot. Pickups
  (`HandlePickupAttempt`) only arm a character a player controller holds; possessing it back
  for the pickup and handing it over again is fine with `bIsABot` set. A character possessed by
  a different controller must carry the victim's PlayerState for damage to land (its team).
- **Attaching grids and entities to a character:** freeze them first. `K2_AttachToActor` (to the
  capsule) tracks exactly on the server, but clients see the grid trail loosely behind, and a
  bot carrying one gets pushed around by it. `K2_AttachToComponent(character.Mesh, socket)`
  (e.g. `Part_Head`) holds rigidly on a real client.
- **Interaction:** `ServerMaybeStartInteract` on the bot's character presses buttons and flips
  switches. A placed `B_Button` carries `Component_Internal_AnimatedButton` (`bHeld`,
  `PressCount` while held), a `B_Switch_Test` `Component_Internal_AnimatedSwitch` (`bEnabled`),
  not the `Component_Button` / `Component_Switch` types their ports are documented under.
- **Jumping:** `ACharacter:Jump()` holds the jump key, and an AI-driven character keeps
  jumping on every landing until `StopJumping()`; the driver releases it a tick later.
- **Sprinting:** `UBRCharacterMovementComponent` keeps two unreflected bytes after
  `OnControlModeChanged` (+0x10): `+0x13` is sprinting (what `GetSprinting` reads, along with
  the team rule allowing it) and `+0x14` wants to sprint (what `SetSprinting` writes). Each
  movement update copies want into sprinting, except with tap-to-sprint
  (`BRGameSettingsBase_Controls.bTapToSprint`, on in a server's defaults): a sprint then only
  ends when the character slows down or moves against its facing. `BR.bot.sprint(ps, false)`
  clears the sprinting byte itself.
- **Sitting:** `ABRCharacter:IsSitting()` is a seat brick only. The Sit emote shows as
  `BP_Emote_Sit_C` in `ActiveEmotes`. An emote stays there after `ServerStopEmoting` until the
  owning client reports `ServerFinishEmote`, which a bot never does.

## Voice

Voice chat has no UFunctions. Each client connection has a `UBRVoiceChannel` (channel type
`BRVoice`); the controller keeps it at `+0x13d8`. A client sends `{ u16 length, u64 position,
u32 burst, Opus frame }`, and the channel's `ReceivedBunch` (vtable slot 91) passes it to the
routing function `route(UWorld*, ABRPlayerState* talker, const TArray<uint8>& frame, u64
position, u32 burst)`, which a listen server's own encoder also calls. It checks the talker's
voice chat permission, then for each listener in earshot writes `{ u32 talker PlayerId, u16
length, u64 position, u32 burst, frame }` down their voice channel. The client finds the talker
by PlayerId, checks mutes, and plays the frame through the voice component on the talker's
character (`+0x6f8`). From the encoder: a frame is one `opus_encode` output of at most 512
bytes; position counts samples, advancing by the frame size; burst counts talk bursts.

## Roles and chat

- `BRPermissionsManager` (on the game state): `OwnerRole`, `DefaultRole` and `CustomRoles` as
  reflected properties; each `BRPermissionsRole` has `Name`, `Permissions`, `Color`. Read roles
  from these properties: the `GetAllPermissionsRoles()` return value comes back from UE4SS as
  a plain table with the first element repeated.
- `BRGameModeBase:PushChatMessage(msg)` broadcasts; the console command is `br.Chat.Broadcast`.

## Brick handles

`BrickHandle` is `{ u32 index, u32 generation }`, looked up in a global table; an odd
generation that matches the slot's is live. `BRLuauBrickLibrary:IsValid` returns false for
anything else, but **every other function taking a handle runs a fatal check** and aborts the
server for a null or stale one (seen with the empty `Brick` of a trace hit). `BR` checks
`IsValid` before any other brick call.

## Traces

`BRLuauWorldLibrary:Raycast(Origin, Direction, OutHit, WorldContextObject, MaxDistance,
Channel, Targets, bComplex)`: `EBRLuauTraceChannel` 1..15 (`Brick`, ..., `Visibility` 14) and
`EBRLuauTraceTargets` bits (`Brick` 1, `PhysicsBody` 2, ..., `WorldStatic` 1024, `All` 2047).
Channel 0 or targets 0 hit nothing, which is why earlier zeroed attempts missed.
`BRLuauTraceHit` (0x48): Entity `+0`, Brick `+8`, Position `+0x10`, Normal `+0x28`, Distance
`+0x40`.

## Found on a live server

- **The stand-in's owner entry has an all-zero GUID** and a blank name, which is what players see
  as the owner of bricks placed with `BR.player.owner_index()`. Deleting them in a transaction run by
  the stand-in reports `BricksBlocked`; the same transaction run by a real player (the server
  owner) deletes them. Registering a named owner with
  `ABRGameStateBase:IdOrRegisterBrickOwner_NotPresent({ OwnerGuid, OwnerName, OwnerDisplayName })`
  works and is idempotent per GUID, but the stand-in can't edit bricks owned by it either.
  `IdOrRegisterBrickOwner(pc)` gives a real player's own owner index, so bricks placed with it show
  their name and they can hammer them.
- **The stand-in counts as a player.** Its controller has a PlayerState, so the server's player
  count (and the server list) is one higher than the real players.
- **A builder needs `SetMaterial`.** Bricks from a builder that never had it are reported visible
  by the server but drawn as nothing by clients; `BR.brick.builder` always sets one.
- **Procedural bricks have a size limit.** A half-extent of 80 (16 studs) placed; 90 was refused.
  The exact limit wasn't pinned down.
- **`BRLuauGridLibrary:InBox(grid, min, max, maxResults)`** lists the bricks in a box. Its
  `TArray<FBrickHandle>` return is read raw: `{data, num}`, 8 bytes per handle.
  `BrickInstanceStatics:GetBrickOwnerData(world, handle)` returns `FBrickOwnerData`
  (GUID at 0, name FString at 0x10, display name at 0x20).
- **Projectile impacts** reach ProcessEvent through `BRWeaponProjectile:ProcessStop(FHitResult)`,
  even for weapons whose shots replicate as accelerated projectiles. `FHitResult` offsets:
  Location 0x10, ImpactPoint 0x28, Normal 0x40, ImpactNormal 0x58, TraceStart 0x70,
  TraceEnd 0x88, HitObjectHandle 0xB8, BoneName 0xE0.
- **Compare UObjects by address.** Two UE4SS wrappers of the same object can compare unequal
  with `==`; use `__addr(a) == __addr(b)`.

## Engine layout facts (Linux)

| Fact | Value |
|------|-------|
| `FUObjectItem` | 0x18 bytes: flags at `+0`, Object at `+8`, SerialNumber at `+0x10`; 65536 per chunk |
| `FUObjectArray` | as the Windows layout: NumElements `+0x08`, ObjFirstGCIndex `+0x20`, ObjObjectsCritical (a 40-byte pthread mutex) `+0x30`, ObjAvailableListEstimateCount `+0x68` |
| `FProperty` | ArrayDim `+0x2C`, ElementSize `+0x30` (Itanium tail padding; Windows `+0x30`/`+0x34`) |
| `UStruct` | PropertiesSize `+0x58`, MinAlignment `+0x5C` |
| `UClass` | ClassFlags `+0xD8` |
| `FFrame` | Node `+0x10`, Object `+0x18`, Code `+0x20` |
| `FMalloc::Malloc` | vtable `+0x30` |
| name pool | entries indexed `Blocks[idx >> 16]`, 2-byte stride, header `len = hdr >> 6` |

---@meta
-- Typings for omegga-ue4ss Lua mods, for Lua Language Server (LuaLS / sumneko).
-- See docs/lua-api.md#editor-completion for the setup. UObject, FName and the
-- UE4SS globals come from ue4ss.lua next to this file; every game class comes
-- from the types the plugin generates on the server.
--
-- `BR` and `Omegga` are globals in the bridge's `exec` snippets. In your own
-- mod, annotate the require:
--
--     ---@type BRModule
--     local BR = require("omegga.brickadia")
--     ---@type OmeggaModule
--     local Omegga = require("omegga")
--
-- Raw engine values (handles, port refs, wire values) are Lua strings of bytes;
-- the aliases below only name what each string holds.

---@alias BrickHandle string 8 bytes: { index, generation }
---@alias BrickId string 4 bytes: a brick's persistent id, for transactions
---@alias PortRef string 8 bytes: BRLuauPortRef
---@alias WireValue string 0x28 bytes: payload + EWireKind tag
---@alias WireString string 16 bytes: shared pointer to the text
---@alias Builder string 0x38 bytes: BRLuauBuilder
---@alias Bytes string
---@alias Vec3 number[]
---@alias Color number[]
---@alias BrickMaterial "Plastic"|"Glass"|"TranslucentPlastic"|"Glow"|"Metal"|"Hologram"
---a component type: its object, or a name for BR.component.type
---@alias ComponentType UObject|string

---@alias PlayerEvent
---| "join"
---| "leave"
---| "chat"
---| "typing"
---| "death"
---| "damage"
---| "emote"
---| "emote_end"
---| "interact"
---| "interact_end"
---| "shoot"
---| "projectile_hit"
---| "avatar"
---| "melee_hit"
---| "place"
---| "delete"
---| "change"
---| "spawn"
---| "team"
---| "respawn_lock"
---| "round_start"
---| "round_end"
---| "round_won"
---| "reset"
---| "session_start"
---| "sprint"
---| "walk"
---| "crouch"
---| "sit"
---| "water"

---@alias MovementMode "walk"|"fall"|"fly"|"swim"|"none"|"custom"

---How a character is moving (BR.player.movement)
---@class Movement
---@field seated boolean in a seat brick
---@field sitting boolean seated, or playing the Sit emote
---@field crouching boolean
---@field sprinting boolean sprint held while moving, walking or flying
---@field walking boolean moving on the ground, neither sprinting nor crouching
---@field moving boolean any horizontal motion
---@field speed number horizontal speed, units/s
---@field mode MovementMode
---@field in_water boolean in the world's water or a water zone

---@class TransactionReport
---@field BricksPlaced integer
---@field BricksDeleted integer
---@field BricksChanged integer
---@field BricksBlocked integer
---@field BricksSkipped integer
---@field BricksUntrusted integer
---@field BricksNotFound integer
---@field BricksInvalid integer
---@field ComponentsAttached integer
---@field ComponentsDetached integer
---@field ComponentsChanged integer
---@field ComponentsQuotaExceeded integer
---@field ComponentsUnattachable integer
---@field ComponentsUndetachable integer
---@field ComponentsSkipped integer
---@field ComponentsNotFound integer
---@field ComponentsInvalid integer
---@field ComponentsRestricted integer
---@field WiresConnected integer
---@field WiresDisconnected integer
---@field WiresUnconnectable integer
---@field WiresUndisconnectable integer
---@field WiresSkipped integer
---@field WiresNotFound integer
---@field WiresInvalid integer
---@field EntitiesPlaced integer
---@field EntitiesDeleted integer
---@field EntitiesChanged integer
---@field EntitiesBlocked integer
---@field EntitiesSkipped integer
---@field EntitiesUntrusted integer
---@field EntitiesNotFound integer
---@field EntitiesInvalid integer
---@field EntitiesOverQuota integer
---@field lines string[] refusals without a counter, such as admin gates

---a brick id: BR.brick.id's bytes, the id tx.place returned, or the id as a number
---@alias TxId BrickId|integer
---an entity: the BREntityActor (or dynamic grid), or its id
---@alias TxEntity UObject|BrickId|integer
---BR.brick.transform's table, or its bytes
---@alias TxTransform BrickTransform|Bytes

---An FTransform in world units (BR.brick.transform)
---@class BrickTransform
---@field pos? Vec3 default {0, 0, 0}
---@field rot? number[] quaternion {x, y, z, w}, default none
---@field scale? Vec3|number default 1

---Positions and sizes are whole grid units; orientations default to BR.brick.Z_UP.
---@class Transaction
---@field place fun(builder: Builder, pos: Vec3, orientation?: integer, grid?: TxEntity): BrickId the new id, usable later in the same transaction; grid defaults to the world grid
---@field restore fun(id: TxId, builder: Builder, pos: Vec3, orientation?: integer, grid?: TxEntity) put a deleted brick back under its id
---@field delete fun(id: TxId)
---@field move fun(id: TxId, pos: Vec3, orientation?: integer)
---@field reorient fun(id: TxId, orientation?: integer)
---@field resize fun(id: TxId, size: Vec3, pos: Vec3) procedural bricks; size is half extents
---@field color fun(id: TxId, color: Color, material?: BrickMaterial|integer, alpha?: integer) with a material, the material and alpha (default 5) change too; alpha needs a material
---@field material fun(id: TxId, material: BrickMaterial|integer, alpha?: integer) alpha defaults to 5
---@field collision fun(id: TxId, channels: integer|boolean) BR.brick.COLLISION bits; true/false for all/none
---@field visible fun(id: TxId, visible: boolean)
---@field owner fun(id: TxId, ps: UObject)
---@field set fun(id: TxId, port: PortRef, value: WireValue)
---@field connect fun(sourceId: TxId, output: PortRef, targetId: TxId, input: PortRef)
---@field disconnect fun(sourceId: TxId, output: PortRef, targetId: TxId, input: PortRef)
---@field attach fun(id: TxId, componentType: UObject)
---@field detach fun(id: TxId, componentType: UObject)
---@field place_entity fun(class: BR.EntityClass|string|UObject, transform: TxTransform, opts?: { frozen?: boolean, owner?: integer }): BrickId the new entity's id
---@field move_entity fun(entity: TxEntity, transform: TxTransform)
---@field delete_entity fun(entity: TxEntity)
---@field entity_color fun(entity: TxEntity, slot: integer, color: Color)
---@field physics fun(entity: TxEntity, enabled: boolean)
---@field connect_joint fun(jointId: TxId, entity: TxEntity, transform: TxTransform)
---@field disconnect_joint fun(jointId: TxId, entity: TxEntity)

---@class BuilderOptions
---@field asset? BR.BrickAsset|string
---@field size? number[]
---@field color? Color
---@field material? BrickMaterial|integer default "Plastic"
---@field alpha? integer material alpha, default 5
---@field grid? UObject
---@field owner? integer
---@field visible? boolean
---@field collision? boolean

---@class CustomEventOptions
---@field target? UObject send only to this entity
---@field owner? integer with target: reach receivers built by this owner index (default the entity's owner)

---@class CustomEventListenOptions
---@field entity? UObject listen for events sent to this brick grid entity

---@class CustomEventInfo
---@field name string
---@field target integer the entity id a targeted event went to; 0 for a global event
---@field sender Bytes the sending gate's component handle (zeros for a BR send)

---@class BrickInfo
---@field valid boolean
---@field asset? UObject
---@field position? number[]

---@class PlayerInfo
---@field name string
---@field display_name string
---@field id string
---@field owner boolean
---@field connected boolean
---@field team? string
---@field alive boolean
---@field health? number
---@field max_health? number

---@class TeamInfo
---@field id integer
---@field name string
---@field color Color
---@field members string[]

---@class InventorySlot
---@field slot integer
---@field count integer
---@field item? string

---@class Vector2Table
---@field X number
---@field Y number

---@class ColorTable
---@field R number
---@field G number
---@field B number
---@field A number

---@class DisplayTextParams
---@field Text string
---@field PersistentId? integer
---@field Position? Vector2Table
---@field Anchor? Vector2Table
---@field Pivot? Vector2Table
---@field Scale? Vector2Table
---@field Angle? number
---@field ZOrder? integer
---@field FontSize? integer
---@field FontColor? ColorTable
---@field OutlineSize? number
---@field OutlineColor? ColorTable
---@field WrapWidth? number
---@field Justification? integer
---@field Lifetime? number
---@field [string] any

---@class TraceOptions
---@field distance? number
---@field channel? string|integer
---@field targets? string|integer
---@field complex? boolean

---@class TraceHit
---@field position Vec3
---@field normal Vec3
---@field distance number
---@field brick? BrickHandle
---@field entity? UObject

---@class ComponentField
---@field name string
---@field type string

---@class Trigger
---@field brick BrickHandle
---@field connect fun(target: BrickHandle, componentType: string, port: string): TransactionReport
---@field fire fun(): TransactionReport

---@class CustomEvent
---@field send fun(...: WireValue): integer the receiver gates it reached

---@class PortList
---@field inputs string[]
---@field outputs string[]

---@class SpawnEntityOptions
---@field frozen? boolean
---@field owner? integer

---@class BotSpawnOptions
---@field team? integer game mode team id to join (default -1, unaffiliated)
---@field respawn? boolean false: no character until BR.player.respawn
---@field weapons? string[] weapon names ("Pistol", "Longsword", ...), given on every spawn
---@field respawn_after? number|false seconds after a death before it respawns (default 3); false: never on its own

---@class MoveToOptions
---@field radius? number how close counts as there, default 40 units
---@field on_arrive? fun(ps: UObject)
---@field on_fail? fun(ps: UObject) it stopped getting closer

---@class NavFindOptions
---@field max_nodes? integer cells to search before giving up, default 3000
---@field budget? integer traces per tick, default 200 (about 10 ms)

---@class PathToOptions: MoveToOptions, NavFindOptions
---@field graph? boolean follow the baked graph (BR.nav.route) instead of searching

---@class NavPoint
---@field [1] number
---@field [2] number
---@field [3] number
---@field jump? boolean it takes a jump up to reach this point

---@class PlaceOptions
---@field position Vec3 grid units, the brick's center
---@field asset? BR.BrickAsset|string default "PB_DefaultBrick"
---@field size? Vec3 half extents, for procedural bricks
---@field orientation? integer default BR.brick.Z_UP
---@field color? Color {r, g, b}
---@field material? BrickMaterial default "Plastic"
---@field alpha? integer material alpha, default 5
---@field count? Vec3 copies along +x, +y, +z (default {1, 1, 1})

---@class PaintOptions
---@field color? Color {r, g, b}
---@field material? BrickMaterial
---@field alpha? integer

---@class WirePort
---@field brick BrickHandle
---@field type ComponentType
---@field port string e.g. "bOutput", "bInputA"

---@enum BREmote
local BREmote = {
    Beckon = "BP_Emote_Beckon", Clap = "BP_Emote_Clap", Dab = "BP_Emote_Dab", Facepalm = "BP_Emote_Facepalm",
    HatBow = "BP_Emote_Hat_Bow", Hug = "BP_Emote_Hug", Nod = "BP_Emote_Nod", Point = "BP_Emote_Point",
    ShakeHead = "BP_Emote_ShakeHead", Shrug = "BP_Emote_Shrug", Sit = "BP_Emote_Sit", Think = "BP_Emote_Think",
    TipHat = "BP_Emote_Tip_Hat", Wave = "BP_Emote_Wave",
}

---@class BRRaw
---@field call fun(target: UObject, class: string, fn: string, args: table<string, Bytes>): table<string, Bytes>
---@field ptr fun(obj?: UObject): Bytes
---@field obj fun(bytes: Bytes): UObject?
---@field bool fun(bytes: Bytes): boolean
---@field i32 fun(bytes: Bytes): integer
---@field ivec fun(x: number, y: number, z: number): Bytes
---@field fstring fun(bytes: Bytes): string
---@field new_fstring fun(text: string): Bytes a new FString (UTF-8 in) on the game heap, for a parameter the engine frees
---@field ftext fun(bytes: Bytes): string
---@field take_handles fun(array: Bytes): BrickHandle[] the handles in a returned TArray's 16 bytes; frees its buffer

---@class BRWorld
---@field explode fun(position: Vec3, opts?: { kind?: BR.Explosion|string, normal?: Vec3, scale?: number, damage?: number, projectiles?: boolean }): boolean
---@field explosion_kinds fun(): string[]
---@field round fun(): integer
---@field session_running fun(): boolean
---@field next_round fun(immediate?: boolean)
---@field win fun(players?: UObject[], teams?: UObject[])
---@field draw fun()
---@field reset_game_mode fun()
---@field rule fun(kind: BR.GameRule|BR.TeamRule|string, create?: boolean): UObject? a game-wide rule; team rule kinds then apply to everyone
---@field rules fun(): { kind: string, rule: UObject }[]
---@field remove_rule fun(rule: string|UObject)
---@field rule_kinds fun(): string[]
---@field overlap_sphere fun(center: Vec3, radius: number, opts?: TraceOptions): { actor: UObject, grid: UObject? }[]
---@field overlap_box fun(center: Vec3, extent: Vec3, opts?: TraceOptions): { actor: UObject, grid: UObject? }[]
---@field players_near fun(center: number[], radius: number): { player: UObject, character: UObject, distance: number }[]
---@field ready fun(): boolean
---@field context fun(): UObject
---@field global_grid fun(): UObject
---@field game_mode fun(): UObject
---@field load_prefab fun(name: string, x: number, y: number, z: number, orientation?: integer): integer bricks added; loads Saved/Prefabs/<name>.brz additively, its bounds corner at (x, y, z)
---@field grids fun(): UObject[]
---@field teleport fun(actor: UObject, x: number, y: number, z: number): boolean
---@field spawn fun(class: UObject): UObject
---@field spawn_projectile fun(class: string|UObject, from: Vec3, dir: Vec3, opts?: { speed: number?, damage: number?, scale: number?, instigator: UObject? }): UObject
---@field projectile_types fun(): string[]
---@field TRACE_CHANNEL table<string, integer>
---@field TRACE_TARGETS table<string, integer>
---@field raycast fun(origin: Vec3, direction: Vec3, opts?: TraceOptions): TraceHit?
---@field sweep fun(origin: Vec3, direction: Vec3, radius: number, opts?: TraceOptions): TraceHit?

---@alias BREnumKind "brick_asset"|"component"|"item"|"entity"|"explosion"|"team_rule"|"game_rule"|"permission"|"material"|"collision"|"emote"|"emoji"|"font"|"sound"

---@alias UIAnchor "top_left"|"top"|"top_right"|"left"|"center"|"right"|"bottom_left"|"bottom"|"bottom_right"
---@alias UIEasing "linear"|"ease_in"|"ease_out"|"ease_in_out"
---@alias UIColor integer[]|string {r, g, b, a?} or "rrggbb[aa]"

---@class UIOptions
---@field text? string rich text markup works
---@field x? number screen units at 1080p from the anchor
---@field y? number
---@field anchor? UIAnchor|number[]
---@field pivot? UIAnchor|number[] defaults to the anchor
---@field size? integer font size, default 24
---@field color? UIColor
---@field outline? integer
---@field outline_color? UIColor
---@field shadow? number[] {x, y} offset
---@field shadow_color? UIColor
---@field scale? number|number[]
---@field angle? number
---@field z? integer
---@field wrap? number
---@field align? "left"|"center"|"right"
---@field font? BR.Font|string
---@field typeface? "regular"|"bold"|"italic"|"bold_italic"
---@field spacing? number
---@field skew? number
---@field line_height? number
---@field lifetime? number seconds; 0 stays
---@field transition? number seconds, for the first send
---@field easing? UIEasing
---@field id? integer a fixed PersistentId
---@field w? number panels: width in screen units
---@field h? number panels: height

---@class UIMotion
---@field transition? number seconds
---@field easing? UIEasing

---@class UIElement
---@field id integer
---@field opts UIOptions
---@field set fun(self: UIElement, changes: UIOptions, motion?: UIMotion): UIElement
---@field move fun(self: UIElement, x: number, y: number, seconds?: number, easing?: UIEasing): UIElement
---@field remove fun(self: UIElement)
---@field show_to fun(self: UIElement, ps: UObject)

---@alias UITarget UObject|UObject[]|"all"

---@class BrickSelf
---@field brick BrickHandle
---@field id integer the brick's persistent id in the world
---@field behavior string
---@field state table saved by save(), back after a restart
---@field save fun(self: BrickSelf)
---@field every fun(self: BrickSelf, seconds: number, fn: fun(self: BrickSelf): boolean?, opts?: { now?: boolean }): fun()
---@field after fun(self: BrickSelf, seconds: number, fn: fun(self: BrickSelf)): fun()
---@field forget fun(self: BrickSelf) drop its saved state

---@class BehaviorSpec
---@field assets? (BR.BrickAsset|string)[]
---@field match? fun(handle: BrickHandle, asset: string?): boolean
---@field appear? fun(self: BrickSelf, how: "existing"|"placed")
---@field remove? fun(self: BrickSelf)
---@field interact? fun(self: BrickSelf, player: UObject, info: table)
---@field hit? fun(self: BrickSelf, player: UObject, info: table)
---@field keep_state? boolean

---@class BRBehavior
---@field interval number seconds between reads of the world grid
---@field define fun(name: string, spec: BehaviorSpec): fun() returns a function that removes it
---@field bricks fun(name: string): BrickSelf[]
---@field of fun(name: string, handle: BrickHandle): BrickSelf?

---@class InventoryThing
---@field brick? BR.BrickAsset|string
---@field size? integer[] procedural bricks: half extents
---@field entity? BR.EntityClass|string
---@field prefab? string a cached prefab's hash, 64 hex digits
---@field preserve_ownership? boolean
---@field item? BR.Item|string|UObject
---@field count? integer

---@class CachedPrefab
---@field hash string
---@field bricks integer
---@field entities integer
---@field components integer
---@field wires integer
---@field size integer[]

---@class BRPrefab
---@field info fun(hash: string): CachedPrefab?
---@field placeable fun(hash: string): string
---@field set_slot fun(ps: UObject, slot: integer, what: InventoryThing)
---@field set_template fun(ps: UObject, what: InventoryThing)
---@field clear_template fun(ps: UObject)
---@field copy fun(ps: UObject, center: integer[], size: integer[], grid?: UObject)
---@field save fun(path: string, center: integer[], extent: integer[], opts?: { entities?: boolean })
---@field give fun(ps: UObject, path: string, preserve_ownership?: boolean)
---@field cached fun(): CachedPrefab[]
---@field template fun(what: InventoryThing): Bytes

---@class BRSound
---@field play fun(target: UObject|UObject[]|"all", sound: BR.Sound|string|UObject, opts?: { volume?: number, pitch?: number, start?: number })
---@field at fun(position: number[], sound: BR.Sound|string|UObject, opts?: { volume?: number, pitch?: number, start?: number })
---@field list fun(): string[]

---@class BRChat
---@field limit fun(opts?: { messages: integer?, per: number?, mute: number?, message: string? }): fun()
---@field censor fun(words: string[], opts?: { replace: string?, block: boolean? }): fun()
---@field route fun(fn: fun(player: UObject, message: string): (UObject[]|nil)): fun()
---@field send fun(to: UObject|UObject[]|"all", from: UObject, text: string, opts?: { raw?: boolean })
---@field format fun(text: string): string

---@class EffectSelf
---@field name string
---@field player UObject
---@field character UObject
---@field stacks integer
---@field strength number
---@field expires number? BR.timer.now() time
---@field data table

---@class EffectSpec
---@field apply? fun(self: EffectSelf)
---@field tick? fun(self: EffectSelf, seconds: number)
---@field remove? fun(self: EffectSelf)
---@field restack? fun(self: EffectSelf)
---@field interval? number
---@field stack? "refresh"|"add"|"max"
---@field max_stacks? integer

---@class BREffect
---@field define fun(name: string, spec: EffectSpec)
---@field apply fun(ps: UObject, name: string, opts?: { duration?: number, strength?: number, stacks?: integer }): EffectSelf?
---@field remove fun(ps: UObject, name?: string)
---@field of fun(ps: UObject): table<string, EffectSelf>

---@class BRState
---@field set fun(key: string, value: any, opts?: { persist?: boolean })
---@field get fun(key: string): any
---@field all fun(): table<string, any>
---@field watch fun(key: string, fn: fun(value: any, old: any, key: string), opts?: { now?: boolean }): fun()
---@field bind_ui fun(key: string, element: UIElement, render: fun(value: any): UIOptions, motion?: UIMotion): fun()

---@alias MetricLabels table<string, string|number|boolean>

---@class BRMetrics
---@field counter fun(name: string, opts?: { help?: string, labels?: string[] }): { inc: fun(n?: number, labels?: MetricLabels), reset: fun() }
---@field gauge fun(name: string, opts?: { help?: string, labels?: string[] }): { set: fun(v: number, labels?: MetricLabels), inc: fun(n?: number, labels?: MetricLabels), dec: fun(n?: number, labels?: MetricLabels), reset: fun() }
---@field histogram fun(name: string, opts?: { help?: string, labels?: string[], buckets?: number[] }): { observe: fun(v: number, labels?: MetricLabels), reset: fun() }

---@class BRUi
---@field LIMIT integer the most display texts a client holds (32)
---@field count fun(ps: UObject): integer
---@field sources fun(id: integer, opts?: { refresh: boolean? }): { brick: BrickHandle, owner: BrickOwner? }[]
---@field texts fun(ps: UObject, opts?: { sources: boolean? }): { id: integer, expires: integer|false, from: "BR.ui"|"world", sources: table[]? }[]
---@field ANCHOR table<UIAnchor, number[]>
---@field EASING table<UIEasing, integer>
---@field ALIGN table<string, integer>
---@field TYPEFACE table<string, integer>
---@field text fun(target: UITarget, opts: UIOptions): UIElement
---@field panel fun(target: UITarget, opts: UIOptions): UIElement
---@field remove fun(target: UITarget, id: integer)
---@field DIALOG table<"ok"|"yes_no"|"ok_cancel"|"text", integer>
---@field ask fun(ps: UObject, opts: { title?: string, message?: string, kind?: "ok"|"yes_no"|"ok_cancel"|"text", timeout?: number, from?: integer }, fn: fun(accepted: boolean?, text: string)): integer

---The game's names, listed live; `npm run enums` writes them to types/enums.lua
---@class BREnums
---@field KINDS { kind: BREnumKind, alias: string, doc: string, list: fun(): string[] }[]
---@field list fun(kind: BREnumKind): string[]
---@field all fun(): table<BREnumKind, string[]>
---@field render fun(build?: string): string the LuaLS alias file
---@field write fun(path: string, build?: string): integer names written

---@class BRServer
---@field world fun(): string?
---@field stats fun(): { players: integer, bots: integer, bricks: integer, grids: integer, tick_rate: number?, slowest_frame_ms: number?, uptime: number, lua_kb: number }
---@field chat fun(message: string)
---@field console fun(command: string)
---@field log_tail fun(n: integer, pattern?: string): string[]
---@field roles fun(): string[]
---@field build fun(): string? the game build, "Release-EA3-CL-16507"
---@field watchdog fun(ms?: integer): integer the callback time budget; returns the previous one

---@class BRBrick
---@field owner fun(handle: BrickHandle): BrickOwner?
---@field owner_info fun(index: integer): BrickOwner?
---@field in_sphere fun(center: number[], radius: number, opts?: { grid?: UObject, max?: integer }): BrickHandle[]
---@field in_box fun(min: integer[], max: integer[], opts?: { grid?: UObject, max?: integer }): BrickHandle[]
---@field Z_UP integer
---@field MATERIAL table<BrickMaterial, integer>
---@field ALL_COLLISION integer
---@field COLLISION table<"Player"|"Player1"|"Player2"|"Player3"|"Weapon"|"Interaction"|"Physics", integer> EBrickCollisionChannels bits
---@field transform fun(t: BrickTransform): Bytes FTransform bytes for entity transactions
---@field asset fun(name: BR.BrickAsset|string): UObject
---@field builder fun(opts?: BuilderOptions): Builder
---@field place fun(builder: Builder, x: number, y: number, z: number, orientation?: integer): BrickHandle?
---@field valid fun(handle: BrickHandle): boolean
---@field info fun(handle: BrickHandle): BrickInfo
---@field id fun(handle: BrickHandle): BrickId
---@field visible fun(handle: BrickHandle): boolean
---@field count fun(grid?: UObject): integer
---@field in_grid fun(grid?: UObject): BrickHandle[]
---@field transaction fun(player: UObject, record: fun(tx: Transaction)): TransactionReport
---@field changes fun(report: TransactionReport): table<string, integer|string[]> the non-zero counters, and lines if any
---@field trigger fun(x: number, y: number, z: number): Trigger
---@field grid fun(handle: BrickHandle): UObject?

---@class BRComponent
---@field types fun(): UObject[]
---@field type fun(name: BR.ComponentType|string): UObject
---@field ports fun(componentType: string): PortList
---@field port_name fun(port: PortRef): string
---@field input_port fun(componentType: string, port: string): PortRef
---@field output_port fun(componentType: string, port: string): PortRef
---@field set_input fun(handle: BrickHandle, componentType: string, port: string, value: WireValue): TransactionReport
---@field input_is fun(handle: BrickHandle, componentType: string, port: string, value: WireValue): boolean
---@field struct fun(componentType: ComponentType): UObject
---@field fields fun(componentType: ComponentType): ComponentField[]
---@field set fun(handle: BrickHandle, componentType: ComponentType, values: table<string, any>)
---@field get fun(handle: BrickHandle, componentType: ComponentType, path: string): any
---@field data fun(handle: BrickHandle, componentType: ComponentType): table<string, any>?
---@field handle fun(handle: BrickHandle, componentType: ComponentType): Bytes? 8-byte BCSComponentHandle
---@field address fun(handle: BrickHandle, componentType: ComponentType): integer?

---@class BRWire
---@field bool fun(value: boolean): WireValue
---@field int fun(value: integer): WireValue
---@field double fun(value: number): WireValue
---@field string fun(text: string): WireValue
---@field wirestring fun(text: string): WireString
---@field read fun(address: integer): any

---@class BRVar
---@field read_array fun(handle: BrickHandle): any[], string
---@field write_array fun(handle: BrickHandle, values: any[])
---@field read_map fun(handle: BrickHandle): any[][], string, string
---@field set_map_value fun(handle: BrickHandle, key: any, value: any): boolean
---@field on_change fun(target: BrickHandle|BrickHandle[]|UObject, fn: fun(value: any, handle: BrickHandle)): (fun()), integer
---@field on_array_change fun(target: BrickHandle|BrickHandle[]|UObject, fn: fun(elements: any[], handle: BrickHandle)): (fun()), integer
---@field on_map_change fun(target: BrickHandle|BrickHandle[]|UObject, fn: fun(entries: any[][], handle: BrickHandle)): (fun()), integer

---@class BREvent
---@field on_ready fun(fn: fun()): fun()
---@field on_unload fun(fn: fun()): fun()
---@field custom fun(name: string, opts?: CustomEventOptions): CustomEvent
---@field on_custom fun(name: string, fn: fun(data: any[], info: CustomEventInfo), opts?: CustomEventListenOptions): fun()
---@field on_any_custom fun(fn: fun(data: any[], info: CustomEventInfo)): fun()
---@field hook fun(path: string, fn: fun(self: UObject, params: Bytes): (false|Bytes|nil)) return false to stop the call, or bytes to write over the parameters
---@field after fun(path: string, fn: fun(self: UObject, params: string): string?): fun()
---@field result fun(path: string, params: string, bytes: string): string
---@field interact fun(fn: fun(character: UObject, brick: BrickHandle, nearby: boolean)): fun()
---@field interact_end fun(fn: fun(character: UObject)): fun()
---@field avatar_change fun(fn: fun(player: UObject?, manager: UObject): false?): fun() return false to refuse the save
---@field on_sprint fun(fn: fun(player: UObject, active: boolean, character: UObject?)): fun()
---@field on_walk fun(fn: fun(player: UObject, active: boolean, character: UObject?)): fun()
---@field on_crouch fun(fn: fun(player: UObject, active: boolean, character: UObject?)): fun()
---@field on_sit fun(fn: fun(player: UObject, active: boolean, character: UObject?)): fun()
---@field on_spawn fun(fn: fun(player: UObject, character: UObject)): fun()
---@field delegate fun(owner: UObject, name: string, fn: fun(params: Bytes, layout: table)): fun()
---@field on_water fun(fn: fun(player: UObject, active: boolean, character: UObject?)): fun()
---@field on_zone fun(zone: BrickHandle, fn: fun(player: UObject, active: boolean, character: UObject?)): fun()
---@field on fun(event: PlayerEvent, fn: fun(player: UObject?, info: table<string, any>): (false|string|nil)): fun() return false to refuse a request event; a string replaces a chat message
---@field EVENTS PlayerEvent[]
---@field tick fun(fn: fun(deltaSeconds: number)): fun()

---@class BRPlayer
---@field launch fun(ch: UObject, velocity: number[], opts?: { replace_xy?: boolean, replace_z?: boolean })
---@field set_can_respawn fun(ps: UObject, can: boolean)
---@field can_respawn fun(ps: UObject): boolean
---@field set_checkpoint fun(ps: UObject, brick?: BrickHandle)
---@field checkpoint fun(ps: UObject): BrickHandle?
---@field set_spectator fun(ps: UObject, on: boolean)
---@field spectator fun(ps: UObject): boolean
---@field server fun(): UObject
---@field owner_index fun(): integer
---@field of fun(obj?: UObject): UObject?
---@field list fun(): UObject[]
---@field find fun(name: string): UObject?
---@field id fun(ps: UObject): string account id (8-4-4-4-12 hex); all zeros for a bot
---@field info fun(ps: UObject): PlayerInfo
---@field controller fun(ps: UObject): UObject?
---@field character fun(ps: UObject): UObject?
---@field connected fun(ps: UObject): boolean
---@field team fun(ps: UObject): UObject?
---@field health fun(character: UObject): number, number
---@field set_health fun(character: UObject, hp: number, max?: number)
---@field kill fun(character: UObject)
---@field movement fun(character: UObject): Movement
---@field sitting fun(character: UObject): boolean
---@field crouching fun(character: UObject): boolean
---@field sprinting fun(character: UObject): boolean
---@field walking fun(character: UObject): boolean
---@field in_water fun(character: UObject): boolean
---@field in_zone fun(character: UObject, zone: BrickHandle): boolean
---@field respawn fun(ps: UObject)
---@field item_class fun(name: BR.Item|string): UObject?
---@field inventory fun(character: UObject): InventorySlot[]
---@field give fun(ps: UObject, slot: integer, item: BR.Item|string|UObject, count?: integer)
---@field clear_slot fun(ps: UObject, slot: integer)
---@field input fun(ch: UObject): { keys: table<string, boolean>, move: number[] } the weapon keys held and the movement direction
---@field tune fun(ch: UObject, slot: integer, opts: { damage?: number, speed?: number, scale?: number, projectile_scale?: number, projectile?: string|UObject, name?: string, colors?: integer[][] }): UObject?
---@field whisper fun(ps: UObject, message: string)
---@field status fun(ps: UObject, message: string, flash?: boolean, keep?: boolean)
---@field set_view fun(ps: UObject, yaw: number, pitch?: number)
---@field spectate_target fun(ps: UObject, actor: UObject)
---@field error_dialog fun(ps: UObject, title: string, message: string)
---@field message_box fun(ps: UObject, title: string, message: string)
---@field hint fun(ps: UObject, title: string, text: string, opts?: { where: "game"|"pause"|"both"? })
---@field ping fun(ps: UObject): number
---@field fade fun(ps: UObject, from: number, to: number, seconds?: number, color?: integer[], opts?: { hold: boolean?, audio: boolean? })
---@field view_from fun(ps: UObject, actor: UObject, opts?: { blend: number? })
---@field view_reset fun(ps: UObject, opts?: { blend: number? })
---@field online_for fun(ps: UObject): number
---@field joined_at fun(ps: UObject): integer?
---@field display_text fun(ps: UObject, params: DisplayTextParams)
---@field remove_text fun(ps: UObject, id: integer)

---@class TeamOptions
---@field name? string
---@field color? integer[] {r, g, b}
---@field friendly_damage? boolean
---@field respawn_time? number seconds
---@field invincibility? number seconds after respawning
---@field max_item_slots? integer
---@field spectator? boolean force spectator mode

---@class BRTeam
---@field find fun(name: string): UObject?
---@field players fun(team: UObject): UObject[]
---@field create fun(name: string, opts?: TeamOptions): UObject the team named `name`, created if missing
---@field configure fun(team: UObject, opts: TeamOptions)
---@field delete fun(team: string|UObject) members become unaffiliated
---@field rule fun(team: UObject, kind: BR.TeamRule|string, create?: boolean): UObject?
---@field rules fun(team: UObject): { kind: string, rule: UObject }[]
---@field remove_rule fun(team: UObject, rule: string|UObject)
---@field rule_kinds fun(): string[]
---@field list fun(): UObject[]
---@field info fun(team: UObject): TeamInfo
---@field join fun(ps: UObject, id: integer, respawn?: boolean)

---@class BRLeaderboard
---@field get fun(target: UObject, name: string): number
---@field set fun(target: UObject, name: string, value: number)
---@field add fun(target: UObject, name: string, delta: number)

---A zone's box in its grid's coordinates (world coordinates on the global grid)
---@class ZoneBox
---@field center number[] {x, y, z}
---@field half number[] half extents {x, y, z}
---@field grid UObject the grid actor

---@class BRZone
---@field COMPONENT string
---@field is_zone fun(handle: BrickHandle): boolean
---@field list fun(grid?: UObject): BrickHandle[]
---@field box fun(handle: BrickHandle): ZoneBox?
---@field contains fun(handle: BrickHandle, character: UObject, box?: ZoneBox): boolean
---@field occupants fun(handle: BrickHandle): UObject[]

---@class BREntity
---@field tag fun(e: UObject): string?
---@field set_tag fun(e: UObject, text: string)
---@field properties fun(e: UObject): table<string, any> custom properties, { [key] = value }
---@field property fun(e: UObject, key: string): any
---@field set_properties fun(e: UObject, props: table<string, boolean|number|string>)
---@field set_property fun(e: UObject, key: string, value: boolean|number|string|nil)
---@field find fun(tag?: string): UObject[]
---@field list fun(): UObject[]
---@field spawn fun(class: BR.EntityClass|string|UObject, x: number, y: number, z: number, opts?: SpawnEntityOptions): UObject
---@field id fun(entity: UObject): integer its transaction id
---@field by_id fun(id: integer): UObject?
---@field class fun(class: BR.EntityClass|string|UObject): UObject
---@field color fun(entity: UObject, slot: integer, r: number, g: number, b: number, a?: number): boolean
---@field frozen fun(entity: UObject): boolean
---@field set_frozen fun(entity: UObject, frozen: boolean): boolean
---@field freeze fun(entity: UObject): boolean
---@field unfreeze fun(entity: UObject): boolean
---@field gravity fun(entity: UObject): boolean physics entities and dynamic grids
---@field set_gravity fun(entity: UObject, enabled: boolean)
---@field gravity_direction fun(target: UObject): Vec3 a PlayerState or character
---@field set_gravity_direction fun(target: UObject, dir: Vec3)
---@field visible fun(entity: UObject): boolean
---@field set_visible fun(entity: UObject, visible: boolean): boolean
---@field owner fun(entity: UObject): integer
---@field delete fun(entity: UObject): boolean
---@field attach fun(entity: UObject, target: UObject, opts?: { socket?: string, offset?: Vec3 }) on the character's mesh; target: a PlayerState or a character
---@field detach fun(entity: UObject, opts?: { unfreeze?: boolean })
---@field attached_to fun(entity: UObject): UObject?

---@class BRNpc
---@field on_spawn fun(fn: fun(npc: UObject)): fun()
---@field on_death fun(fn: fun(npc: UObject, info: table)): fun()
---@field list fun(): UObject[]

---@class BRNav
---@field CHARACTER { radius: number, height: number, step: number, jump: number, drop: number }
---@field find fun(from: Vec3, to: Vec3, done: fun(path: NavPoint[]?), opts?: NavFindOptions): fun() returns a cancel function
---@field clear fun(from: Vec3, to: Vec3): boolean a straight walk with nothing in the way
---@field bake fun(seed: Vec3, opts?: { radius?: number, cell?: integer, done?: fun(count: integer) }): fun() place node gates over the reachable area; returns a cancel function
---@field unbake fun(center?: Vec3, radius?: number): integer remove node gates (all, without a center)
---@field graph fun(reload?: boolean): { nodes: table[], by_cell: table, cell: integer }
---@field route fun(from: Vec3, to: Vec3): NavPoint[]? Dijkstra over the baked graph, with the costs the gates hold now
---@field GRAPH_DIRECTIONS integer[][] the direction of each edge-cost element, in order

---@class BRBot
---@field patrol fun(ps: UObject, points: number[][], opts?: { wait: number?, pathfind: boolean?, radius: number? }): fun()
---@field follow fun(ps: UObject, target: UObject, opts?: { distance: number?, every: number? }): fun()
---@field spawn fun(name: string, opts?: BotSpawnOptions): UObject the bot's PlayerState
---@field is_bot fun(ps: UObject): boolean
---@field list fun(): UObject[]
---@field remove fun(ps: UObject) gone on the next tick
---@field move fun(ps: UObject, x: number, y: number) walk in world direction (x, y); (0, 0) stops
---@field move_to fun(ps: UObject, target: Vec3, opts?: MoveToOptions) walk straight there; walls are not avoided
---@field path_to fun(ps: UObject, target: Vec3, opts?: PathToOptions) walk there along a BR.nav path
---@field stop fun(ps: UObject)
---@field moving fun(ps: UObject): boolean
---@field look fun(ps: UObject, yaw?: number, pitch?: number) degrees; no angles: face the walking direction again
---@field look_at fun(ps: UObject, point: Vec3)
---@field jump fun(ps: UObject)
---@field crouch fun(ps: UObject, on: boolean)
---@field sprint fun(ps: UObject, on: boolean)
---@field fly fun(ps: UObject, on: boolean)
---@field give fun(ps: UObject, weapon: BR.Item|string): integer? the slot it went to
---@field equip fun(ps: UObject, slot: integer)
---@field fire fun(ps: UObject, on: boolean) hold or release the trigger
---@field reload fun(ps: UObject)
---@field weapon fun(ps: UObject): UObject? the weapon in hand
---@field drive fun() restart the bot driver after a BR_RELOAD

---Every action takes the player's PlayerState; tool actions return the
---transaction report, all zeros when the game refused.
---@class BRAct
---@field place_prefab fun(ps: UObject, opts: { prefab: string, position: integer[], orientation: integer?, count: integer[]?, spacing: integer[]?, preserve_ownership: boolean? }): table
---@field EMOTE BREmote
---@field place fun(ps: UObject, opts: PlaceOptions): TransactionReport
---@field hammer fun(ps: UObject, brick: BrickHandle): TransactionReport
---@field paint fun(ps: UObject, brick: BrickHandle, opts: PaintOptions): TransactionReport
---@field set_visible fun(ps: UObject, brick: BrickHandle, visible: boolean): TransactionReport
---@field set_collision fun(ps: UObject, brick: BrickHandle, channels: integer): TransactionReport
---@field wire fun(ps: UObject, from: WirePort, to: WirePort): TransactionReport connects, or disconnects an existing wire
---@field emote fun(ps: UObject, emote: BREmote)
---@field stop_emote fun(ps: UObject)
---@field say fun(ps: UObject, message: string)
---@field interact fun(ps: UObject, brick: BrickHandle, nearby?: boolean)
---@field stop_interact fun(ps: UObject)

---@class BRVoice
---@field FRAME_SECONDS number 0.02: one Opus frame
---@field ogg_frames fun(path: string): Bytes[] the Opus frames of an Ogg Opus file
---@field say fun(ps: UObject, frames: Bytes[], opts?: { done?: fun(ps: UObject) }): fun() returns a stop function
---@field play fun(ps: UObject, path: string, opts?: { done?: fun(ps: UObject) }): fun()
---@field capture fun(fn: fun(ps: UObject, frame: Bytes, position: integer, burst: integer)): fun() every frame anyone says; returns a stop function
---@field recorder fun(opts?: { seconds?: number }): fun() keep each player's last seconds of speech; returns a stop function
---@field recorded fun(): { key: integer, name: string?, id: string?, seconds: number }[]
---@field clip fun(who: UObject|integer, path: string, opts?: { seconds?: number }): number? write a player's recording as Ogg Opus; seconds written
---@field write_ogg fun(path: string, frames: Bytes[])

---@class PermissionDefinition
---@field default? boolean
---@field roles? string[]
---@field description? string

---@class BRPerm
---@field GAME_PREFIX string
---@field has fun(ps: UObject, name: BR.Permission|string): boolean
---@field set fun(ps: UObject, name: BR.Permission|string, state: boolean?)
---@field get fun(ps: UObject, name: string): boolean?
---@field clear fun(ps: UObject)
---@field define fun(name: string, opts?: PermissionDefinition)
---@field defined fun(): table<string, PermissionDefinition>
---@field set_role fun(role: string, name: string, state: boolean?)
---@field game_tags fun(): string[]
---@field trace fun(fn: fun(player: UObject, tag: string, allowed: boolean)): fun()

---@class BRStoreHandle
---@field data table
---@field version number? the version opened with
---@field save fun()
---@field get fun(key: string): any
---@field set fun(key: string, value: any)
---@field pending boolean? from view(), before the stores arrived: empty, and save is an error

---@class BRStore
---@field ready fun(): boolean
---@field on_ready fun(fn: fun())
---@field load fun(name: string): table
---@field save fun(name: string, value: table)
---@field delete fun(name: string)
---@field open fun(name: string, opts?: StoreOptions): BRStoreHandle
---@field view fun(name: string, opts?: StoreOptions): BRStoreHandle
---@field for_world fun(name: string, opts?: StoreOptions): BRStoreHandle

---@class TimerOptions
---@field owner? UObject|BrickHandle end the timer once this is gone
---@field now? boolean every: also run at once

---@class BRTimer
---@field after fun(seconds: number, fn: fun(), opts?: TimerOptions): fun()
---@field every fun(seconds: number, fn: fun(): false?, opts?: TimerOptions): fun()
---@field next_tick fun(fn: fun(), opts?: TimerOptions): fun()
---@field now fun(): number
---@field cron fun(expr: string, fn: fun(): false?, opts?: ScheduleOptions): fun()
---@field at fun(clock: string, fn: fun(): false?, opts?: ScheduleOptions): fun()
---@field cron_matches fun(expr: string, t?: osdate): boolean
---@field async fun(fn: fun(), opts?: TimerOptions): fun()
---@field sleep fun(seconds: number)

---@class ScheduleOptions
---@field owner? UObject|BrickHandle end the schedule once this is gone
---@field utc? boolean use UTC rather than the server's local time

---@class StoreOptions
---@field version? number the layout's version
---@field migrate? table<integer, fun(data: table): table?> steps to each version

---@class CommandContext
---@field name string
---@field raw string the text after the name
---@field reply fun(text: string)

---@class CommandOptions
---@field permission? string
---@field aliases? string[]
---@field description? string
---@field usage? string

---@class CommandInfo
---@field name string
---@field aliases string[]
---@field description? string
---@field usage? string
---@field permission? string

---@class BRCommand
---@field register fun(name: string, fn: fun(player: UObject, args: string[], ctx: CommandContext), opts?: CommandOptions): fun()
---@field list fun(player?: UObject): CommandInfo[]
---@field builtin fun(name: string): boolean
---@field split fun(text: string): string[]

---@class BanOptions
---@field duration? number seconds
---@field reason? string
---@field by? UObject

---@class BanInfo
---@field reason string
---@field by string
---@field created number|string
---@field expires number|string

---@class BRMod
---@field kick fun(ps: UObject, reason?: string, by?: UObject): boolean
---@field ban fun(who: UObject|string, opts?: BanOptions)
---@field unban fun(who: UObject|string)
---@field banned fun(who: UObject|string): BanInfo?
---@field bans fun(): table<string, BanInfo>
---@field on_join fun(fn: fun(player: UObject): (false|string|nil)): fun()
---@field guid fun(id: string): { A: integer, B: integer, C: integer, D: integer }

---@class BRVec
---@field x number
---@field y number
---@field z number
---@operator add(BRVec): BRVec
---@operator sub(BRVec): BRVec
---@operator unm: BRVec
---@operator mul(number|BRVec): BRVec
---@operator div(number|BRVec): BRVec
---@field dot fun(self: BRVec, b: BRVec|number[]): number
---@field cross fun(self: BRVec, b: BRVec|number[]): BRVec
---@field length fun(self: BRVec): number
---@field length_squared fun(self: BRVec): number
---@field length_2d fun(self: BRVec): number
---@field distance fun(self: BRVec, b: BRVec|number[]): number
---@field distance_squared fun(self: BRVec, b: BRVec|number[]): number
---@field normalized fun(self: BRVec): BRVec
---@field is_zero fun(self: BRVec, tolerance?: number): boolean
---@field near fun(self: BRVec, b: BRVec|number[], tolerance?: number): boolean
---@field lerp fun(self: BRVec, b: BRVec|number[], t: number): BRVec
---@field angle_to fun(self: BRVec, b: BRVec|number[]): number degrees
---@field project_on fun(self: BRVec, dir: BRVec|number[]): BRVec
---@field project_on_plane fun(self: BRVec, normal: BRVec|number[]): BRVec
---@field reflect fun(self: BRVec, normal: BRVec|number[]): BRVec
---@field rotator fun(self: BRVec): BRRot
---@field quat fun(self: BRVec): BRQuat
---@field ue fun(self: BRVec): { X: number, Y: number, Z: number }
---@field array fun(self: BRVec): number[]
---@field unpack fun(self: BRVec): number, number, number

---@class BRQuat
---@field x number
---@field y number
---@field z number
---@field w number
---@operator mul(BRQuat): BRQuat
---@operator unm: BRQuat
---@field dot fun(self: BRQuat, b: BRQuat): number
---@field length fun(self: BRQuat): number
---@field normalized fun(self: BRQuat): BRQuat
---@field inverse fun(self: BRQuat): BRQuat
---@field rotate fun(self: BRQuat, v: BRVec|number[]): BRVec
---@field unrotate fun(self: BRQuat, v: BRVec|number[]): BRVec
---@field forward fun(self: BRQuat): BRVec
---@field right fun(self: BRQuat): BRVec
---@field up fun(self: BRQuat): BRVec
---@field angle fun(self: BRQuat): number degrees
---@field axis fun(self: BRQuat): BRVec
---@field axis_angle fun(self: BRQuat): BRVec, number
---@field angle_to fun(self: BRQuat, b: BRQuat): number degrees
---@field slerp fun(self: BRQuat, b: BRQuat, t: number): BRQuat
---@field rotator fun(self: BRQuat): BRRot
---@field euler fun(self: BRQuat): BRVec (Roll, Pitch, Yaw) degrees
---@field ue fun(self: BRQuat): { X: number, Y: number, Z: number, W: number }
---@field array fun(self: BRQuat): number[]
---@field unpack fun(self: BRQuat): number, number, number, number

---@class BRRot
---@field Pitch number
---@field Yaw number
---@field Roll number
---@operator add(BRRot): BRRot
---@operator sub(BRRot): BRRot
---@operator unm: BRRot
---@operator mul(number): BRRot
---@field quat fun(self: BRRot): BRQuat
---@field forward fun(self: BRRot): BRVec
---@field right fun(self: BRRot): BRVec
---@field up fun(self: BRRot): BRVec
---@field normalized fun(self: BRRot): BRRot
---@field angle_to fun(self: BRRot, b: BRRot): number degrees
---@field slerp fun(self: BRRot, b: BRRot, t: number): BRRot
---@field rotate fun(self: BRRot, v: BRVec|number[]): BRVec
---@field unrotate fun(self: BRRot, v: BRVec|number[]): BRVec
---@field euler fun(self: BRRot): BRVec
---@field ue fun(self: BRRot): { Pitch: number, Yaw: number, Roll: number }
---@field array fun(self: BRRot): number[]
---@field unpack fun(self: BRRot): number, number, number

---@class BRMath
---@field vec fun(x?: number|table, y?: number, z?: number): BRVec
---@field quat fun(x?: number|table, y?: number, z?: number, w?: number): BRQuat
---@field rot fun(pitch?: number|table, yaw?: number, roll?: number): BRRot
---@field quat_euler fun(roll: number|BRVec|number[], pitch?: number, yaw?: number): BRQuat
---@field quat_axis_angle fun(axis: BRVec|number[], degrees: number): BRQuat
---@field quat_between fun(a: BRVec|number[], b: BRVec|number[]): BRQuat
---@field quat_look fun(forward: BRVec|number[], up?: BRVec|number[]): BRQuat
---@field quat_from_axes fun(x: BRVec|number[], y: BRVec|number[], z: BRVec|number[]): BRQuat
---@field transform fun(location?: BRVec|number[], rotation?: BRQuat|BRRot, scale?: number|BRVec|number[]): table
---@field rad fun(deg: number): number
---@field deg fun(rad: number): number
---@field normalize_angle fun(a: number): number (-180, 180]
---@field clamp_angle fun(a: number): number [0, 360)
---@field delta_angle fun(a: number, b: number): number
---@field lerp_angle fun(a: number, b: number, t: number): number
---@field lerp fun(a: number, b: number, t: number): number
---@field clamp fun(v: number, lo: number, hi: number): number
---@field ZERO BRVec
---@field FORWARD BRVec
---@field RIGHT BRVec
---@field UP BRVec
---@field IDENTITY BRQuat
---@field D2R number
---@field R2D number

---@class BRModule
---@field math BRMath
---@field raw BRRaw
---@field world BRWorld
---@field server BRServer
---@field brick BRBrick
---@field component BRComponent
---@field wire BRWire
---@field var BRVar
---@field event BREvent
---@field player BRPlayer
---@field team BRTeam
---@field leaderboard BRLeaderboard
---@field entity BREntity
---@field zone BRZone
---@field npc BRNpc
---@field nav BRNav
---@field bot BRBot
---@field act BRAct
---@field voice BRVoice
---@field perm BRPerm
---@field store BRStore
---@field timer BRTimer
---@field command BRCommand
---@field mod BRMod
---@field enums BREnums
---@field ui BRUi
---@field behavior BRBehavior
---@field prefab BRPrefab
---@field sound BRSound
---@field chat BRChat
---@field effect BREffect
---@field state BRState
---@field metrics BRMetrics
---@field pickup BRPickup
---@field gen BRGen
---@field guard BRGuard
---@field secrets BRSecrets
---@field db BRDb
---@field region BRRegion
---@field target BRTarget
---@field afk BRAfk
---@field profile BRProfile
---@field watch BRWatch
---@field env BREnv
---@field config BRConfig
---@field label BRLabel
---@field mover BRMover

---@class HttpRequest
---@field method string
---@field path string below /api/v1/plugin/ue4ss, starting with /
---@field query table<string, string|string[]>
---@field headers table<string, string> lowercase names
---@field body any parsed JSON, the text of a text or form body, or nil
---@field user { id: string, username: string }? the web UI user, nil when nobody is logged in
---@field ip string

---@class RouteOptions
---@field public boolean? reachable without a web UI login

---@class PickupOptions
---@field respawn number? seconds until it comes back after being taken; 0 never
---@field once boolean? removed once taken (drop's default)
---@field multi boolean? a player may take several
---@field damage number?
---@field speed number?
---@field name string?
---@field projectile string|UClass?
---@field projectile_scale number?
---@field colors number[][]?
---@field position number[]? drop only: where to leave it

---@class BRPickup
---@field class fun(what: string|UClass): UClass?
---@field spawn fun(what: string|UClass, position: number[], opts?: PickupOptions): UObject
---@field drop fun(ps: UObject, slot: integer, opts?: PickupOptions): UObject?
---@field gate fun(fn: fun(player: UObject, pickup: UObject): boolean?): fun()
---@field on fun(fn: fun(player: UObject, pickup: UObject, item: string?)): fun()
---@field list fun(): UObject[]

---@class BRRng
---@field next fun(self: BRRng): integer a 32-bit integer
---@field float fun(self: BRRng): number in [0, 1)
---@field int fun(self: BRRng, a: integer, b: integer): integer
---@field chance fun(self: BRRng, p: number): boolean
---@field pick fun(self: BRRng, list: any[]): any
---@field shuffle fun(self: BRRng, list: any[]): any[]

---@class GenBuildOptions
---@field seed any?
---@field player UObject? whose transaction; default the server stand-in
---@field material string|integer?
---@field owner integer? brick owner index

---@class BRGen
---@field rng fun(seed?: number|string): BRRng
---@field noise fun(seed?: number|string): fun(x: number, y: number, z?: number): number
---@field fbm fun(noise: fun(x: number, y: number, z?: number): number, x: number, y: number, z?: number, opts?: { octaves: integer?, lacunarity: number?, gain: number? }): number
---@field fits fun(min: integer[], max: integer[], opts?: { grid: UObject? }): boolean
---@field scatter fun(rng: BRRng, min: number[], max: number[], count: integer, opts?: { spacing: number? }): integer[][]
---@field terrain fun(origin: integer[], cells: integer[], opts?: GenBuildOptions|{ cell: integer?, layers: integer?, layer: integer?, scale: number?, octaves: integer?, colors: integer[][]? }): table
---@field maze_grid fun(cells: integer[], rng: BRRng): boolean[][]
---@field maze fun(origin: integer[], cells: integer[], opts?: GenBuildOptions|{ block: integer?, height: integer?, color: integer[]? }): table, boolean[][]

---@alias GuardKind "speed"|"teleport"|"fly"|"build_rate"

---@class GuardOptions
---@field bots boolean? include bots
---@field tolerance number? speed: times the character's top speed (1.25)
---@field sustain integer? speed: polls in a row (3)
---@field slack number? teleport: units beyond what velocity explains (300)
---@field max integer? build_rate: place requests per second (20)

---@class BRGuard
---@field on fun(kind: GuardKind, fn: fun(player: UObject, amount: number, info: table), opts?: GuardOptions): fun()
---@field expect_move fun(actor: UObject)

---@class BRSecrets
---@field get fun(key: string, default?: any): any
---@field require fun(key: string): any
---@field path fun(): string

---@class BRDatabase
---@field name string
---@field exec fun(sql: string, fn?: fun(ok: boolean, err: string?))
---@field run fun(sql: string, params?: any[], fn?: fun(ok: boolean, result: { changes: integer, last_id: integer }|string))
---@field query fun(sql: string, params: any[]?, fn: fun(ok: boolean, rows: table[]|string))

---@class BRDb
---@field open fun(name: string): BRDatabase

---@class RegionBox
---@field min integer[] {x, y, z} grid units
---@field max integer[]

---@class RegionOptions
---@field box RegionBox?
---@field boxes RegionBox[]?
---@field owners (string|UObject)[]? player ids or PlayerStates who may build
---@field build "owners"|"nobody"|"everyone"?
---@field copy boolean? anyone may select (and copy) in it
---@field ban_assets string[]?
---@field ban_components string[]?
---@field message string? what a refused player is told

---@class RegionRefusal
---@field action string place, delete, paint, apply, paste, resize, rotate, select, selection, wire, ...
---@field region string? the region in the way
---@field zone BrickHandle? the zone brick a zone rule refused in
---@field banned string? the banned asset or component
---@field removed integer? bricks taken back out (a prefab)
---@field quiet boolean? set true to stop the default message

---@class RegionZone
---@field brick BrickHandle the zone projector brick
---@field box RegionBox
---@field tag string the zone's tag filter
---@field building boolean its building zone flag

---@class RegionFilter
---@field asset (string|string[])?
---@field component (string|string[])?
---@field owner integer? a brick owner index

---@class BRRegion
---@field define fun(name: string, opts: RegionOptions): table
---@field get fun(name: string): table?
---@field list fun(): table<string, table>
---@field remove fun(name: string)
---@field add_owner fun(name: string, ps: UObject|string)
---@field remove_owner fun(name: string, ps: UObject|string)
---@field at fun(point: integer[]): string[]
---@field set_default fun(rule: "everyone"|"nobody")
---@field ban fun(kind: "assets"|"components", names: string|string[])
---@field unban fun(kind: "assets"|"components", names: string|string[])
---@field allows fun(ps: UObject, box: RegionBox): boolean, (string|{ zone: BrickHandle, message: string? })?
---@field bypass fun(ps: UObject, on?: boolean)
---@field on_refused fun(fn: fun(player: UObject, info: RegionRefusal)): fun()
---@field zone_rule fun(fn: (fun(zone: RegionZone, player: UObject, action: "build"|"select"): boolean?, string?)?)
---@field refresh_zones fun()
---@field bricks fun(name: string, filter?: RegionFilter): BrickHandle[]
---@field clear fun(name: string, filter?: RegionFilter): integer

---@class BrickOwner
---@field index integer
---@field id string account id
---@field name string
---@field display_name string

---@class TargetOptions
---@field bots boolean? include bots
---@field one boolean? exactly one player
---@field immunity boolean? false: ignore target.immune

---@class BRTarget
---@field resolve fun(actor: UObject?, spec: string, opts?: TargetOptions): UObject[]?, string?
---@field one fun(actor: UObject?, spec: string, opts?: TargetOptions): UObject?, string?
---@field selectors fun(): string[]

---@class BRAfk
---@field idle fun(ps: UObject): number seconds since they last did anything
---@field on fun(seconds: number, fn: fun(player: UObject, away: boolean), opts?: { bots: boolean? }): fun()
---@field touch fun(ps: UObject)

---@class ProfileEntry
---@field kind string
---@field source string file:line of the handler
---@field calls integer
---@field total_ms number
---@field avg_ms number
---@field max_ms number

---@class BRProfile
---@field start fun()
---@field stop fun()
---@field running fun(): boolean
---@field reset fun()
---@field report fun(opts?: { limit: integer? }): ProfileEntry[]
---@field measure fun(name: string, fn: function, ...: any): any
---@field sample fun(seconds: number, fn: fun(report: ProfileEntry[]), opts?: { limit: integer? })

---@class BRWatch
---@field removed fun(target: BrickHandle|UObject, fn: fun(target: BrickHandle|UObject)): fun()
---@field count fun(): integer

---@alias EnvGroup "sky"|"ground"|"water"|"ambience"|"space"|"studio"|"terrain"

---@class BREnv
---@field settings fun(group: EnvGroup): string[]
---@field set fun(group: EnvGroup, values: table<string, any>)
---@field get fun(group: EnvGroup, setting: string): any

---@class ModConfig
---@field get fun(key: string): any
---@field all fun(): table
---@field path fun(): string

---@class BRConfig
---@field open fun(name: string, defaults?: table): ModConfig

---@class Label
---@field brick BrickHandle
---@field set fun(self: Label, changes: table)
---@field remove fun(self: Label)

---@class BRLabel
---@field create fun(position: integer[], opts?: { text: string?, billboard: "none"|"full"|"in_plane"?, color: integer[]?, outline: number?, outline_color: integer[]?, scale: number?, offset: number[]?, foreground: boolean? }): Label

---@class Mover
---@field position number[]
---@field stop fun(self: Mover)
---@field pause fun(self: Mover)
---@field resume fun(self: Mover)

---@class BRMover
---@field path fun(entity: UObject, points: number[][], opts?: { speed: number?, mode: "once"|"loop"|"ping_pong"?, wait: number?, rate: number?, on_arrive: fun(index: integer)? }): Mover

---@class OmeggaModule
---@field id string this mod's interop id (each mod is its own Lua state)
---@field plain fun(value: any, depth?: integer): any
---@field emit fun(event: string, data?: any)
---@field call fun(plugin: string, event: string, args?: any[], callback?: fun(ok: boolean, result: any)): string
---@field handle fun(name: string, fn: fun(...: any): any)
---@field on fun(event: string, fn: fun(...: string): any) "cmd:<name>" (a chat command: fn(player_name, ...words)) or "consolecmd:<name>" (a console command), declared in the mod's doc.json
---@field on_connect fun(key: string, fn: fun()) run fn each time a plugin connects; a later call with the same key replaces it
---@field invoke fun(name: string, args?: any[], callback?: fun(ok: boolean, result: any)): string
---@field route fun(method: string, path: string, fn: fun(request: HttpRequest): (string|table|nil), opts?: RouteOptions)
---@field watch fun(name: string, intervalMs: integer, getter: fun(): any)
---@field unwatch fun(name: string)

---@type BRModule
BR = nil
---@type OmeggaModule
Omegga = nil

---Re-reads omegga.brickadia after editing it (bridge exec only).
---@return BRModule
function BR_RELOAD() end

-- native helpers from the BrickadiaBridge C++ mod, in every Lua mod

---@param path string
---@return table<string, any>?
function __fn_layout(path) end
---@param target UObject
---@param path string
---@param bytes Bytes
---@return Bytes
function __raw_call(target, path, bytes) end
---@param obj UObject
---@return integer
function __addr(obj) end
---@param address integer
---@return UObject?
function __obj(address) end
---@param text string
---@return integer
function __fname(text) end
---@param address integer
---@param length integer
---@return Bytes
function __peek(address, length) end
---@param bytes Bytes
---@return integer
function __alloc(bytes) end
---@param address integer
function __free(address) end
---@param bytes Bytes
---@return integer
function __game_alloc(bytes) end
---@param address integer
function __game_free(address) end
---@param address integer
---@param bytes Bytes
function __poke(address, bytes) end
---@param path string
---@param fn fun(self: UObject, params: Bytes)
function __on_call(path, fn) end
---After each call of `path` that ran; params hold the return value and out parameters
---@param path string
---@param fn fun(self: UObject, params: Bytes)
function __on_call_after(path, fn) end
---The callback time budget in ms (0: off); returns the previous one
---@param ms? integer
---@return integer
function __watchdog(ms) end
---@param fn fun(deltaSeconds: number)
function __on_tick(fn) end
---@param handle Bytes
---@return integer?
function __component_data(handle) end
---@param name string
---@param fn fun(conn: integer, line: string)
function __bridge_listen(name, fn) end
---@param conn integer
---@param line string
function __bridge_send(conn, line) end

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
---a component type: its object, or a name for BR.component_type
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
---| "place"
---| "delete"
---| "change"

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

---@class Transaction
---@field set fun(id: BrickId, port: PortRef, value: WireValue)
---@field connect fun(sourceId: BrickId, output: PortRef, targetId: BrickId, input: PortRef)
---@field attach fun(id: BrickId, componentType: UObject)
---@field delete fun(id: BrickId)

---@class BuilderOptions
---@field asset? string
---@field size? number[]
---@field color? Color
---@field grid? UObject
---@field owner? integer
---@field visible? boolean
---@field collision? boolean

---@class CustomEventOptions
---@field at? Vec3
---@field target? UObject send only to this brick grid entity

---@class CustomEventListenOptions
---@field at? Vec3
---@field entity? UObject listen for events sent to this brick grid entity

---@class BrickInfo
---@field valid boolean
---@field asset? string
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
---@field brick BrickHandle
---@field trigger Trigger
---@field send fun(...: WireValue): TransactionReport

---@class PortList
---@field inputs string[]
---@field outputs string[]

---@class SpawnEntityOptions
---@field frozen? boolean
---@field owner? integer

---@class BRModule
---@field ready fun(): boolean
---@field world_context fun(): UObject
---@field global_grid fun(): UObject
---@field game_mode fun(): UObject
---@field Z_UP integer
---@field ALL_COLLISION integer
---@field asset fun(name: string): UObject
---@field builder fun(opts?: BuilderOptions): Builder
---@field place fun(builder: Builder, x: number, y: number, z: number, orientation?: integer): BrickHandle?
---@field brick_valid fun(handle: BrickHandle): boolean
---@field brick_info fun(handle: BrickHandle): BrickInfo
---@field brick_id fun(handle: BrickHandle): BrickId
---@field is_visible fun(handle: BrickHandle): boolean
---@field brick_count fun(grid?: UObject): integer
---@field component_types fun(): UObject[]
---@field component_type fun(name: string): UObject
---@field ports fun(componentType: string): PortList
---@field port_name fun(port: PortRef): string
---@field input_port fun(componentType: string, port: string): PortRef
---@field output_port fun(componentType: string, port: string): PortRef
---@field wire_bool fun(value: boolean): WireValue
---@field wire_int fun(value: integer): WireValue
---@field wire_double fun(value: number): WireValue
---@field wire_string fun(text: string): WireValue
---@field wirestring fun(text: string): WireString
---@field player fun(): UObject
---@field owner_index fun(): integer
---@field transaction fun(player: UObject, record: fun(tx: Transaction)): TransactionReport
---@field changes fun(report: TransactionReport): table<string, any>
---@field set_input fun(handle: BrickHandle, componentType: string, port: string, value: WireValue): TransactionReport
---@field input_is fun(handle: BrickHandle, componentType: string, port: string, value: WireValue): boolean
---@field trigger fun(x: number, y: number, z: number): Trigger
---@field component_struct fun(componentType: ComponentType): UObject
---@field component_fields fun(componentType: ComponentType): ComponentField[]
---@field set_component fun(handle: BrickHandle, componentType: ComponentType, values: table<string, any>)
---@field get_component fun(handle: BrickHandle, componentType: ComponentType, path: string): any
---@field component_data fun(handle: BrickHandle, componentType: ComponentType): table<string, any>?
---@field component_address fun(handle: BrickHandle, componentType: ComponentType): integer?
---@field read_wirevalue fun(address: integer): any
---@field custom_event fun(name: string, opts?: CustomEventOptions): CustomEvent
---@field on_custom_event fun(name: string, fn: fun(data: any[], count: integer), opts?: CustomEventListenOptions): fun()
---@field grids fun(): UObject[]
---@field brick_grid fun(handle: BrickHandle): UObject?
---@field on_call fun(path: string, fn: fun(self: UObject, params: Bytes))
---@field on_interact fun(fn: fun(character: UObject, brick: BrickHandle, nearby: boolean)): fun()
---@field on_interact_end fun(fn: fun(character: UObject)): fun()
---@field on fun(event: PlayerEvent, fn: fun(player: UObject?, info: table<string, any>)): fun()
---@field EVENTS PlayerEvent[]
---@field player_of fun(obj?: UObject): UObject?
---@field on_tick fun(fn: fun(deltaSeconds: number)): fun()
---@field interact fun(character: UObject, brick: BrickHandle, nearby?: boolean)
---@field stop_interact fun(character: UObject)
---@field players fun(): UObject[]
---@field find_player fun(name: string): UObject?
---@field player_info fun(ps: UObject): PlayerInfo
---@field controller fun(ps: UObject): UObject?
---@field character fun(ps: UObject): UObject?
---@field connected fun(ps: UObject): boolean
---@field team fun(ps: UObject): UObject?
---@field teams fun(): UObject[]
---@field team_info fun(team: UObject): TeamInfo
---@field join_team fun(ps: UObject, id: integer, respawn?: boolean)
---@field health fun(character: UObject): number, number
---@field set_health fun(character: UObject, hp: number, max?: number)
---@field kill fun(character: UObject)
---@field respawn fun(ps: UObject)
---@field leaderboard fun(target: UObject, name: string): number
---@field set_leaderboard fun(target: UObject, name: string, value: number)
---@field add_leaderboard fun(target: UObject, name: string, delta: number)
---@field item_class fun(name: string): UObject?
---@field inventory fun(character: UObject): InventorySlot[]
---@field give fun(ps: UObject, slot: integer, item: string|UObject, count?: integer)
---@field clear_slot fun(ps: UObject, slot: integer)
---@field whisper fun(ps: UObject, message: string)
---@field status fun(ps: UObject, message: string, flash?: boolean, keep?: boolean)
---@field message_box fun(ps: UObject, title: string, message: string)
---@field display_text fun(ps: UObject, params: DisplayTextParams)
---@field remove_text fun(ps: UObject, id: integer)
---@field bots fun(): UObject[]
---@field teleport fun(actor: UObject, x: number, y: number, z: number): boolean
---@field entities fun(): UObject[]
---@field spawn_entity fun(class: UObject, x: number, y: number, z: number, opts?: SpawnEntityOptions): UObject
---@field entity_color fun(entity: UObject, slot: integer, r: number, g: number, b: number, a?: number): boolean
---@field frozen fun(entity: UObject): boolean
---@field set_frozen fun(entity: UObject, frozen: boolean): boolean
---@field entity_visible fun(entity: UObject): boolean
---@field set_entity_visible fun(entity: UObject, visible: boolean): boolean
---@field entity_owner fun(entity: UObject): integer
---@field delete_entity fun(entity: UObject): boolean
---@field spawn fun(class: UObject): UObject
---@field TRACE_CHANNEL table<string, integer>
---@field TRACE_TARGETS table<string, integer>
---@field raycast fun(origin: Vec3, direction: Vec3, opts?: TraceOptions): TraceHit?
---@field sweep fun(origin: Vec3, direction: Vec3, radius: number, opts?: TraceOptions): TraceHit?
---@field chat fun(message: string)
---@field console fun(command: string)
---@field log_tail fun(n: integer, pattern?: string): string[]
---@field roles fun(): string[]
---@field call fun(target: UObject, class: string, fn: string, args: table<string, Bytes>): table<string, Bytes>
---@field ptr fun(obj?: UObject): Bytes
---@field obj fun(bytes: Bytes): UObject?
---@field bool fun(bytes: Bytes): boolean
---@field i32 fun(bytes: Bytes): integer
---@field ivec fun(x: number, y: number, z: number): Bytes
---@field fstring fun(bytes: Bytes): string
---@field ftext fun(bytes: Bytes): string

---@class OmeggaModule
---@field id string this mod's interop id (each mod is its own Lua state)
---@field plain fun(value: any, depth?: integer): any
---@field emit fun(event: string, data?: any)
---@field call fun(plugin: string, event: string, args?: any[], callback?: fun(ok: boolean, result: any)): string
---@field handle fun(name: string, fn: fun(...: any): any)
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
---@param path string
---@param fn fun(self: UObject, params: Bytes)
function __on_call(path, fn) end
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

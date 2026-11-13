// End-to-end checks against a running server, through the UE4SS bridge.
//
//   npm run acceptance -- [bridge socket]
//
// The socket defaults to $OMEGGA_UE4SS_SOCKET, then ./data/UE4SS/bridge.sock
// (run from the omegga directory). Prints PASS/FAIL per check and
// `N/M passed`; exits 0 only when every check passes. Each run uses a fresh
// nonce and its own spot on the plate, so it can be repeated on one server.
import { randomBytes, randomInt } from 'node:crypto';
import path from 'node:path';
import { Bridge } from '../src/bridge';

const socket =
  process.argv[2] ??
  process.env.OMEGGA_UE4SS_SOCKET ??
  path.join(process.cwd(), 'data', 'UE4SS', 'bridge.sock');
const bridge = new Bridge(socket);
const lua = <T = unknown>(source: string) =>
  bridge.eval<T>(`BR_RELOAD()\n${source}`);
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function waitFor<T>(
  source: string,
  ok: (v: T) => boolean,
  timeoutMs = 15_000,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let value = await lua<T>(source);
  while (!ok(value) && Date.now() < deadline) {
    await sleep(500);
    value = await lua<T>(source);
  }
  return value;
}

type Outcome = { ok: boolean; detail: string };
type BrickInfo = { valid: boolean; asset: string; position: number[] };

const nonce = randomBytes(3).toString('hex');
// brick units; each run takes its own 400-unit square of the plate
const ox = randomInt(-40, 40) * 400;
const oy = randomInt(-40, 40) * 400;
const gate = [ox - 80, oy, 6];
const shortAsset = (a: string) => a.split('.').pop();
const AND = 'BrickComponentType_Expr_LogicalAND';

const checks: [string, () => Promise<Outcome>][] = [
  [
    'place a brick',
    async () => {
      const r = await lua<{ before: number; after: number } & BrickInfo>(`
        local before = BR.brick.count()
        local h = assert(BR.brick.place(BR.brick.builder({ asset = "PB_DefaultBrick", size = { 10, 10, 6 }, color = { 255, 64, 0, 255 } }), ${ox}, ${oy}, 6), "refused")
        local info = BR.brick.info(h)
        return { before = before, after = BR.brick.count(), asset = info.asset, position = info.position }`);
      return {
        ok: r.after === r.before + 1 && r.asset.includes('PB_DefaultBrick'),
        detail: `${shortAsset(r.asset)} at [${r.position}], ${r.before} -> ${r.after} bricks`,
      };
    },
  ],
  [
    'place an npc spawn brick',
    async () => {
      const r = await lua<BrickInfo>(
        `return BR.brick.info(assert(BR.brick.place(BR.brick.builder({ asset = "B_Bot_Spawn_Point" }), ${ox + 80}, ${oy}, 6), "refused"))`,
      );
      return {
        ok: r.valid && r.asset.includes('B_Bot_Spawn_Point'),
        detail: `${shortAsset(r.asset)} at [${r.position}]`,
      };
    },
  ],
  [
    'teleport the npc',
    async () => {
      const n = await waitFor<number>('return #BR.npc.list()', v => v > 0);
      if (!n) return { ok: false, detail: 'no npc spawned' };
      const [tx, ty, tz] = [ox + 200, oy + 200, 400];
      const r = await lua<{ ok: boolean; before: number[]; after: number[] }>(`
        -- earlier runs leave npcs behind; the newest spawned last
        local bots = BR.npc.list()
        local bot = bots[#bots]
        local function loc() local v = bot:K2_GetActorLocation(); return { v.X, v.Y, v.Z } end
        local before = loc()
        local ok = BR.world.teleport(bot, ${tx}, ${ty}, ${tz})
        return { ok = ok, before = before, after = loc() }`);
      const close = r.after.every((v, i) => Math.abs(v - [tx, ty, tz][i]) < 1);
      return {
        ok: r.ok && close,
        detail: `[${r.before.map(Math.round)}] -> [${r.after.map(Math.round)}]`,
      };
    },
  ],
  [
    "set the npc's health",
    async () => {
      const r = await lua<{
        before: number[];
        set: number[];
        restored: number[];
      }>(`
        local bots = BR.npc.list()
        local bot = bots[#bots]
        local before = { BR.player.health(bot) }
        BR.player.set_health(bot, 40)
        local set = { BR.player.health(bot) }
        BR.player.set_health(bot, before[1])
        return { before = before, set = set, restored = { BR.player.health(bot) } }`);
      return {
        ok: r.set[0] === 40 && r.restored[0] === r.before[0],
        detail: `${r.before[0]}/${r.before[1]} -> ${r.set[0]} -> ${r.restored[0]}`,
      };
    },
  ],
  [
    'send a chat message',
    async () => {
      await lua(`BR.server.chat("acceptance chat ${nonce}")`);
      const line = await waitFor<string[]>(
        `return BR.server.log_tail(1, "LogChat: acceptance chat ${nonce}")`,
        v => v.length > 0,
      );
      return {
        ok: line.length > 0,
        detail: line[0]?.slice(-50) ?? 'not in the log',
      };
    },
  ],
  [
    'read console logs',
    async () => {
      const r = await lua<string[]>(
        'return BR.server.log_tail(3, "LogGlobalStatus")',
      );
      return {
        ok: r.length > 0,
        detail: `${r.length} LogGlobalStatus lines, last: ${r.at(-1)?.slice(-45) ?? ''}`,
      };
    },
  ],
  [
    'run a console command',
    async () => {
      await lua(`BR.server.console("br.Chat.Broadcast console ${nonce}")`);
      const line = await waitFor<string[]>(
        `return BR.server.log_tail(1, "LogChat: console ${nonce}")`,
        v => v.length > 0,
      );
      return {
        ok: line.length > 0,
        detail: line[0]?.slice(-50) ?? 'not in the log',
      };
    },
  ],
  [
    'list roles',
    async () => {
      const roles = await lua<string[]>('return BR.server.roles()');
      return {
        ok: roles.includes('Owner') && roles.includes('Default'),
        detail: roles.join(', '),
      };
    },
  ],
  [
    'place a logic gate',
    async () => {
      // owned by the bridge's player, so its transactions are trusted to edit it
      const r = await lua<BrickInfo>(`
        _G.ACCEPTANCE_GATE = assert(BR.brick.place(BR.brick.builder({ asset = "B_1x1_Gate_Expr_LogicalAND", owner = BR.player.owner_index() }), ${gate.join(', ')}), "refused")
        return BR.brick.info(_G.ACCEPTANCE_GATE)`);
      return {
        ok: r.valid && r.asset.includes('LogicalAND'),
        detail: `${shortAsset(r.asset)} at [${r.position}]`,
      };
    },
  ],
  [
    'set a value on the gate',
    async () => {
      const r = await lua<Record<string, number>>(
        `return BR.component.set_input(_G.ACCEPTANCE_GATE, "${AND}", "bInputA", BR.wire.bool(true))`,
      );
      const other = Object.entries(r).filter(
        ([k, v]) => k !== 'lines' && v !== 0 && k !== 'ComponentsChanged',
      );
      return {
        ok: r.ComponentsChanged === 1 && !other.length,
        detail: `bInputA = true, report ${JSON.stringify(Object.fromEntries(Object.entries(r).filter(([k, v]) => k !== 'lines' && v)))}`,
      };
    },
  ],
  [
    'read the value back',
    async () => {
      // true must read as true; false must not (a negative control, so an
      // oracle that always says "unchanged" can't pass), then restore true
      const r = await lua<{
        isTrue: boolean;
        isFalse: boolean;
        restored: boolean;
      }>(`
        local isTrue = BR.component.input_is(_G.ACCEPTANCE_GATE, "${AND}", "bInputA", BR.wire.bool(true))
        local isFalse = BR.component.input_is(_G.ACCEPTANCE_GATE, "${AND}", "bInputA", BR.wire.bool(false))
        local restored = not BR.component.input_is(_G.ACCEPTANCE_GATE, "${AND}", "bInputA", BR.wire.bool(true))
        return { isTrue = isTrue, isFalse = isFalse, restored = restored }`);
      return {
        ok: r.isTrue && !r.isFalse && r.restored,
        detail: `bInputA reads true: ${r.isTrue}, reads false: ${r.isFalse}`,
      };
    },
  ],
  [
    'leaderboard value',
    async () => {
      const r = await lua<number>(`
        local ps = BR.player.server()
        BR.leaderboard.set(ps, "Acceptance", 5)
        BR.leaderboard.add(ps, "Acceptance", 2)
        return BR.leaderboard.get(ps, "Acceptance")`);
      return { ok: r === 7, detail: `set 5, add 2: ${r}` };
    },
  ],
  [
    'fire an exec gate',
    async () => {
      // a trigger wired to Broadcast Chat Message (an admin gate); its empty message logs a bare "LogChat:"
      const wired = await lua<Record<string, number>>(`
        local CHAT = BR.component.type("Gamemode_BroadcastChatMessage"):GetFName():ToString()
        local chat = assert(BR.brick.place(BR.brick.builder({ asset = "B_1x1_Gate_Exec_Gamemode_BroadcastChatMessage", owner = BR.player.owner_index() }), ${gate[0]}, ${gate[1] + 80}, 6), "refused")
        _G.ACCEPTANCE_TRIGGER = BR.brick.trigger(${gate[0]}, ${gate[1] + 40}, 6)
        return _G.ACCEPTANCE_TRIGGER.connect(chat, CHAT, "Exec")`);
      if (wired.WiresConnected !== 1)
        return { ok: false, detail: `connect: ${JSON.stringify(wired)}` };
      await sleep(500);
      const count = 'return #BR.server.log_tail(1000000, "LogChat:")';
      const before = await lua<number>(count);
      await lua('_G.ACCEPTANCE_TRIGGER.fire()');
      const after = await waitFor<number>(count, v => v > before, 5_000);
      return {
        ok: after === before + 1,
        detail: `chat lines ${before} -> ${after}`,
      };
    },
  ],
  [
    'raycast onto a brick',
    async () => {
      // placed first: a brick has no collision until the next tick
      await lua(
        `_G.ACCEPTANCE_RAY = assert(BR.brick.place(BR.brick.builder({ asset = "PB_DefaultBrick", size = { 10, 10, 6 } }), ${ox + 160}, ${oy}, 6), "refused")`,
      );
      await sleep(200);
      const r = await lua<{ z: number; same: boolean } | null>(`
        local hit = BR.world.raycast({ ${ox + 160}, ${oy}, 500 }, { 0, 0, -1 })
        if not hit then return nil end
        local info = hit.brick and BR.brick.info(hit.brick)
        local mine = BR.brick.info(_G.ACCEPTANCE_RAY)
        return { z = hit.position[3], same = info ~= nil and info.position[1] == mine.position[1] and info.position[2] == mine.position[2] }`);
      return {
        ok: r !== null && r.same && Math.abs(r.z - 12) < 0.5,
        detail: r ? `hit z ${r.z}, the placed brick: ${r.same}` : 'no hit',
      };
    },
  ],
  [
    'set component data',
    async () => {
      const r = await lua<{ gun: boolean; active: boolean }>(`
        local spawn = assert(BR.brick.place(BR.brick.builder({ asset = "B_Bot_Spawn_Point", owner = BR.player.owner_index() }), ${ox + 240}, ${oy}, 6), "refused")
        BR.component.set(spawn, "BotSpawn", { GunSkill = 0.25, bActiveBot = false, BotName = "acceptance" })
        local T = BR.component.type("BotSpawn"):GetFName():ToString()
        return { gun = BR.component.input_is(spawn, T, "GunSkill", BR.wire.double(0.25)), active = BR.component.input_is(spawn, T, "bActiveBot", BR.wire.bool(false)) }`);
      return {
        ok: r.gun && r.active,
        detail: `GunSkill 0.25: ${r.gun}, bActiveBot false: ${r.active}`,
      };
    },
  ],
  [
    'custom event by name',
    async () => {
      // a listener for another name must stay quiet, so a name that is ignored
      // can't pass; three sends in one call must all arrive, in order
      await lua(`
        _G.ACCEPTANCE_HEARD, _G.ACCEPTANCE_WRONG = {}, 0
        BR.event.on_custom("acceptance_${nonce}", function(data, info) table.insert(_G.ACCEPTANCE_HEARD, { data[1], data[2], info.target }) end)
        BR.event.on_custom("other_${nonce}", function() _G.ACCEPTANCE_WRONG = _G.ACCEPTANCE_WRONG + 1 end)
        local ev = BR.event.custom("acceptance_${nonce}")
        for i = 1, 3 do ev.send(BR.wire.string("payload"), BR.wire.int(i)) end`);
      const heard = await waitFor<[string, number, number][]>(
        'return _G.ACCEPTANCE_HEARD',
        v => Array.isArray(v) && v.length >= 3,
        5_000,
      );
      const wrong = await lua<number>('return _G.ACCEPTANCE_WRONG');
      const got = Array.isArray(heard) ? heard : [];
      const ok =
        got.length === 3 &&
        got.every(
          (h, i) => h[0] === 'payload' && h[1] === i + 1 && h[2] === 0,
        ) &&
        wrong === 0;
      return {
        ok,
        detail: `heard ${JSON.stringify(got)}, other listener ${wrong}x`,
      };
    },
  ],
  [
    'custom event: game gates and BR interoperate',
    async () => {
      // an in-game receiver counts a BR send into a variable, and a listener
      // hears an in-game sender fired by a trigger, so neither side is only
      // talking to itself
      await lua(`
        local x, y, z = ${ox}, ${oy + 120}, 6
        local function put(asset, dx) return assert(BR.brick.place(BR.brick.builder({ asset = asset, owner = BR.player.owner_index() }), x + dx, y, z), "refused") end
        local RECV, INC, VAR = BR.component.type("Event_CustomGlobal"), BR.component.type("Exec_Var_Increment"), BR.component.type("BrickComponentType_Var")
        local recv, inc, var = put("PB_Gate_Event_CustomGlobal", 0), put("B_1x1_Gate_Exec_Var_Increment", 40), put("B_1x1_Gate_Variable", 80)
        BR.component.set(recv, RECV, { EventName = "into_game_${nonce}" })
        local RN, IN, VN = RECV:GetFName():ToString(), INC:GetFName():ToString(), VAR:GetFName():ToString()
        BR.brick.transaction(BR.player.server(), function(tx)
          tx.connect(BR.brick.id(recv), BR.component.output_port(RN, "ExecOut"), BR.brick.id(inc), BR.component.input_port(IN, "Exec"))
          tx.connect(BR.brick.id(var), BR.component.output_port(VN, "VarRef"), BR.brick.id(inc), BR.component.input_port(IN, "VarRef"))
          tx.set(BR.brick.id(inc), BR.component.input_port(IN, "Value"), BR.wire.int(1))
        end)
        local SEND = BR.component.type("SendCustomEventGlobal")
        local sender = put("PB_Gate_Exec_SendCustomEventGlobal", 160)
        BR.component.set(sender, SEND, { EventName = "from_game_${nonce}" })
        BR.brick.transaction(BR.player.server(), function(tx)
          tx.set(BR.brick.id(sender), BR.component.input_port(SEND:GetFName():ToString(), "DataIn1"), BR.wire.string("from a gate"))
        end)
        local trigger = BR.brick.trigger(x + 160, y + 40, z)
        trigger.connect(sender, SEND:GetFName():ToString(), "ExecIn")
        _G.ACCEPTANCE_INTEROP = { var = var, trigger = trigger }
        BR.event.on_custom("from_game_${nonce}", function(data) _G.ACCEPTANCE_INTEROP.heard = data[1] end)`);
      await sleep(300);
      await lua(`
        local ev = BR.event.custom("into_game_${nonce}")
        for i = 1, 3 do ev.send() end
        _G.ACCEPTANCE_INTEROP.trigger.fire()`);
      const r = await waitFor<{ count: number; heard: string | null }>(
        `local s = _G.ACCEPTANCE_INTEROP
        return { count = BR.component.get(s.var, "BrickComponentType_Var", "Value"), heard = s.heard }`,
        v => v.count >= 3 && v.heard !== null,
        5_000,
      );
      return {
        ok: r.count === 3 && r.heard === 'from a gate',
        detail: `receiver gate counted ${r.count}, listener heard ${JSON.stringify(r.heard)}`,
      };
    },
  ],
  [
    'entity custom properties: gate, read, write',
    async () => {
      // the game's own Set Custom Property gate writes them, fired by a trigger
      await lua(`
        local W = StaticFindObject("/Script/Brickadia.Default__BRLuauWorldLibrary")
        local GT = StaticFindObject("/Game/Entities/BrickGrids/Entity_DynamicBrickGrid.Entity_DynamicBrickGrid_C")
        local own = BR.player.owner_index()
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = ${ox} + 800, Y = ${oy}, Z = 3000 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local g = W:SpawnEntity(BR.world.context(), GT, xf, true, own, {})
        assert(BR.brick.place(BR.brick.builder({ asset = "PB_DefaultBrick", size = { 10, 10, 6 }, owner = own, grid = g }), 0, 0, 6), "refused")
        local reader = assert(BR.brick.place(BR.brick.builder({ asset = "B_1x1_Gate_Internal_ReadBrickGrid", owner = own, grid = g }), 40, 0, 6), "refused")
        local set = assert(BR.brick.place(BR.brick.builder({ asset = "B_1x1_Gate_Exec_Entity_SetCustomProperty", owner = own }), ${ox} + 800, ${oy} + 200, 6), "refused")
        local SN = BR.component.type("Exec_Entity_SetCustomProperty"):GetFName():ToString()
        local RN = BR.component.type("Internal_ReadBrickGrid"):GetFName():ToString()
        BR.brick.transaction(BR.player.server(), function(tx)
          tx.connect(BR.brick.id(reader), BR.component.output_port(RN, "BrickGrid"), BR.brick.id(set), BR.component.input_port(SN, "Entity"))
          tx.set(BR.brick.id(set), BR.component.input_port(SN, "Key"), BR.wire.string("score"))
          tx.set(BR.brick.id(set), BR.component.input_port(SN, "Value"), BR.wire.int(42))
        end)
        local trigger = BR.brick.trigger(${ox} + 800, ${oy} + 240, 6)
        trigger.connect(set, SN, "Exec")
        _G.ACCEPTANCE_PROPS = { grid = g, set = set, sn = SN, trigger = trigger, before = BR.entity.properties(g) }`);
      await sleep(200);
      await lua('_G.ACCEPTANCE_PROPS.trigger.fire()');
      await sleep(200);
      await lua(`
        local p = _G.ACCEPTANCE_PROPS
        BR.brick.transaction(BR.player.server(), function(tx)
          tx.set(BR.brick.id(p.set), BR.component.input_port(p.sn, "Key"), BR.wire.string("name"))
          tx.set(BR.brick.id(p.set), BR.component.input_port(p.sn, "Value"), BR.wire.string("blue team"))
        end)`);
      await sleep(200);
      await lua('_G.ACCEPTANCE_PROPS.trigger.fire()');
      const r = await waitFor<{ before: number; props: Record<string, unknown>; one: unknown }>(
        `local p = _G.ACCEPTANCE_PROPS
        local n = 0
        for _ in pairs(p.before) do n = n + 1 end
        return { before = n, props = BR.entity.properties(p.grid), one = BR.entity.property(p.grid, "score") }`,
        v => typeof v.props === 'object' && v.props !== null && 'name' in v.props,
        3_000,
      );
      // and BR's own writes, through a transaction like the applicator's paste
      const w = await lua<Record<string, unknown>>(`
        local g = _G.ACCEPTANCE_PROPS.grid
        BR.entity.set_property(g, "score", 43)
        BR.entity.set_property(g, "ratio", 0.25)
        BR.entity.set_property(g, "ready", true)
        BR.entity.set_property(g, "name", nil)
        return BR.entity.properties(g)`);
      await lua(`
        local p = _G.ACCEPTANCE_PROPS
        if p.grid:IsValid() then BR.entity.delete(p.grid) end
        BR.brick.transaction(BR.player.server(), function(tx) tx.delete(BR.brick.id(p.set)) end)
        _G.ACCEPTANCE_PROPS = nil`);
      const ok =
        r.before === 0 &&
        r.props.score === 42 &&
        r.props.name === 'blue team' &&
        r.one === 42 &&
        // a Lua table's keys come back in no particular order
        Object.keys(w).length === 3 &&
        w.ratio === 0.25 &&
        w.ready === true &&
        w.score === 43;
      return {
        ok,
        detail: `before ${r.before}, from the gate ${JSON.stringify(r.props)}, after BR's writes ${JSON.stringify(w)}`,
      };
    },
  ],
  [
    'custom event to an entity',
    async () => {
      // two grid entities and a global listener: only the target's listener may hear it
      await lua(`
        local W = StaticFindObject("/Script/Brickadia.Default__BRLuauWorldLibrary")
        local GT = StaticFindObject("/Game/Entities/BrickGrids/Entity_DynamicBrickGrid.Entity_DynamicBrickGrid_C")
        local function grid(dy)
          local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = ${ox}, Y = ${oy} + dy, Z = 3000 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
          local g = W:SpawnEntity(BR.world.context(), GT, xf, true, BR.player.owner_index(), {})
          assert(BR.brick.place(BR.brick.builder({ asset = "PB_DefaultBrick", size = { 10, 10, 6 }, owner = BR.player.owner_index(), grid = g }), 0, 0, 6), "refused")
          return g
        end
        local a, b = grid(0), grid(400)
        -- an object-event receiver on a, counting into a variable
        local own = BR.player.owner_index()
        local function put(asset, x) return assert(BR.brick.place(BR.brick.builder({ asset = asset, owner = own, grid = a }), x, 0, 6), "refused") end
        local RECV, INC, VAR = BR.component.type("Event_Custom"), BR.component.type("Exec_Var_Increment"), BR.component.type("BrickComponentType_Var")
        local recv, inc, var = put("PB_Gate_Event_Custom", 40), put("B_1x1_Gate_Exec_Var_Increment", 80), put("B_1x1_Gate_Variable", 120)
        BR.component.set(recv, RECV, { EventName = "targeted_${nonce}", bIsObjectEvent = true })
        local RN, IN, VN = RECV:GetFName():ToString(), INC:GetFName():ToString(), VAR:GetFName():ToString()
        BR.brick.transaction(BR.player.server(), function(tx)
          tx.connect(BR.brick.id(recv), BR.component.output_port(RN, "ExecOut"), BR.brick.id(inc), BR.component.input_port(IN, "Exec"))
          tx.connect(BR.brick.id(var), BR.component.output_port(VN, "VarRef"), BR.brick.id(inc), BR.component.input_port(IN, "VarRef"))
          tx.set(BR.brick.id(inc), BR.component.input_port(IN, "Value"), BR.wire.int(1))
        end)
        _G.ACCEPTANCE_TARGETED = { a = 0, b = 0, global = 0, grids = { a, b }, var = var }
        local heard = _G.ACCEPTANCE_TARGETED
        BR.event.on_custom("targeted_${nonce}", function(data) heard.a = heard.a + 1; heard.data = data[1] end, { entity = a })
        BR.event.on_custom("targeted_${nonce}", function() heard.b = heard.b + 1 end, { entity = b })
        BR.event.on_custom("targeted_${nonce}", function() heard.global = heard.global + 1 end)
        heard.reached = BR.event.custom("targeted_${nonce}", { target = a }).send(BR.wire.string("to a"))`);
      const r = await waitFor<{
        a: number;
        b: number;
        global: number;
        data?: string;
      }>('return _G.ACCEPTANCE_TARGETED', v => v.a > 0, 5_000);
      await sleep(200);
      const after = await lua<{
        a: number;
        b: number;
        global: number;
        data?: string;
        reached: number;
        counted: number;
      }>(`
        local t = _G.ACCEPTANCE_TARGETED
        local counted = BR.component.get(t.var, "BrickComponentType_Var", "Value")
        -- the grids are this check's own; left behind, every run adds two
        for _, g in ipairs(t.grids) do if g:IsValid() then BR.entity.delete(g) end end
        return { a = t.a, b = t.b, global = t.global, data = t.data, reached = t.reached, counted = counted }`);
      return {
        ok:
          after.a === 1 &&
          after.b === 0 &&
          after.global === 0 &&
          after.data === 'to a' &&
          after.reached === 1 &&
          after.counted === 1,
        detail: `target ${after.a}x (${JSON.stringify(r.data)}), other grid ${after.b}x, global ${after.global}x, receiver gate ${after.reached} reached / ${after.counted} counted`,
      };
    },
  ],
  [
    'bot chats, chat event',
    async () => {
      const r = await lua<{ who: string; message: string } | null>(`
        local ps = BR.bot.spawn("chatter ${nonce}")
        local seen
        local stop = BR.event.on("chat", function(player, info) seen = { who = BR.player.info(player).display_name, message = info.message } end)
        BR.act.say(ps, "acceptance ${nonce}")
        stop()
        BR.bot.remove(ps)
        return seen`);
      return {
        ok:
          r?.message === `acceptance ${nonce}` && r?.who === `chatter ${nonce}`,
        detail: r ? `${r.who}: ${r.message}` : 'no event',
      };
    },
  ],
  [
    'read component data',
    async () => {
      const r = await lua<{ gun: number; name: string; active: boolean }>(`
        local spawn = assert(BR.brick.place(BR.brick.builder({ asset = "B_Bot_Spawn_Point", owner = BR.player.owner_index() }), ${ox + 280}, ${oy}, 6), "refused")
        BR.component.set(spawn, "BotSpawn", { GunSkill = 0.375, BotName = "reader ${nonce}", bActiveBot = false })
        local d = BR.component.data(spawn, "BotSpawn")
        return { gun = d.GunSkill, name = BR.component.get(spawn, "BotSpawn", "BotName"), active = d.bActiveBot }`);
      return {
        ok:
          r.gun === 0.375 && r.name === `reader ${nonce}` && r.active === false,
        detail: `GunSkill ${r.gun}, BotName "${r.name}", bActiveBot ${r.active}`,
      };
    },
  ],
  [
    'spawn a bot',
    async () => {
      const r = await lua<{
        isBot: boolean;
        listed: boolean;
        asPlayer: boolean;
        character: boolean;
        name: string;
      }>(`
        local ps = BR.bot.spawn("bot ${nonce}")
        _G.ACCEPTANCE_BOT = ps
        local listed, asPlayer = false, false
        for _, b in ipairs(BR.bot.list()) do if __addr(b) == __addr(ps) then listed = true end end
        for _, p in ipairs(BR.player.list()) do if __addr(p) == __addr(ps) then asPlayer = true end end
        return { isBot = BR.bot.is_bot(ps), listed = listed, asPlayer = asPlayer,
          character = BR.player.character(ps) ~= nil, name = ps.PlayerNamePrivate:ToString() }`);
      const ok =
        r.isBot &&
        r.listed &&
        !r.asPlayer &&
        r.character &&
        r.name === `bot ${nonce}`;
      return {
        ok,
        detail: `${r.name}: bot ${r.isBot}, listed ${r.listed}, connected player ${r.asPlayer}, character ${r.character}`,
      };
    },
  ],
  [
    'bot places, paints and hides a brick',
    async () => {
      const [x, y] = [ox, oy + 280];
      const r = await lua<
        Record<string, Record<string, number>> & {
          hidden: boolean;
          shown: boolean;
        }
      >(`
        local ps = _G.ACCEPTANCE_BOT
        local r = { place = BR.brick.changes(BR.act.place(ps, { position = { ${x}, ${y}, 6 }, size = { 5, 5, 6 }, color = { 0, 128, 255 } })) }
        local hit = BR.world.raycast({ ${x}, ${y}, 200 }, { 0, 0, -1 })
        local h = hit and hit.brick
        if not h then error("nothing placed: report " .. require("omegga.json").encode(r.place) .. ", ray hit " .. require("omegga.json").encode(Omegga.plain(hit))) end
        r.paint = BR.brick.changes(BR.act.paint(ps, h, { color = { 255, 255, 0 }, material = "Glow" }))
        r.hide = BR.brick.changes(BR.act.set_visible(ps, h, false))
        r.hidden = not BR.brick.visible(h)
        BR.act.set_visible(ps, h, true)
        r.shown = BR.brick.visible(h)
        return r`);
      const ok =
        r.place.BricksPlaced === 1 &&
        r.paint.BricksChanged === 1 &&
        r.hide.BricksChanged === 1 &&
        r.hidden &&
        r.shown;
      return {
        ok,
        detail: `placed ${r.place.BricksPlaced}, painted ${r.paint.BricksChanged}, hidden ${r.hidden}, shown again ${r.shown}`,
      };
    },
  ],
  [
    'handlers block and rewrite requests',
    async () => {
      // a refused request must leave no trace, and the same request allowed must
      // go through, so a handler that breaks everything can't pass
      const [x, y] = [ox + 160, oy + 320];
      const r = await lua<{
        placedBlocked: boolean;
        placed: boolean;
        hammerBlocked: boolean;
        hammered: boolean;
      }>(`
        local ps = _G.ACCEPTANCE_BOT
        local deny = true
        local stops = {
          BR.event.on("place", function() if deny then return false end end),
          BR.event.on("delete", function() if deny then return false end end),
          BR.event.on("chat", function(_, info)
            if info.message == "blocked ${nonce}" then return false end
            if info.message == "rewrite ${nonce}" then return "rewritten ${nonce} \u{e9}\u{1F389}" end
          end),
        }
        local function brick() local hit = BR.world.raycast({ ${x}, ${y}, 200 }, { 0, 0, -1 }); return hit and hit.brick end
        local r = {}
        BR.act.place(ps, { position = { ${x}, ${y}, 6 }, size = { 5, 5, 6 } })
        r.placedBlocked = brick() ~= nil
        deny = false
        BR.act.place(ps, { position = { ${x}, ${y}, 6 }, size = { 5, 5, 6 } })
        local h = brick()
        r.placed = h ~= nil
        deny = true
        if h then BR.act.hammer(ps, h) end
        r.hammerBlocked = h ~= nil and BR.brick.valid(h)
        deny = false
        if h then BR.act.hammer(ps, h) end
        r.hammered = h ~= nil and not BR.brick.valid(h)
        BR.act.say(ps, "blocked ${nonce}")
        BR.act.say(ps, "rewrite ${nonce}")
        for _, stop in ipairs(stops) do stop() end
        return r`);
      // the log is written after the call; the rewrite went out second, so once
      // it is there the refused line would be too
      const lines = await waitFor<string[]>(
        `return BR.server.log_tail(1, "rewritten ${nonce}")`,
        v => Array.isArray(v) && v.length > 0,
        5_000,
      );
      const rewritten = Array.isArray(lines) ? (lines[0] ?? '') : '';
      const blocked = await lua<number>(
        `return #BR.server.log_tail(1, "blocked ${nonce}")`,
      );
      const ok =
        !r.placedBlocked &&
        r.placed &&
        r.hammerBlocked &&
        r.hammered &&
        blocked === 0 &&
        rewritten.endsWith('rewritten ' + nonce + ' \u00e9\u{1F389}');
      return {
        ok,
        detail: `place: refused left ${r.placedBlocked ? 'a brick' : 'nothing'}, allowed ${r.placed}; hammer: refused kept ${r.hammerBlocked}, allowed ${r.hammered}; chat: blocked logged ${blocked}x, rewrite "${rewritten.slice(-24)}"`,
      };
    },
  ],
  [
    'permissions: overrides, roles and the trace',
    async () => {
      const [x, y] = [ox + 200, oy + 320];
      const r = await lua<{
        traced: boolean;
        denied: boolean;
        allowed: boolean;
        vip: boolean[];
        restored: boolean;
      }>(`
        local ps = _G.ACCEPTANCE_BOT
        local function brick() local hit = BR.world.raycast({ ${x}, ${y}, 200 }, { 0, 0, -1 }); return hit and hit.brick end
        local r = { vip = {} }
        -- the trace shows what placing checks
        __permission_trace(true)
        __permission_trace_take()
        BR.perm.set(ps, "BR.Permission.Building", false)
        BR.act.place(ps, { position = { ${x}, ${y}, 6 }, size = { 5, 5, 6 } })
        for _, c in ipairs(__permission_trace_take()) do
          if c.tag == "BR.Permission.Building.Placer.PlaceBricks" and __addr(c.player) == __addr(ps) and c.result == false then r.traced = true end
        end
        __permission_trace(false)
        r.denied = brick() == nil
        BR.perm.set(ps, "BR.Permission.Building", nil)
        BR.act.place(ps, { position = { ${x}, ${y}, 6 }, size = { 5, 5, 6 } })
        r.allowed = brick() ~= nil
        BR.perm.define("acceptance_${nonce}.vip")
        r.vip[1] = BR.perm.has(ps, "acceptance_${nonce}.vip")
        BR.perm.set_role("Default", "acceptance_${nonce}", true)
        r.vip[2] = BR.perm.has(ps, "acceptance_${nonce}.vip")
        BR.perm.set(ps, "acceptance_${nonce}.vip", false)
        r.vip[3] = BR.perm.has(ps, "acceptance_${nonce}.vip")
        BR.perm.clear(ps)
        BR.perm.set_role("Default", "acceptance_${nonce}", nil)
        r.vip[4] = BR.perm.has(ps, "acceptance_${nonce}.vip")
        r.restored = BR.perm.has(ps, "BR.Permission.Building.Placer.PlaceBricks")
        return r`);
      const ok =
        r.traced &&
        r.denied &&
        r.allowed &&
        r.vip.join() === 'false,true,false,false' &&
        r.restored;
      return {
        ok,
        detail: `trace saw the refusal ${r.traced}; place forbidden ${r.denied}, allowed again ${r.allowed}; plugin permission default/role/player/cleared ${r.vip.join('/')}`,
      };
    },
  ],
  [
    'timers: once, repeating, owned, cancelled',
    async () => {
      await lua(`
        local log = {}
        _G.ACCEPTANCE_TIMERS = log
        local owner = BR.bot.spawn("timer owner ${nonce}")
        BR.timer.after(0.3, function() log[#log + 1] = "after" end)
        local n = 0
        BR.timer.every(0.1, function() n = n + 1; log[#log + 1] = "every" .. n; if n == 3 then return false end end)
        BR.timer.after(0.2, function() log[#log + 1] = "cancelled" end)()
        local owned = 0
        BR.timer.every(0.05, function() owned = owned + 1 end, { owner = owner })
        BR.timer.after(0.2, function() log.owned_at_remove = owned; BR.bot.remove(owner) end)
        BR.timer.after(0.6, function() log.owned_later = owned end)`);
      const r = await waitFor<Record<string, unknown>>(
        'return _G.ACCEPTANCE_TIMERS',
        v => v.owned_later !== undefined,
        5_000,
      );
      const order = Object.keys(r)
        .filter(k => /^\d+$/.test(k))
        .sort((a, b) => Number(a) - Number(b))
        .map(k => r[k]);
      const ok =
        order.join() === 'every1,every2,after,every3' &&
        r.owned_at_remove === r.owned_later;
      return {
        ok,
        detail: `order ${order.join(' ')}; owned timer ${r.owned_at_remove} runs, ${r.owned_later} after its bot left`,
      };
    },
  ],
  [
    'game mode events: spawn, team, respawn lock, leave',
    async () => {
      // a character alive when listening starts doesn't count; a respawn does
      await lua(`
        local log = {}
        _G.ACCEPTANCE_GM = { log = log }
        local ps = BR.bot.spawn("spawner ${nonce}")
        _G.ACCEPTANCE_GM.ps = ps
        local function mine(p) return p and __addr(p) == __addr(ps) end
        _G.ACCEPTANCE_GM.stops = {
          BR.event.on_spawn(function(p, ch) if mine(p) then log[#log + 1] = ch and __addr(ch) == __addr(BR.player.character(ps)) and "spawn" or "spawn without its character" end end),
          BR.event.on("team", function(p, info) if mine(p) then log[#log + 1] = "team" end end),
          BR.event.on("respawn_lock", function(p, info) if mine(p) then log[#log + 1] = info.locked and "locked" or "unlocked" end end),
          BR.event.on("leave", function(p) if mine(p) then log[#log + 1] = "leave" end end),
        }`);
      await sleep(300);
      await lua(`
        local ps = _G.ACCEPTANCE_GM.ps
        BR.player.set_can_respawn(ps, false)
        BR.player.set_can_respawn(ps, true)
        BR.team.join(ps, -1, false)
        BR.player.kill(BR.player.character(ps))
        BR.timer.after(0.3, function()
          BR.player.respawn(ps)
          BR.timer.after(0.3, function() BR.bot.remove(ps) end)
        end)`);
      const log = await waitFor<string[]>(
        'return _G.ACCEPTANCE_GM.log',
        v => Array.isArray(v) && v.includes('leave'),
        5_000,
      );
      await lua('for _, stop in ipairs(_G.ACCEPTANCE_GM.stops) do stop() end');
      const got = Array.isArray(log) ? log : [];
      const ok = got.join() === 'locked,unlocked,team,spawn,leave';
      return { ok, detail: got.join(' ') || 'nothing heard' };
    },
  ],
  [
    'BR.math matches the engine',
    async () => {
      // the same random inputs through BR.math and KismetMathLibrary; angles
      // allow for the engine computing some in single precision
      const r = await lua<{ bad: string[]; failed: number; n: number }>(`
        local M = BR.math
        local K = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        local bad, n = {}, 0
        local function q(a, b)
          return math.min(math.max(math.abs(a.x - b.X), math.abs(a.y - b.Y), math.abs(a.z - b.Z), math.abs(a.w - b.W)),
            math.max(math.abs(a.x + b.X), math.abs(a.y + b.Y), math.abs(a.z + b.Z), math.abs(a.w + b.W)))
        end
        local function v(a, b) return math.max(math.abs(a.x - b.X), math.abs(a.y - b.Y), math.abs(a.z - b.Z)) end
        local function rt(a, b) return math.max(math.abs(M.delta_angle(a.Pitch, b.Pitch)), math.abs(M.delta_angle(a.Yaw, b.Yaw)), math.abs(M.delta_angle(a.Roll, b.Roll))) end
        local function check(name, d, tol) n = n + 1 if d > tol then bad[#bad + 1] = name .. " " .. d end end
        local seed = ${randomInt(1, 2 ** 31 - 1)}
        local function rnd(lo, hi) seed = (seed * 1103515245 + 12345) % 2147483648 return lo + (hi - lo) * seed / 2147483648 end
        for _ = 1, 50 do
          local e = M.vec(rnd(-180, 180), rnd(-89, 89), rnd(-180, 180))
          local qa, qb = M.quat_euler(e), M.quat_euler(rnd(-180, 180), rnd(-89, 89), rnd(-180, 180))
          local a, b = M.vec(rnd(-100, 100), rnd(-100, 100), rnd(-100, 100)), M.vec(rnd(-100, 100), rnd(-100, 100), rnd(-100, 100))
          local r = M.rot(rnd(-89, 89), rnd(-180, 180), rnd(-180, 180))
          check("euler->quat", q(qa, K:Quat_MakeFromEuler(e:ue())), 1e-9)
          check("quat->rotator", rt(qa:rotator(), K:Quat_Rotator(qa:ue())), 1e-6)
          check("rotator->quat", q(r:quat(), K:Conv_RotatorToQuaternion(r:ue())), 1e-9)
          check("rotate", v(qa:rotate(a), K:Quat_RotateVector(qa:ue(), a:ue())), 1e-9)
          check("multiply", q(qa * qb, K:Multiply_QuatQuat(qa:ue(), qb:ue())), 1e-9)
          check("slerp", q(qa:slerp(qb, 0.3), K:Quat_Slerp(qa:ue(), qb:ue(), 0.3)), 1e-9)
          check("between", q(M.quat_between(a, b), K:Quat_FindBetweenVectors(a:ue(), b:ue())), 1e-9)
          check("look", rt(M.quat_look(a, b):rotator(), K:MakeRotFromXZ(a:ue(), b:ue())), 1e-3)
          check("forward", v(r:forward(), K:Conv_RotatorToVector(r:ue())), 1e-9)
          check("direction->rotator", rt(a:rotator(), K:Conv_VectorToRotator(a:ue())), 1e-6)
          check("angle", math.abs(qa:angle_to(qb) - K:Quat_AngularDistance(qa:ue(), qb:ue()) * M.R2D), 1e-3)
          local x = rnd(-1000, 1000)
          check("normalize_angle", math.abs(M.normalize_angle(x) - K:NormalizeAxis(x)), 1e-3)
        end
        -- an empty table comes back as {}, so the count says whether any failed
        return { bad = bad, failed = #bad, n = n }`);
      return {
        ok: r.failed === 0,
        detail: r.failed ? Object.values(r.bad).slice(0, 5).join(', ') : `${r.n} comparisons agree`,
      };
    },
  ],
  [
    'non-ASCII text through UE4SS',
    async () => {
      // a Lua string handed to a game function arrives as UTF-16; it used to be
      // copied byte by byte, so one "█" became three wrong characters
      const r = await lua<{ block: number; accent: number; back: boolean }>(`
        local K = StaticFindObject("/Script/Engine.Default__KismetStringLibrary")
        return { block = K:Len("█"), accent = K:Len("café"), back = K:Concat_StrStr("█ café", ""):ToString() == "█ café" }`);
      return {
        ok: r.block === 1 && r.accent === 4 && r.back,
        detail: `Len("█") ${r.block}, Len("café") ${r.accent}, round trip ${r.back}`,
      };
    },
  ],
  [
    'chat commands',
    async () => {
      // omegga hands a declared command to the plugin as (player name, ...words
      // split on spaces); this sends the same call the plugin would
      const name = await lua<string>(`
        local ps = _G.ACCEPTANCE_BOT
        _G.ACC_CMD = { calls = {}, denied = true }
        local r = _G.ACC_CMD
        BR.perm.define("acceptance_${nonce}.cmd")
        r.stops = {
          BR.command.register("acc${nonce}", function(_, args) r.calls[#r.calls + 1] = table.concat(args, "|") end, { aliases = { "acca${nonce}" } }),
          BR.command.register("accp${nonce}", function() r.denied = false end, { permission = "acceptance_${nonce}.cmd" }),
        }
        -- bots have no user name, so the display name finds this one
        return BR.player.info(ps).display_name`);
      const send = (cmd: string, ...words: string[]) => bridge.callLua(`cmd:${cmd}`, [name, ...words]);
      await send(`acc${nonce}`, 'one', '"two', 'words"');
      await send(`acca${nonce}`, 'alias');
      await send(`accp${nonce}`);
      await lua(`for _, stop in ipairs(_G.ACC_CMD.stops) do stop() end`);
      await send(`acc${nonce}`, 'after');
      const r = await lua<{ calls: string[]; denied: boolean }>(`
        local r = _G.ACC_CMD
        _G.ACC_CMD = nil
        return { calls = r.calls, denied = r.denied }`);
      const ok = r.calls.join() === 'one|two words,alias' && r.denied;
      return {
        ok,
        detail: `calls ${JSON.stringify(r.calls)}, permission refused ${r.denied}`,
      };
    },
  ],
  [
    'moderation: join gate, kick, ban',
    async () => {
      // a made-up account id, so no real player is ever banned
      const r = await lua<{
        ban?: { reason: string; expires: number; created: number };
        unbanned: boolean;
      }>(`
        _G.ACCEPTANCE_GATE = { seen = {} }
        local g = _G.ACCEPTANCE_GATE
        g.stop = BR.mod.on_join(function(ps)
          local name = BR.player.info(ps).display_name
          g.seen[#g.seen + 1] = name
          if name == "refused ${nonce}" then return "acceptance ${nonce}" end
        end)
        g.ok = BR.bot.spawn("allowed ${nonce}")
        g.no = BR.bot.spawn("refused ${nonce}")
        local id = string.format("acce${nonce.slice(0, 4)}-0000-4000-8000-%012x", ${Date.now() % 1e12})
        BR.mod.ban(id, { duration = 600, reason = "acceptance ${nonce}" })
        local r = { ban = BR.mod.banned(id) }
        BR.mod.unban(id)
        r.unbanned = BR.mod.banned(id) == nil
        return r`);
      const gate = await waitFor<{ seen: string[]; ok: boolean; no: boolean }>(
        `local g = _G.ACCEPTANCE_GATE
        local function listed(ps) for _, p in ipairs(BR.bot.list()) do if __addr(p) == __addr(ps) then return true end end return false end
        return { seen = g.seen, ok = listed(g.ok), no = listed(g.no) }`,
        v => Array.isArray(v.seen) && v.seen.length >= 2,
        5_000,
      );
      await lua(
        '_G.ACCEPTANCE_GATE.stop(); BR.bot.remove(_G.ACCEPTANCE_GATE.ok)',
      );
      const kicked = await waitFor<string[]>(
        `return BR.server.log_tail(1, "refused ${nonce} was kicked")`,
        v => Array.isArray(v) && v.length > 0,
        5_000,
      );
      const ban = r.ban;
      const ok =
        gate.ok &&
        !gate.no &&
        Array.isArray(kicked) &&
        kicked.length === 1 &&
        ban?.reason === `acceptance ${nonce}` &&
        ban.expires - ban.created === 600 &&
        r.unbanned;
      return {
        ok,
        detail: `gate saw ${JSON.stringify(gate.seen)}, allowed stays ${gate.ok}, refused kicked ${!gate.no}; ban ${ban ? `${ban.expires - ban.created}s "${ban.reason}"` : 'missing'}, unbanned ${r.unbanned}`,
      };
    },
  ],
  [
    'area queries',
    async () => {
      const [x, y] = [ox + 240, oy + 320];
      const r = await lua<{
        sphere: boolean;
        box: boolean;
        empty: number;
        bot_overlap: boolean;
        near_first: boolean;
      }>(`
        local ps = _G.ACCEPTANCE_BOT
        local b = assert(BR.brick.place(BR.brick.builder({ size = { 5, 5, 6 }, owner = BR.player.owner_index() }), ${x}, ${y}, 6), "refused")
        local r = {}
        r.sphere = BR.brick.in_sphere({ ${x}, ${y}, 6 }, 20)[1] == b
        r.box = BR.brick.in_box({ ${x} - 10, ${y} - 10, 0 }, { ${x} + 10, ${y} + 10, 12 })[1] == b
        r.empty = #BR.brick.in_sphere({ ${x}, ${y}, 2000 }, 20)
        local ch = BR.player.character(ps)
        local l = ch:K2_GetActorLocation()
        r.bot_overlap = false
        for _, o in ipairs(BR.world.overlap_sphere({ l.X, l.Y, l.Z }, 100)) do
          if __addr(o.actor) == __addr(ch) then r.bot_overlap = true end
        end
        local near = BR.world.players_near({ l.X, l.Y, l.Z }, 50)
        r.near_first = near[1] ~= nil and __addr(near[1].player) == __addr(ps)
        return r`);
      const ok =
        r.sphere && r.box && r.empty === 0 && r.bot_overlap && r.near_first;
      return {
        ok,
        detail: `brick by sphere ${r.sphere}, by box ${r.box}, empty air ${r.empty}; bot in overlap ${r.bot_overlap}, nearest player ${r.near_first}`,
      };
    },
  ],
  [
    'player controls and team rules',
    async () => {
      const [x, y] = [ox + 280, oy + 320];
      const r = await lua<{
        rose: number;
        respawn: boolean[];
        checkpoint: boolean[];
        speed: number[];
        removed: boolean;
        kinds: number;
      }>(`
        local ps = BR.bot.spawn("controls ${nonce}")
        local r = {}
        local ch = BR.player.character(ps)
        local z0 = ch:K2_GetActorLocation().Z
        BR.player.launch(ch, { 0, 0, 1200 }, { replace_z = true })
        _G.ACCEPTANCE_LAUNCH = { ch = ch, z0 = z0 }
        BR.player.set_can_respawn(ps, false)
        r.respawn = { BR.player.can_respawn(ps) }
        BR.player.set_can_respawn(ps, true)
        r.respawn[2] = BR.player.can_respawn(ps)
        local cp = assert(BR.brick.place(BR.brick.builder({ size = { 5, 5, 2 }, owner = BR.player.owner_index() }), ${x}, ${y}, 2), "refused")
        BR.player.set_checkpoint(ps, cp)
        r.checkpoint = { BR.player.checkpoint(ps) == cp }
        BR.player.set_checkpoint(ps, nil)
        r.checkpoint[2] = BR.player.checkpoint(ps) == nil
        -- a rule on the bot's own team, removed afterwards
        local team = BR.player.team(ps)
        local before = ch.CharacterMovement:GetMaxSpeed()
        local rule = BR.team.rule(team, "EnhancedBrickadians")
        rule:SetWalkSpeedMultiplier(2)
        r.speed = { before, ch.CharacterMovement:GetMaxSpeed() }
        BR.team.remove_rule(team, "EnhancedBrickadians")
        r.removed = BR.team.rule(team, "EnhancedBrickadians", false) == nil
        r.kinds = #BR.team.rule_kinds()
        _G.ACCEPTANCE_LAUNCH.ps = ps
        return r`);
      await sleep(300);
      const rose = await lua<number>(
        'local l = _G.ACCEPTANCE_LAUNCH; local z = l.ch:K2_GetActorLocation().Z - l.z0; BR.bot.remove(l.ps); return z',
      );
      const ok =
        rose > 100 &&
        r.respawn.join() === 'false,true' &&
        r.checkpoint.join() === 'true,true' &&
        Math.abs(r.speed[1] - 2 * r.speed[0]) < 1 &&
        r.removed &&
        r.kinds > 20;
      return {
        ok,
        detail: `launched up ${Math.round(rose)}; respawn lock ${r.respawn.join('/')}; checkpoint ${r.checkpoint.join('/')}; max speed ${r.speed.join(' -> ')} with a 2x rule, removed ${r.removed}; ${r.kinds} rule kinds`,
      };
    },
  ],
  [
    'after-call hooks',
    async () => {
      await lua(`
        local chat = "/Script/Brickadia.BRPlayerController:ServerPushChatMessage"
        _G.ACCEPTANCE_AFTER = { pre = 0, after = 0 }
        local a = _G.ACCEPTANCE_AFTER
        local ps = BR.bot.spawn("after ${nonce}")
        local pc = BR.player.controller(ps)
        BR.event.hook(chat, function(c) if a.block and __addr(c) == __addr(pc) then a.pre = a.pre + 1 return false end end)
        a.stop = BR.event.after(chat, function(c) if __addr(c) == __addr(pc) then a.after = a.after + 1 end end)
        a.ps = ps
        BR.act.say(ps, "after ${nonce} runs")
        a.block = true
        BR.act.say(ps, "after ${nonce} blocked")
        a.block = false`);
      const r = await lua<{ pre: number; after: number }>(`
        local a = _G.ACCEPTANCE_AFTER
        a.stop()
        BR.bot.remove(a.ps)
        return { pre = a.pre, after = a.after }`);
      const ok = r.pre === 1 && r.after === 1;
      return {
        ok,
        detail: `blocked ${r.pre} call, after-hook ran ${r.after} time(s) (once for the call that ran)`,
      };
    },
  ],
  [
    'scripted bricks',
    async () => {
      const [x, y] = [ox + 400, oy + 400];
      await lua(`
        _G.ACCEPTANCE_BH = { log = {} }
        local a = _G.ACCEPTANCE_BH
        a.stop = BR.behavior.define("acc${nonce}", {
          assets = { "B_1x1_Round" },
          appear = function(self, how) table.insert(a.log, "appear " .. how) self.state.seen = true self:save() end,
          remove = function(self) table.insert(a.log, "remove") end,
        })
        local b = BR.brick.builder({ asset = "B_1x1_Round", owner = BR.player.owner_index() })
        BR.brick.transaction(BR.player.server(), function(tx) a.id = tx.place(b, { ${x}, ${y}, 2000 }) end)`);
      const placed = await waitFor<string[]>(
        'return _G.ACCEPTANCE_BH.log',
        v => v.length >= 1,
        3000,
      );
      await lua(
        'BR.brick.transaction(BR.player.server(), function(tx) tx.delete(_G.ACCEPTANCE_BH.id) end)',
      );
      const log = await waitFor<string[]>(
        'return _G.ACCEPTANCE_BH.log',
        v => v.length >= 2,
        3000,
      );
      await lua('_G.ACCEPTANCE_BH.stop()');
      const ok =
        placed[0] === 'appear placed' && log.join() === 'appear placed,remove';
      return { ok, detail: log.join(', ') || 'nothing' };
    },
  ],
  [
    'build rules from zone bricks',
    async () => {
      const [x, y] = [ox + 1200, oy + 2000];
      const r = await lua<Record<string, unknown>>(`
        local ps = BR.bot.spawn("zones ${nonce}")
        local zone = assert(BR.brick.place(BR.brick.builder({ asset = "BP_ZoneProjector", size = { 20, 20, 2 }, owner = BR.player.owner_index() }), ${x}, ${y}, 2), "refused")
        BR.component.set(zone, BR.zone.COMPONENT, { ZoneEndDistance = 200, TagFilter = "plot-${nonce}" })
        local refused = {}
        local stop = BR.region.on_refused(function(_, i) refused[#refused + 1] = i.zone and "zone" or "other" end)
        local seen
        BR.region.zone_rule(function(z, p)
          if z.tag ~= "plot-${nonce}" then return nil end
          seen = z.tag
          return __addr(p) ~= __addr(ps), "members only"
        end)
        local function placed(o) return BR.act.place(ps, o).BricksPlaced or 0 end
        local r = {}
        r.inside = placed({ position = { ${x}, ${y}, 60 }, size = { 5, 5, 6 } })
        r.outside = placed({ position = { ${x} + 400, ${y}, 6 }, size = { 5, 5, 6 } })
        BR.region.zone_rule(nil)
        stop()
        r.after = placed({ position = { ${x}, ${y}, 60 }, size = { 5, 5, 6 } })
        r.refused, r.seen = refused, seen
        BR.bot.remove(ps)
        local hs = BR.brick.in_box({ ${x} - 100, ${y} - 100, 0 }, { ${x} + 500, ${y} + 100, 300 })
        BR.brick.transaction(BR.player.server(), function(tx) for _, b in ipairs(hs) do tx.delete(BR.brick.id(b)) end end)
        return r`);
      const refused = Array.isArray(r.refused) ? r.refused.join() : '';
      const ok =
        r.inside === 0 &&
        r.outside === 1 &&
        r.after === 1 &&
        refused === 'zone' &&
        r.seen === `plot-${nonce}`;
      return {
        ok,
        detail: `in the zone ${String(r.inside)}, outside ${String(r.outside)}, rule off ${String(r.after)}, refusals ${refused || 'none'}`,
      };
    },
  ],
  [
    'build regions: plots, volumes, bans, delete, select, clear',
    async () => {
      const [x, y] = [ox + 1200, oy + 1200];
      const r = await lua<Record<string, unknown>>(`
        local plot, free = "plot-${nonce}", "free-${nonce}"
        local ps = BR.bot.spawn("region ${nonce}")
        local refused = {}
        local stop = BR.region.on_refused(function(_, i) refused[#refused + 1] = i.action .. ":" .. (i.region or i.banned or "default") end)
        BR.region.define(plot, { box = { min = { ${x}, ${y}, 0 }, max = { ${x} + 200, ${y} + 200, 200 } } })
        BR.region.define(free, { box = { min = { ${x} + 400, ${y}, 0 }, max = { ${x} + 600, ${y} + 200, 200 } }, build = "everyone",
          ban_components = { "BrickComponentType_Expr_LogicalAND" } })
        local function placed(o) return BR.act.place(ps, o).BricksPlaced or 0 end
        local r = {}
        r.inside = placed({ position = { ${x} + 100, ${y} + 100, 6 }, size = { 5, 5, 6 } })
        -- a dragged row from outside: the 10th copy touches the border, so allowed...
        r.touch = placed({ position = { ${x} - 95, ${y} + 150, 6 }, size = { 5, 5, 6 }, count = { 20, 1, 1 } })
        -- ...and from 10 further in, the last copy is inside: refused
        r.reach = placed({ position = { ${x} - 85, ${y} + 100, 6 }, size = { 5, 5, 6 }, count = { 20, 1, 1 } })
        BR.region.ban("assets", "B_2x2_Cone")
        r.banned = placed({ position = { ${x} + 300, ${y} - 100, 12 }, asset = "B_2x2_Cone" })
        BR.region.unban("assets", "B_2x2_Cone")
        r.gate = placed({ position = { ${x} + 500, ${y} + 100, 2 }, asset = "B_1x1_Gate_Expr_LogicalAND" })
        r.gate_left = #BR.brick.in_box({ ${x} + 490, ${y} + 90, 0 }, { ${x} + 510, ${y} + 110, 10 })
        local h = BR.brick.place(BR.brick.builder({ size = { 5, 5, 6 }, owner = BR.player.owner_index() }), ${x} + 50, ${y} + 50, 6)
        r.hammer = BR.act.hammer(ps, h).BricksDeleted or 0
        local pc = BR.player.controller(ps)
        local sel
        for _, t in ipairs(FindAllOf("BRTool_Selector") or {}) do
          if t:IsValid() then local o = t:GetOwnerController() if o and o:IsValid() and __addr(o) == __addr(pc) then sel = t end end
        end
        local n = #refused
        BR.raw.call(sel, "BRTool_Selector", "ServerSelectInBox", { TargetGrid = BR.raw.ptr(BR.world.global_grid().BrickGridComponent),
          SelectionCenter = BR.raw.ivec(${x} + 100, ${y} + 100, 20), SelectionSize = BR.raw.ivec(20, 20, 20), SelectType = "\0" })
        r.select = #refused > n
        BR.raw.call(sel, "BRTool_Selector", "ServerDeselectAll", {})
        -- a prefab pasted from outside, its bricks landing inside: placed, then all taken back out
        local cached = BR.prefab.cached()[1]
        if cached then
          -- two pastes in a row: past the game's paste cooldown
          BR.perm.set(ps, "BR.Permission.Prefabs.BypassTimeout", true)
          -- a paste can bring dynamic grids (this world's prefab has four)
          local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
          local function grids()
            local list, set = {}, {}
            GS:GetAllActorsOfClass(BR.world.context(), StaticFindObject("/Script/Brickadia.BrickGridDynamicActor"), list)
            for _, a in ipairs(list) do set[__addr(a:get())] = a:get() end
            return set
          end
          local grids_before = grids()
          local probe = BR.act.place_prefab(ps, { prefab = cached.hash, position = { ${x} + 900, ${y} + 900, 60 } })
          for k, g in pairs(grids()) do if not grids_before[k] then BR.entity.delete(g) end end
          r.prefab_free = probe.BricksPlaced or 0
          -- where its world-grid bricks landed, relative to the anchor
          local hs = BR.brick.in_box({ ${x} + 700, ${y} + 700, 0 }, { ${x} + 1100, ${y} + 1100, 400 })
          local dy = 0
          for _, b in ipairs(hs) do dy = math.max(dy, BR.brick.info(b).position[2] - (${y} + 900)) end
          BR.brick.transaction(BR.player.server(), function(tx) for _, b in ipairs(hs) do tx.delete(BR.brick.id(b)) end end)
          local n = #refused
          BR.act.place_prefab(ps, { prefab = cached.hash, position = { ${x} + 100, ${y} - dy + 5, 60 } })
          r.prefab_removed = #refused > n and refused[#refused]:find("place:") ~= nil
          r.prefab_left = #BR.brick.in_box({ ${x}, ${y}, 0 }, { ${x} + 200, ${y} + 200, 200 })
          r.prefab_grids_left = 0
          for k in pairs(grids()) do if not grids_before[k] then r.prefab_grids_left = r.prefab_grids_left + 1 end end
        else
          r.prefab_free, r.prefab_removed, r.prefab_left, r.prefab_grids_left = "no cached prefab", true, 0, 0
        end
        BR.region.add_owner(plot, ps)
        r.owner = placed({ position = { ${x} + 150, ${y} + 150, 6 }, size = { 5, 5, 6 } })
        stop()
        r.refused = refused
        r.cleared = BR.region.clear(plot)
        BR.region.remove(plot)
        BR.region.remove(free)
        BR.bot.remove(ps)
        local hs = BR.brick.in_box({ ${x} - 200, ${y} - 200, 0 }, { ${x} + 800, ${y} + 400, 200 })
        BR.brick.transaction(BR.player.server(), function(tx) for _, b in ipairs(hs) do tx.delete(BR.brick.id(b)) end end)
        return r`);
      const want = {
        inside: 0,
        touch: 10,
        reach: 0,
        banned: 0,
        gate: 1,
        gate_left: 0,
        hammer: 0,
        select: true,
        owner: 1,
        prefab_removed: true,
        prefab_grids_left: 0,
      };
      const bad = Object.entries(want)
        .filter(([k, v]) => r[k] !== v)
        .map(([k, v]) => `${k} ${JSON.stringify(r[k])} (want ${v})`);
      if (
        r.prefab_free !== 'no cached prefab' &&
        !(typeof r.prefab_free === 'number' && r.prefab_free > 0)
      )
        bad.push(`prefab paste placed ${JSON.stringify(r.prefab_free)}`);
      // the hammered brick and the owner's; the row along the border touches the box too
      if (typeof r.cleared !== 'number' || r.cleared < 2)
        bad.push(`cleared ${JSON.stringify(r.cleared)} (want 2 or more)`);
      return {
        ok: bad.length === 0,
        detail: bad.length
          ? bad.join('; ')
          : `refused ${JSON.stringify(r.refused)}`,
      };
    },
  ],
  [
    'targets',
    async () => {
      const r = await lua<Record<string, unknown>>(`
        local a, b, c = BR.bot.spawn("Alpha ${nonce}"), BR.bot.spawn("Alphabet ${nonce}"), BR.bot.spawn("Bravo ${nonce}")
        local function names(list) local o = {} for _, p in ipairs(list or {}) do o[#o + 1] = BR.player.info(p).display_name:match("^%S+") end table.sort(o) return table.concat(o, ",") end
        local o = { bots = true }
        local r = {}
        -- other bots of the run are around too: count only this check's own
        local mine = {}
        for _, p in ipairs(BR.target.resolve(a, "@o", o) or {}) do
          if __addr(p) == __addr(b) or __addr(p) == __addr(c) or __addr(p) == __addr(a) then mine[#mine + 1] = p end
        end
        r.others = names(mine)
        r.prefix = names(BR.target.resolve(nil, "alpha", o))
        r.ambiguous = select(2, BR.target.one(nil, "alph", o)) ~= nil
        r.exact = names(BR.target.resolve(nil, "Bravo ${nonce}", o))
        BR.perm.set(c, "target.immune", true)
        r.immune = BR.target.resolve(a, "Bravo ${nonce}", o) == nil
        BR.perm.set(a, "target.bypass_immunity", true)
        r.bypass = names(BR.target.resolve(a, "Bravo ${nonce}", o))
        BR.perm.clear(a) BR.perm.clear(c)
        for _, p in ipairs({ a, b, c }) do BR.bot.remove(p) end
        return r`);
      // the bots' names carry the nonce; only the first word is compared
      const want: Record<string, unknown> = {
        others: 'Alphabet,Bravo',
        prefix: 'Alpha,Alphabet',
        ambiguous: true,
        exact: 'Bravo',
        immune: true,
        bypass: 'Bravo',
      };
      const bad = Object.entries(want)
        .filter(([k, v]) => r[k] !== v)
        .map(
          ([k, v]) =>
            `${k} ${JSON.stringify(r[k])} (want ${JSON.stringify(v)})`,
        );
      return {
        ok: bad.length === 0,
        detail: bad.length
          ? bad.join('; ')
          : 'selectors, names and immunity',
      };
    },
  ],
  [
    'profiling, server stats and AFK',
    async () => {
      await lua(`
        local g = { log = {} }
        _G.ACC_PROF = g
        g.ps = BR.bot.spawn("idle ${nonce}")
        g.stop_afk = BR.afk.on(1.5, function(p, away)
          if __addr(p) == __addr(g.ps) then g.log[#g.log + 1] = away and "away" or "back" end
        end, { bots = true })
        g.stop_tick = BR.event.tick(function() local x = 0 for i = 1, 2000 do x = x + i end end)
        BR.server.stats()
        BR.profile.sample(1, function(r)
          for _, e in ipairs(r) do if e.kind == "tick" and e.source:find("bridge") and e.calls > 10 then g.profiled = e.calls end end
        end, { limit = 100 })
        BR.timer.after(3, function() BR.bot.move(g.ps, 1, 0) end)`);
      const r = await waitFor<{
        log: string[];
        profiled?: number;
        rate?: number;
      }>(
        `
        local g = _G.ACC_PROF
        return { log = g.log, profiled = g.profiled, rate = BR.server.stats().tick_rate }`,
        v => Array.isArray(v.log) && v.log.length >= 2 && v.profiled !== undefined,
        8_000,
      );
      // an empty Lua table comes back as {}
      const log = Array.isArray(r.log) ? r.log : [];
      await lua(
        'local g = _G.ACC_PROF g.stop_afk() g.stop_tick() BR.bot.remove(g.ps)',
      );
      const ok =
        log[0] === 'away' &&
        log[1] === 'back' &&
        (r.profiled ?? 0) > 10 &&
        (r.rate ?? 0) > 5;
      return {
        ok,
        detail: `afk ${log.join(',') || 'nothing'}; tick handler profiled ${r.profiled} calls; ${Math.round(r.rate ?? 0)} ticks/s`,
      };
    },
  ],
  [
    'removal signal',
    async () => {
      const [x, y] = [ox + 1500, oy];
      await lua(`
        _G.ACC_WATCH = {}
        local log = _G.ACC_WATCH
        local function b(dx) return BR.brick.place(BR.brick.builder({ size = { 5, 5, 6 }, owner = BR.player.owner_index() }), ${x} + dx, ${y}, 6) end
        local ps = BR.bot.spawn("watch ${nonce}")
        local h1, h2, h3, h4 = b(0), b(20), b(40), b(60)
        BR.watch.removed(h1, function() log[#log + 1] = "hammer" end)
        BR.watch.removed(h2, function() log[#log + 1] = "transaction" end)
        BR.watch.removed(h3, function() log[#log + 1] = "clear" end)
        BR.watch.removed(h4, function() log[#log + 1] = "stopped" end)()
        local e = BR.entity.spawn(BR.entity.class("Entity_Ball"), ${x}, ${y} + 100, 300)
        BR.watch.removed(e, function() log[#log + 1] = "entity" end)
        BR.act.hammer(ps, h1)
        BR.brick.transaction(BR.player.server(), function(tx) tx.delete(BR.brick.id(h2)) tx.delete(BR.brick.id(h4)) end)
        BR.region.define("watch-${nonce}", { box = { min = { ${x} + 30, ${y} - 10, 0 }, max = { ${x} + 50, ${y} + 10, 20 } }, build = "everyone" })
        BR.region.clear("watch-${nonce}")
        BR.region.remove("watch-${nonce}")
        BR.entity.delete(e)
        BR.bot.remove(ps)`);
      const log = await waitFor<string[]>(
        'return _G.ACC_WATCH',
        v => Array.isArray(v) && v.length >= 4,
        3_000,
      );
      const ok = log.join() === 'hammer,transaction,clear,entity';
      return { ok, detail: `heard ${log.join(', ')}` };
    },
  ],
  [
    'after-hooks replace a return value',
    async () => {
      const r = await lua<{
        before: number;
        overridden: number;
        after: number;
      }>(`
        local path = "/Script/Engine.PlayerState:GetPingInMilliseconds"
        local ps = BR.player.server()
        local before = ps:GetPingInMilliseconds()
        local stop = BR.event.after(path, function(_, params) return BR.event.result(path, params, string.pack("<f", 123.5)) end)
        local overridden = ps:GetPingInMilliseconds()
        stop()
        return { before = before, overridden = overridden, after = ps:GetPingInMilliseconds() }`);
      return {
        ok: r.overridden === 123.5 && r.after === r.before,
        detail: `ping ${r.before}, while hooked ${r.overridden}, after ${r.after}`,
      };
    },
  ],
  [
    'a bot facing a seat; equip event',
    async () => {
      // a bot's character runs the client's interaction prompt near a seat; without
      // BR.bot's guard that crashed the server within seconds
      const [x, y] = [ox + 1800, oy];
      await lua(`
        local g = { log = {} }
        _G.ACC_SEAT = g
        g.ps = BR.bot.spawn("seat ${nonce}")
        local ch = BR.player.character(g.ps)
        BR.world.teleport(ch, ${x}, ${y}, 30)
        g.seat = BR.brick.place(BR.brick.builder({ asset = "B_Seat", owner = BR.player.owner_index() }), ${x} + 30, ${y}, 6)
        BR.bot.look_at(g.ps, { ${x} + 30, ${y}, 10 })
        g.stop = BR.event.on("equip", function(_, i) g.log[#g.log + 1] = tostring(i.item) end)
        BR.bot.give(g.ps, "Pistol")
        for _, e in ipairs(BR.player.inventory(ch)) do if e.item == "Weapon_Pistol_C" then g.slot = e.slot end end
        BR.timer.after(0.5, function() BR.bot.equip(g.ps, g.slot) end)`);
      await sleep(8_000);
      const r = await lua<{ log: string[]; alive: boolean }>(`
        local g = _G.ACC_SEAT
        g.stop()
        local r = { log = g.log, alive = BR.player.character(g.ps) ~= nil }
        BR.bot.remove(g.ps)
        if g.seat and BR.brick.valid(g.seat) then BR.brick.transaction(BR.player.server(), function(tx) tx.delete(BR.brick.id(g.seat)) end) end
        return r`);
      const ok = r.alive && r.log.join() === 'Weapon_Pistol_C';
      return {
        ok,
        detail: `server up after 8 s facing a seat; equip events ${JSON.stringify(r.log)}`,
      };
    },
  ],
  [
    'small helpers: async, config, chat filters, labels, world store, invoke, ready, NPCs',
    async () => {
      const [x, y] = [ox + 2100, oy];
      await lua(`
        local g = { async = "", chat = {} }
        _G.ACC_SMALL = g
        BR.timer.async(function() g.async = g.async .. "a" BR.timer.sleep(0.2) g.async = g.async .. "b" BR.timer.sleep(0.2) g.async = g.async .. "c" end)
        local cfg = BR.config.open("acc-${nonce}", { rounds = 5 })
        -- an admin's edit, after the defaults were written
        local f = io.open(cfg.path(), "wb") f:write('{"rounds": 9}') f:close()
        g.cfg_default = cfg.get("rounds")
        g.cfg_path = cfg.path()
        local ps = BR.bot.spawn("filters ${nonce}")
        local stop_c = BR.chat.censor({ "darn" })
        BR.act.say(ps, "oh darn it ${nonce}")
        stop_c()
        local stop_l = BR.chat.limit({ messages = 2, per = 10, mute = 5 })
        for i = 1, 4 do BR.act.say(ps, "line " .. i .. " ${nonce}") end
        stop_l()
        BR.bot.remove(ps)
        local l = BR.label.create({ ${x}, ${y}, 60 }, { text = "label ${nonce}" })
        g.label = BR.component.data(l.brick, "Component_TextDisplay").Text
        l:remove()
        g.world = BR.server.world()
        local s = BR.store.for_world("acc-${nonce}")
        s.set("k", 7)
        g.world_store = BR.store.load("world." .. g.world:gsub("[^%w_%-%.]", "_") .. ".acc-${nonce}").k
        BR.store.delete("world." .. g.world:gsub("[^%w_%-%.]", "_") .. ".acc-${nonce}")
        Omegga.handle("acc_double_${nonce}", function(n) return n * 2 end)
        Omegga.invoke("acc_double_${nonce}", { 21 }, function(ok, v) g.invoked = ok and v end)
        local stop_ready = BR.event.on_ready(function() g.ready = true end)
        BR.timer.after(1, stop_ready)
        local npcs = BR.npc.list()
        if #npcs > 0 then
          g.npc = { death = 0 }
          g.npc_stop = BR.npc.on_death(function() g.npc.death = g.npc.death + 1 end)
          BR.player.kill(npcs[1])
        else
          g.npc = "none in this world"
        end`);
      await sleep(2_500);
      const r = await lua<Record<string, unknown>>(`
        local g = _G.ACC_SMALL
        if g.npc_stop then g.npc_stop() end
        g.cfg_edited = BR.config.open("acc-${nonce}", { rounds = 5 }).get("rounds")
        os.remove(g.cfg_path)
        -- what went out: the server logs each chat line it sends
        local chat = {}
        for _, line in ipairs(BR.server.log_tail(20, "LogChat: filters ${nonce}: ")) do chat[#chat + 1] = line:match(": ([^:]*)$") end
        return { async = g.async, cfg_default = g.cfg_default, cfg_edited = g.cfg_edited, chat = chat, label = g.label,
          world = g.world, world_store = g.world_store, invoked = g.invoked, ready = g.ready, npc = g.npc }`);
      const chat = Array.isArray(r.chat) ? r.chat.map(String) : [];
      const npc = r.npc;
      const npcOk =
        npc === 'none in this world' ||
        (typeof npc === 'object' &&
          npc !== null &&
          'death' in npc &&
          npc.death === 1);
      const want: Record<string, unknown> = {
        async: 'abc',
        cfg_default: 5,
        cfg_edited: 9,
        label: `label ${nonce}`,
        world_store: 7,
        invoked: 42,
        ready: true,
      };
      const bad = Object.entries(want)
        .filter(([k, v]) => r[k] !== v)
        .map(
          ([k, v]) =>
            `${k} ${JSON.stringify(r[k])} (want ${JSON.stringify(v)})`,
        );
      // the censored line went out rewritten; the limit let 2 of 4 through
      if (!chat.some(c => c.includes('■■■')))
        bad.push(`censor: ${JSON.stringify(chat[0])}`);
      if (chat.filter(c => c.startsWith('line ')).length !== 2)
        bad.push(
          `limit let through ${JSON.stringify(chat.filter(c => c.startsWith('line ')))}`,
        );
      if (!npcOk) bad.push(`npc ${JSON.stringify(npc)}`);
      return {
        ok: bad.length === 0,
        detail: bad.length
          ? bad.join('; ')
          : `world ${r.world}; npc ${JSON.stringify(npc)}`,
      };
    },
  ],
  [
    'movers, patrol and follow',
    async () => {
      const [x, y] = [ox + 2400, oy];
      await lua(`
        local g = { arrived = {} }
        _G.ACC_MOVE = g
        g.e = BR.entity.spawn(BR.entity.class("Entity_Ball"), ${x}, ${y}, 300)
        BR.brick.transaction(BR.player.server(), function(tx) tx.physics(g.e, false) end)
        g.m = BR.mover.path(g.e, { { ${x}, ${y}, 300 }, { ${x} + 300, ${y}, 300 } }, { speed = 300, on_arrive = function(i) g.arrived[#g.arrived + 1] = i end })
        g.a, g.b = BR.bot.spawn("patrol ${nonce}"), BR.bot.spawn("follow ${nonce}")
        BR.world.teleport(BR.player.character(g.a), ${x}, ${y} + 500, 30)
        BR.world.teleport(BR.player.character(g.b), ${x}, ${y} + 900, 30)
        g.stop_patrol = BR.bot.patrol(g.a, { { ${x} + 400, ${y} + 500, 30 }, { ${x}, ${y} + 500, 30 } })
        g.stop_follow = BR.bot.follow(g.b, g.a, { distance = 120 })`);
      await sleep(3_000);
      const r = await lua<{
        ball: number;
        arrived: number[];
        gap: number;
      }>(`
        local g = _G.ACC_MOVE
        local pa, pb = BR.player.character(g.a):K2_GetActorLocation(), BR.player.character(g.b):K2_GetActorLocation()
        local r = { ball = g.e:K2_GetActorLocation().X - ${x}, arrived = g.arrived, gap = math.sqrt((pa.X - pb.X) ^ 2 + (pa.Y - pb.Y) ^ 2) }
        g.stop_patrol() g.stop_follow()
        BR.bot.remove(g.a) BR.bot.remove(g.b)
        BR.entity.delete(g.e)
        return r`);
      const ok =
        Math.abs(r.ball - 300) < 2 &&
        r.arrived.join() === '2' &&
        r.gap < 400;
      return {
        ok,
        detail: `ball moved ${Math.round(r.ball)} (arrived at ${r.arrived.join()}); follower ${Math.round(r.gap)} behind`,
      };
    },
  ],
  [
    'SQLite databases',
    async () => {
      await lua(`
        _G.ACC_DB = {}
        -- one database for every run; the plugin keeps it open, so it is emptied, not deleted
        local h = BR.db.open("acceptance")
        h.exec("drop table if exists kills; create table kills (killer text, victim text)")
        h.run("insert into kills values (?, ?)", { "Ann", "Bo" }, function(ok, r) _G.ACC_DB.insert = ok and r.changes end)
        h.run("insert into kills values (?, ?)", { "Ann", "Cy" })
        h.run("insert into kills values (?, ?)", { "Bo", "Ann" })
        h.query("select killer, count(*) as n from kills group by killer order by n desc", {}, function(ok, rows) _G.ACC_DB.rows = ok and rows or tostring(rows) end)
        h.query("select * from missing", {}, function(ok, err) _G.ACC_DB.error = not ok and err end)`);
      const r = await waitFor<{
        insert?: number;
        rows?: { killer: string; n: number }[] | string;
        error?: string;
      }>('return _G.ACC_DB', v => v.error !== undefined, 5_000);
      const top = Array.isArray(r.rows)
        ? r.rows.map(x => `${x.killer}:${x.n}`).join(',')
        : String(r.rows);
      const ok =
        r.insert === 1 &&
        top === 'Ann:2,Bo:1' &&
        r.error === 'no such table: missing';
      return {
        ok,
        detail: `insert changed ${r.insert}; top ${top}; bad query: ${r.error}`,
      };
    },
  ],
  [
    'guard signals: teleport, fly, build rate',
    async () => {
      const [x, y] = [ox + 900, oy];
      await lua(`
        _G.ACC_GUARD = { teleport = {}, fly = 0, build = 0 }
        local g = _G.ACC_GUARD
        local ps = BR.bot.spawn("guard ${nonce}")
        g.ps = ps
        BR.perm.set(ps, "BR.Permission.Fly", false)
        g.stops = {
          BR.guard.on("teleport", function(_, d) g.teleport[#g.teleport + 1] = math.floor(d) end, { bots = true }),
          BR.guard.on("fly", function() g.fly = g.fly + 1 end, { bots = true }),
          BR.guard.on("build_rate", function() g.build = g.build + 1 end, { bots = true }),
        }
        BR.world.teleport(BR.player.character(ps), ${x}, ${y}, 30)
        -- a move BR.world.teleport didn't make, past its one-second grace
        BR.timer.after(1.3, function()
          local c = BR.player.character(ps)
          c:K2_TeleportTo({ X = ${x} + 1500, Y = ${y}, Z = 30 }, c:K2_GetActorRotation())
        end)
        BR.timer.after(1.8, function() BR.player.character(ps).CharacterMovement:SetMovementMode(5, 0) end)
        BR.timer.after(2.3, function()
          for i = 1, 22 do BR.act.place(ps, { position = { ${x} + i * 20, ${y} + 300, 2000 }, size = { 5, 5, 5 } }) end
        end)`);
      const r = await waitFor<{
        teleport: number[];
        fly: number;
        build: number;
      }>(
        `local g = _G.ACC_GUARD return { teleport = g.teleport, fly = g.fly, build = g.build }`,
        v => v.build > 0,
        6_000,
      );
      await lua(`
        local g = _G.ACC_GUARD
        for _, stop in ipairs(g.stops) do stop() end
        BR.perm.clear(g.ps)
        BR.bot.remove(g.ps)
        local hs = BR.brick.in_box({ ${x}, ${y} + 250, 1950 }, { ${x} + 500, ${y} + 350, 2050 })
        BR.brick.transaction(BR.player.server(), function(tx) for _, h in ipairs(hs) do tx.delete(BR.brick.id(h)) end end)`);
      const ok =
        r.teleport.length === 1 &&
        (r.teleport[0] ?? 0) >= 1400 &&
        (r.teleport[0] ?? 0) < 1700 &&
        r.fly === 1 &&
        r.build === 1;
      return {
        ok,
        detail: `teleport ${JSON.stringify(r.teleport)}, fly ${r.fly}x, build rate ${r.build}x`,
      };
    },
  ],
  [
    'procedural generation',
    async () => {
      const [x, y] = [ox + 600, oy + 600];
      const r = await lua<{
        same: boolean;
        terrain: number;
        maze: number;
        open: number;
        taken: boolean;
        removed: number;
      }>(`
        local a, b = BR.gen.rng("${nonce}"), BR.gen.rng("${nonce}")
        local same = true
        for _ = 1, 50 do if a:next() ~= b:next() then same = false end end
        local terrain = BR.gen.terrain({ ${x}, ${y}, 0 }, { 6, 6 }, { seed = "${nonce}" })
        local maze, grid = BR.gen.maze({ ${x}, ${y} + 200, 0 }, { 4, 4 }, { seed = 1 })
        local open = 0
        for i = 1, #grid do for j = 1, #grid[1] do if not grid[i][j] then open = open + 1 end end end
        local r = { same = same, terrain = terrain.BricksPlaced, maze = maze.BricksPlaced, open = open,
          taken = not BR.gen.fits({ ${x}, ${y}, 0 }, { ${x} + 20, ${y} + 20, 10 }) }
        local hs = BR.brick.in_box({ ${x} - 1, ${y} - 1, -1 }, { ${x} + 400, ${y} + 400, 100 })
        r.removed = BR.brick.transaction(BR.player.server(), function(tx) for _, h in ipairs(hs) do tx.delete(BR.brick.id(h)) end end).BricksDeleted
        return r`);
      // a perfect maze of 4x4 cells has 16 cells and 15 passages open
      const ok =
        r.same &&
        r.terrain === 36 &&
        r.maze > 0 &&
        r.open === 31 &&
        r.taken &&
        r.removed === r.terrain + r.maze;
      return {
        ok,
        detail: `same seed same numbers ${r.same}; terrain ${r.terrain} columns; maze ${r.maze} bricks, ${r.open} open; area taken ${r.taken}; removed ${r.removed}`,
      };
    },
  ],
  [
    'cron schedules and store migrations',
    async () => {
      const r = await lua<{
        matches: boolean[];
        bad: boolean;
        migrated: string;
        file: number;
        newer: boolean;
      }>(`
        local t = { min = 30, hour = 20, day = 13, month = 11, wday = 6 }
        local m = BR.timer.cron_matches
        local r = { matches = { m("30 20 * * 5", t), m("*/15 * * * *", t), m("0-30/10 20-21 * 11 *", t), m("30 20 1 * 5", t),
          not m("0 * * * *", t), not m("30 20 1 * 1", t) } }
        r.bad = not pcall(m, "61 * * * *", t)
        local name = "acc-migrate-${nonce}"
        BR.store.save(name, { points = 5 })
        local s = BR.store.open(name, { version = 3, migrate = {
          [2] = function(d) d.scores = d.points d.points = nil end,
          [3] = function(d) return { wrapped = d } end } })
        r.migrated = require("omegga.json").encode(s.data)
        r.file = BR.store.load(name).__version
        r.newer = not pcall(BR.store.open, name, { version = 2 })
        return r`);
      const ok =
        r.matches.every(Boolean) &&
        r.bad &&
        r.migrated === '{"wrapped":{"scores":5}}' &&
        r.file === 3 &&
        r.newer;
      return {
        ok,
        detail: `cron ${r.matches.filter(Boolean).length}/6, bad field refused ${r.bad}; migrated ${r.migrated} at version ${r.file}; newer refused ${r.newer}`,
      };
    },
  ],
  [
    'item pickups: drop, gate, take',
    async () => {
      const r = await lua<{
        dropped: string;
        damage: number;
        emptied: boolean;
        refused: boolean;
        taken: string[];
        got: boolean;
        gone: boolean;
        spawned: string;
      }>(`
        local ps = BR.bot.spawn("pickups ${nonce}", { weapons = { "Pistol" } })
        local ch = BR.player.character(ps)
        local slot
        for _, e in ipairs(BR.player.inventory(ch)) do if e.item == "Weapon_Pistol_C" then slot = e.slot end end
        BR.player.tune(ch, slot, { damage = 2.5 })
        local p = BR.pickup.drop(ps, slot)
        local r = { dropped = p:GetClass():GetFName():ToString(), damage = p.DamageMultiplier,
          emptied = ch:GetCharacterInventoryEntry(slot).ItemInstance == nil or not ch:GetCharacterInventoryEntry(slot).ItemInstance:IsValid() }
        local deny = true
        local taken = {}
        local stops = {
          BR.pickup.gate(function(_, pk) if deny and __addr(pk) == __addr(p) then return false end end),
          BR.pickup.on(function(who, _, item) taken[#taken + 1] = tostring(item) end),
        }
        -- only a character its player controller holds takes pickups, as bot.spawn arms one
        local state = _G.BR_BOTS[__addr(ps)]
        _G.BR_BOTS[__addr(ps)] = nil
        BR.player.controller(ps):Possess(ch)
        p:HandlePickupAttempt(ch)
        r.refused = p:IsPickupEnabled() and #taken == 0
        deny = false
        local key = __addr(p)
        p:HandlePickupAttempt(ch)
        r.taken = taken
        r.got = false
        for _, e in ipairs(BR.player.inventory(ch)) do if e.item == "Weapon_Pistol_C" then r.got = true end end
        r.gone = true
        for _, x in ipairs(BR.pickup.list()) do if __addr(x) == key then r.gone = false end end
        local s = BR.pickup.spawn("Ammo_Light", { ${ox + 400}, ${oy}, 30 }, { respawn = 0 })
        r.spawned = s:GetClass():GetFName():ToString()
        s:K2_DestroyActor()
        for _, stop in ipairs(stops) do stop() end
        -- back to its AI controller in this same call: a character a player
        -- controller holds counts as a local player's for a tick, builds the
        -- client's interaction prompt widget, and a later tick then runs its
        -- UI code on the server and crashes it
        state.ai:Possess(ch)
        _G.BR_BOTS[__addr(ps)] = state
        BR.bot.remove(ps)
        return r`);
      const ok =
        r.dropped === 'BP_ItemPickup_Pistol_C' &&
        r.damage === 2.5 &&
        r.emptied &&
        r.refused &&
        r.taken.join() === 'Weapon_Pistol_C' &&
        r.got &&
        r.gone &&
        r.spawned === 'BP_Pickup_Ammo_Light_C';
      return {
        ok,
        detail: `dropped ${r.dropped} (damage ${r.damage}, slot emptied ${r.emptied}); refused ${r.refused}; taken ${r.taken.join()}; got it ${r.got}; pickup gone ${r.gone}; spawned ${r.spawned}`,
      };
    },
  ],
  [
    'inventory slots and the template',
    async () => {
      const r = await lua<{
        slots: string[];
        template: string;
        prefab: string;
      }>(`
        local ps = BR.bot.spawn("inventory ${nonce}")
        local ch = BR.player.character(ps)
        local function desc(e)
          local p = e.Placeable
          if p.Type == 1 then return "brick " .. p.BrickType.BrickAsset:GetFName():ToString() end
          if p.Type == 2 then return "entity " .. p.EntityType:GetFName():ToString() end
          if p.Type == 3 then return "prefab" end
          local it = e.ItemInstance
          if it and it:IsValid() then return "item " .. it:GetClass():GetFName():ToString() end
          return "type " .. p.Type
        end
        BR.prefab.set_slot(ps, 7, { brick = "B_1x1_Round" })
        BR.prefab.set_slot(ps, 8, { entity = "Entity_Ball" })
        BR.prefab.set_slot(ps, 9, { item = "Weapon_Pistol" })
        BR.prefab.set_template(ps, { brick = "PB_DefaultBrick", size = { 10, 10, 2 } })
        local r = { slots = { desc(ch:GetCharacterInventoryEntry(7)), desc(ch:GetCharacterInventoryEntry(8)), desc(ch:GetCharacterInventoryEntry(9)) },
          template = desc(ch:GetCharacterTempInventoryEntry()) }
        -- any prefab the server has cached (the world's own, at least)
        local cached = BR.prefab.cached()[1]
        if cached then
          BR.prefab.set_slot(ps, 6, { prefab = cached.hash })
          r.prefab = desc(ch:GetCharacterInventoryEntry(6))
        else
          r.prefab = "none cached"
        end
        BR.bot.remove(ps)
        return r`);
      const ok =
        r.slots.join() ===
          'brick B_1x1_Round,entity Entity_Ball,item Weapon_Pistol_C' &&
        r.template === 'brick PB_DefaultBrick' &&
        (r.prefab === 'prefab' || r.prefab === 'none cached');
      return {
        ok,
        detail: `slots ${r.slots.join(', ')}; template ${r.template}; prefab slot ${r.prefab}`,
      };
    },
  ],
  [
    'watchdog and dialogs',
    async () => {
      await lua(`
        _G.ACCEPTANCE_WD = { prev = BR.server.watchdog(300) }
        BR.timer.after(0.05, function() while true do end end)
        BR.timer.after(0.5, function() _G.ACCEPTANCE_WD.after = true end)
        -- a dialog answered on a bot's controller, as a client answers
        local b = BR.bot.spawn("asker ${nonce}")
        _G.ACCEPTANCE_WD.bot = b
        local real = BR.player.connected
        BR.player.connected = function() return true end
        local ok, id = pcall(BR.ui.ask, b, { title = "acc", kind = "text" }, function(yes, text) _G.ACCEPTANCE_WD.answer = { yes, text } end)
        BR.player.connected = real
        assert(ok, id)
        BR.player.controller(b):ServerWireMessageBoxAnswered(id, true, "answer ${nonce}")`);
      const r = await waitFor<{ after?: boolean; answer?: [boolean, string] }>(
        'local w = _G.ACCEPTANCE_WD return { after = w.after, answer = w.answer }',
        v => v.after === true,
        3000,
      );
      await lua(
        'BR.server.watchdog(_G.ACCEPTANCE_WD.prev) BR.bot.remove(_G.ACCEPTANCE_WD.bot)',
      );
      const ok =
        r.after === true &&
        r.answer?.[0] === true &&
        r.answer?.[1] === `answer ${nonce}`;
      return {
        ok,
        detail: `endless loop stopped, later timer ran ${r.after}; dialog answer ${JSON.stringify(r.answer)}`,
      };
    },
  ],
  [
    'sounds and chat channels',
    async () => {
      const r = await lua<{
        sounds: number;
        played: boolean;
        formatted: string;
      }>(`
        local played = pcall(BR.sound.play, "all", "OBA_Deathmatch_Round_Start") and pcall(BR.sound.at, { 0, 0, 100 }, "OSA_GrenadeLauncher_Fire", { volume = 0.2 })
        local b = BR.bot.spawn("router ${nonce}")
        _G.ACCEPTANCE_ROUTE = { bot = b, stop = BR.chat.route(function(_, m) if m:find("routed") then return {} end end) }
        return { sounds = #BR.sound.list(), played = played, formatted = BR.chat.format("**b** :heart:") }`);
      // a bot's chat in the tick it spawned isn't handled yet
      await sleep(500);
      await lua(`
        BR.act.say(_G.ACCEPTANCE_ROUTE.bot, "routed ${nonce}")
        BR.act.say(_G.ACCEPTANCE_ROUTE.bot, "public ${nonce}")`);
      await sleep(300);
      const lines = await lua<string[]>(`
        local a = _G.ACCEPTANCE_ROUTE
        a.stop()
        BR.bot.remove(a.bot)
        local out = {}
        for _, l in ipairs(BR.server.log_tail(20, "${nonce}")) do if l:find("LogChat: router") then out[#out + 1] = l:match("router ${nonce}: (.*)$") end end
        return out`);
      const said = Array.isArray(lines) ? lines.filter(l => l) : [];
      const ok =
        r.sounds > 100 &&
        r.played &&
        r.formatted === '<b>b</> <emoji>heart</>' &&
        said.join() === `public ${nonce}`;
      return {
        ok,
        detail: `${r.sounds} sounds, played ${r.played}; format ${r.formatted}; reached the game's chat: ${said.join(', ') || 'none'}`,
      };
    },
  ],
  [
    'status effects',
    async () => {
      await lua(`
        local b = BR.bot.spawn("effects ${nonce}")
        local ch = BR.player.character(b)
        BR.player.set_health(ch, 100)
        _G.ACCEPTANCE_FX = { bot = b }
        BR.effect.apply(b, "poison", { duration = 1, strength = 40 })
        BR.effect.apply(b, "poison", { duration = 1, strength = 40 })
        BR.effect.apply(b, "size", { duration = 1, strength = 2 })
        _G.ACCEPTANCE_FX.stacks = BR.effect.of(b).poison.stacks
        _G.ACCEPTANCE_FX.scale = ch.CharacterScale`);
      await sleep(1600);
      const r = await lua<{
        stacks: number;
        scale: number;
        hp: number;
        scale_after: number;
        left: number;
      }>(`
        local f = _G.ACCEPTANCE_FX
        local ch = BR.player.character(f.bot)
        local n = 0
        for _ in pairs(BR.effect.of(f.bot)) do n = n + 1 end
        local r = { stacks = f.stacks, scale = f.scale, hp = BR.player.health(ch), scale_after = ch.CharacterScale, left = n }
        BR.bot.remove(f.bot)
        return r`);
      const ok =
        r.stacks === 2 &&
        r.scale === 2 &&
        r.hp < 90 &&
        r.scale_after === 1 &&
        r.left === 0;
      return {
        ok,
        detail: `poison x${r.stacks} left ${Math.round(r.hp)} health; size ${r.scale} -> ${r.scale_after}; ${r.left} effects left`,
      };
    },
  ],
  [
    'shared state',
    async () => {
      const r = await lua<{ seen: string[]; any: number }>(`
        local key = "acc.${nonce}"
        local seen, any = {}, 0
        local stop = BR.state.watch(key, function(v, old) seen[#seen + 1] = tostring(old) .. ">" .. tostring(v) end)
        local stop2 = BR.state.watch("*", function(_, _, k) if k == key then any = any + 1 end end)
        BR.state.set(key, 1)
        BR.state.set(key, 1)
        BR.state.set(key, 2)
        BR.state.set(key, nil)
        stop() stop2()
        return { seen = seen, any = any }`);
      const ok = r.seen.join() === 'nil>1,1>2,2>nil' && r.any === 3;
      return { ok, detail: `${r.seen.join(' ')}; any-key watcher ${r.any}` };
    },
  ],
  [
    'transaction actions',
    async () => {
      const [x, y] = [ox + 400, oy + 320];
      const r = await lua<{
        placed: number;
        ms: number;
        edit: Record<string, number>;
        moved: boolean;
        hidden: boolean;
        deleted: number;
        refused: boolean;
      }>(`
        local ps = BR.player.server()
        local ok, r = pcall(function()
          local b = BR.brick.builder({ size = { 5, 5, 5 }, owner = BR.player.owner_index() })
          local ids = {}
          local t0 = os.clock()
          local placed = BR.brick.transaction(ps, function(tx)
            for i = 0, 19 do ids[#ids + 1] = tx.place(b, { ${x} + i * 20, ${y}, 2000 }) end
          end)
          local ms = (os.clock() - t0) * 1000
          local edit = BR.brick.transaction(ps, function(tx)
            tx.move(ids[1], { ${x}, ${y} + 40, 2000 })
            tx.resize(ids[2], { 5, 5, 10 }, { ${x} + 20, ${y}, 2005 })
            tx.color(ids[3], { 255, 0, 0 })
            tx.color(ids[4], { 0, 0, 255 }, "Glow", 8)
            tx.material(ids[5], "Metal")
            tx.collision(ids[6], false)
            tx.visible(ids[7], false)
          end)
          local moved, hidden = false, false
          for _, h in ipairs(BR.brick.in_box({ ${x} - 10, ${y} - 10, 1980 }, { ${x} + 400, ${y} + 50, 2030 })) do
            local id = BR.brick.id(h)
            if id == ids[1] then moved = BR.brick.info(h).position[2] == ${y} + 40 end
            if id == ids[7] then hidden = not BR.brick.visible(h) end
          end
          local deleted = BR.brick.transaction(ps, function(tx) for _, id in ipairs(ids) do tx.delete(id) end end)
          local refused = not pcall(BR.brick.transaction, ps, function(tx) tx.color(ids[1], { 0, 0, 0 }, nil, 3) end)
          return { placed = placed.BricksPlaced, ms = ms, edit = BR.brick.changes(edit), moved = moved, hidden = hidden, deleted = deleted.BricksDeleted, refused = refused }
        end)
        assert(ok, r)
        return r`);
      const ok =
        r.placed === 20 &&
        r.edit.BricksChanged === 7 &&
        r.moved &&
        r.hidden &&
        r.deleted === 20 &&
        r.refused;
      return {
        ok,
        detail: `placed ${r.placed} in one transaction in ${r.ms.toFixed(1)} ms; edits ${JSON.stringify(r.edit)}; moved ${r.moved}, hidden ${r.hidden}; deleted ${r.deleted}; alpha without material refused ${r.refused}`,
      };
    },
  ],
  [
    'teams, game-wide rules and a round',
    async () => {
      const name = `acc team ${nonce}`;
      const r = await lua<{
        same: boolean;
        color: number[];
        team: number[];
        world: number[];
        gone: boolean;
        round: number;
      }>(`
        local t = BR.team.create("${name}", { color = { 200, 120, 0 }, respawn_time = 2 })
        local r = { same = __addr(BR.team.create("${name}")) == __addr(t), color = BR.team.info(t).color }
        local ps = BR.bot.spawn("teams ${nonce}")
        local ch = BR.player.character(ps)
        BR.team.join(ps, BR.team.info(t).id, false)
        local base = ch.CharacterMovement:GetMaxSpeed()
        BR.team.rule(t, "EnhancedBrickadians"):SetWalkSpeedMultiplier(2)
        r.team = { base, ch.CharacterMovement:GetMaxSpeed() }
        BR.team.join(ps, -1, false)
        BR.world.rule("EnhancedBrickadians"):SetWalkSpeedMultiplier(1.5)
        r.world = { ch.CharacterMovement:GetMaxSpeed() }
        BR.world.remove_rule("EnhancedBrickadians")
        r.world[2] = ch.CharacterMovement:GetMaxSpeed()
        BR.team.delete(t)
        r.gone = BR.team.find("${name}") == nil
        BR.bot.remove(ps)
        r.round = BR.world.round()
        _G.ACCEPTANCE_ROUND = {}
        _G.ACCEPTANCE_ROUND.stop = BR.event.on("round_won", function(_, info) _G.ACCEPTANCE_ROUND.result = info.result end)
        _G.ACCEPTANCE_ROUND.stop_start = BR.event.on("round_start", function() _G.ACCEPTANCE_ROUND.next = true end)
        BR.world.draw()
        return r`);
      const result = await waitFor<string | null>(
        'return _G.ACCEPTANCE_ROUND.result',
        v => v === 'draw',
        5000,
      );
      // the next round starts a few seconds after a draw and respawns everyone, which
      // would land in the middle of a later check
      const next = await waitFor<boolean | null>(
        'return _G.ACCEPTANCE_ROUND.next',
        v => v === true,
        15_000,
      );
      await lua('_G.ACCEPTANCE_ROUND.stop() _G.ACCEPTANCE_ROUND.stop_start()');
      await sleep(1000);
      const ok =
        r.same &&
        r.color.join() === '200,120,0,255' &&
        Math.abs(r.team[1] - 2 * r.team[0]) < 1 &&
        Math.abs(r.world[0] - 1.5 * r.team[0]) < 1 &&
        Math.abs(r.world[1] - r.team[0]) < 1 &&
        r.gone &&
        result === 'draw' &&
        next === true;
      return {
        ok,
        detail: `team created once, color ${r.color.join(',')}; team rule ${r.team.join(' -> ')}; game-wide ${r.team[0]} -> ${r.world.join(' -> ')}; deleted ${r.gone}; round ${r.round} draw reported as ${result}`,
      };
    },
  ],
  [
    'explosions and rounds',
    async () => {
      const r = await lua<{
        boom: boolean;
        kinds: number;
        round: number;
        running: boolean;
      }>(`
        return { boom = BR.world.explode({ ${ox}, ${oy}, 30000 }, { damage = 0 }), kinds = #BR.world.explosion_kinds(), round = BR.world.round(), running = BR.world.session_running() }`);
      const ok = r.boom && r.kinds > 10 && r.round >= 1;
      return {
        ok,
        detail: `explosion went off ${r.boom}, ${r.kinds} kinds; round ${r.round}, session running ${r.running}`,
      };
    },
  ],
  [
    'bot wires two gates',
    async () => {
      const [x, y] = [ox + 40, oy + 280];
      const r = await lua<Record<string, Record<string, number>>>(`
        local ps = _G.ACCEPTANCE_BOT
        BR.act.place(ps, { position = { ${x}, ${y}, 2 }, asset = "B_1x1_Gate_Expr_LogicalNOT" })
        BR.act.place(ps, { position = { ${x + 40}, ${y}, 2 }, asset = "B_1x1_Gate_Expr_LogicalAND" })
        local function at(px) return assert(BR.world.raycast({ px, ${y}, 200 }, { 0, 0, -1 }).brick, "no gate at " .. px) end
        local from = { brick = at(${x}), type = "BrickComponentType_Expr_LogicalNOT", port = "bOutput" }
        local to = { brick = at(${x + 40}), type = "${AND}", port = "bInputA" }
        return { wire = BR.brick.changes(BR.act.wire(ps, from, to)), unwire = BR.brick.changes(BR.act.wire(ps, from, to)) }`);
      const ok =
        r.wire.WiresConnected === 1 && r.unwire.WiresDisconnected === 1;
      return {
        ok,
        detail: `connected ${r.wire.WiresConnected}, then disconnected ${r.unwire.WiresDisconnected}`,
      };
    },
  ],
  [
    'bot hammers its bricks',
    async () => {
      const r = await lua<number[]>(`
        local ps = _G.ACCEPTANCE_BOT
        local deleted = {}
        for _, px in ipairs({ ${ox}, ${ox + 40}, ${ox + 80} }) do
          local hit = BR.world.raycast({ px, ${oy + 280}, 200 }, { 0, 0, -1 })
          deleted[#deleted + 1] = hit and hit.brick and BR.act.hammer(ps, hit.brick).BricksDeleted or 0
        end
        return deleted`);
      return { ok: r.every(n => n === 1), detail: `deleted ${r.join(', ')}` };
    },
  ],
  [
    'bot emotes',
    async () => {
      const r = await lua<string[]>(`
        BR.act.emote(_G.ACCEPTANCE_BOT, BR.act.EMOTE.Wave)
        local active = {}
        BR.player.character(_G.ACCEPTANCE_BOT).ActiveEmotes:ForEach(function(_, e) active[#active + 1] = e:get():GetFName():ToString() end)
        return active`);
      return {
        ok: r.includes('BP_Emote_Wave_C'),
        detail: `active: ${r.join(', ') || 'none'}`,
      };
    },
  ],
  [
    'bot walks to a point',
    async () => {
      const start = await lua<number[]>(`
        local ps = _G.ACCEPTANCE_BOT
        BR.act.stop_emote(ps)
        local v = BR.player.character(ps):K2_GetActorLocation()
        _G.ACCEPTANCE_ARRIVED = false
        BR.bot.move_to(ps, { v.X + 300, v.Y + 200, v.Z }, { on_arrive = function() _G.ACCEPTANCE_ARRIVED = true end })
        return { v.X, v.Y }`);
      // `=== true`: bridges before 0.3.0 hand a lone false back as [false]
      const arrived =
        (await waitFor<boolean>(
          'return _G.ACCEPTANCE_ARRIVED',
          v => v === true,
          10_000,
        )) === true;
      const end = await lua<number[]>(
        'local v = BR.player.character(_G.ACCEPTANCE_BOT):K2_GetActorLocation() return { v.X, v.Y }',
      );
      const off = Math.hypot(
        end[0] - (start[0] + 300),
        end[1] - (start[1] + 200),
      );
      return {
        ok: arrived && off <= 40,
        detail: `[${start.map(Math.round)}] -> [${end.map(Math.round)}], ${Math.round(off)} from the target`,
      };
    },
  ],
  [
    'bot jumps',
    async () => {
      await lua(`
        local ch = BR.player.character(_G.ACCEPTANCE_BOT)
        _G.ACCEPTANCE_Z0 = ch:K2_GetActorLocation().Z
        _G.ACCEPTANCE_ZMAX = _G.ACCEPTANCE_Z0
        _G.ACCEPTANCE_ZWATCH = BR.event.tick(function()
          local c = BR.player.character(_G.ACCEPTANCE_BOT)
          if c then _G.ACCEPTANCE_ZMAX = math.max(_G.ACCEPTANCE_ZMAX, c:K2_GetActorLocation().Z) end
        end)
        BR.bot.jump(_G.ACCEPTANCE_BOT)`);
      await sleep(1500);
      const rise = await lua<number>(
        '_G.ACCEPTANCE_ZWATCH() return _G.ACCEPTANCE_ZMAX - _G.ACCEPTANCE_Z0',
      );
      return { ok: rise > 30, detail: `rose ${Math.round(rise)} units` };
    },
  ],
  [
    'movement events: walk, sprint, crouch, sit',
    async () => {
      await lua(`
        local ps = _G.ACCEPTANCE_BOT
        _G.ACCEPTANCE_MOVES = {}
        local function rec(name) return function(p, active)
          if p and __addr(p) == __addr(ps) then table.insert(_G.ACCEPTANCE_MOVES, name .. (active and "+" or "-")) end
        end end
        _G.ACCEPTANCE_MOVE_STOPS = { BR.event.on_walk(rec("walk")), BR.event.on_sprint(rec("sprint")),
          BR.event.on_crouch(rec("crouch")), BR.event.on_sit(rec("sit")) }
        -- west of the spawn: open ground, away from what earlier checks leave behind
        BR.bot.move(ps, -1, 0)`);
      // each step outlasts a poll (0.1 s) and the walk's acceleration
      const steps = [
        'BR.bot.sprint(_G.ACCEPTANCE_BOT, true)',
        'BR.bot.sprint(_G.ACCEPTANCE_BOT, false)',
        'BR.bot.crouch(_G.ACCEPTANCE_BOT, true)',
        'BR.bot.crouch(_G.ACCEPTANCE_BOT, false) BR.bot.stop(_G.ACCEPTANCE_BOT) BR.player.character(_G.ACCEPTANCE_BOT).CharacterMovement:StopMovementImmediately()',
        'BR.act.emote(_G.ACCEPTANCE_BOT, BR.act.EMOTE.Sit)',
        'BR.act.stop_emote(_G.ACCEPTANCE_BOT)',
      ];
      // how the bot moved before each step, to tell a missed event from a bot that didn't move
      const states: string[] = [];
      for (const step of steps) {
        await sleep(500);
        states.push(
          await lua<string>(`
            local m = BR.player.movement(BR.player.character(_G.ACCEPTANCE_BOT))
            return string.format("%s %.0f", m.mode, m.speed)`),
        );
        await lua(step);
      }
      await sleep(500);
      const seen = await lua<string[]>(`
        for _, stop in ipairs(_G.ACCEPTANCE_MOVE_STOPS) do stop() end
        return _G.ACCEPTANCE_MOVES`);
      const want = [
        'walk+',
        'walk-',
        'sprint+',
        'sprint-',
        'walk+',
        'walk-',
        'crouch+',
        'crouch-',
        'sit+',
        'sit-',
      ];
      const ok = seen.join(' ') === want.join(' ');
      return {
        ok,
        detail: `${seen.join(' ') || 'none'}${ok ? '' : ` (bot before each step: ${states.join(', ')})`}`,
      };
    },
  ],
  [
    'zone and water events',
    async () => {
      await lua(`
        local ps = _G.ACCEPTANCE_BOT
        local v = BR.player.character(ps):K2_GetActorLocation()
        -- a water zone 150 units west of the bot, 200 tall
        local x, y = math.floor(v.X / 10) * 10 - 150, math.floor(v.Y / 10) * 10
        local zone = assert(BR.brick.place(BR.brick.builder({ asset = "BP_ZoneProjector", size = { 20, 20, 2 } }), x, y, 2), "refused")
        BR.component.set(zone, BR.zone.COMPONENT, { ZoneEndDistance = 200, bWater = true })
        _G.ACCEPTANCE_ZONE = { zone = zone, x = x, y = y }
        _G.ACCEPTANCE_ZONE_EVENTS = {}
        local function rec(name) return function(p, active)
          if p and __addr(p) == __addr(ps) then table.insert(_G.ACCEPTANCE_ZONE_EVENTS, name .. (active and "+" or "-")) end
        end end
        _G.ACCEPTANCE_ZONE_STOPS = { BR.event.on_zone(zone, rec("zone")), BR.event.on_water(rec("water")) }`);
      const move = (dx: number) =>
        lua(`
          local z, ch = _G.ACCEPTANCE_ZONE, BR.player.character(_G.ACCEPTANCE_BOT)
          ch:K2_SetActorLocation({ X = z.x + ${dx}, Y = z.y, Z = 40 }, false, {}, true)
          ch.CharacterMovement:StopMovementImmediately()`);
      // the game's own count and ours, and the events so far, after each move
      const look = () =>
        lua<{ game: number; ours: number; events: string[] }>(`
          local z = _G.ACCEPTANCE_ZONE.zone
          local events = {}
          for _, e in ipairs(_G.ACCEPTANCE_ZONE_EVENTS) do events[#events + 1] = e end
          table.sort(events)
          _G.ACCEPTANCE_ZONE_EVENTS = {}
          return { game = BR.component.get(z, BR.zone.COMPONENT, "OccupantCount"), ours = #BR.zone.occupants(z), events = events }`);
      await move(0);
      await sleep(600);
      const inside = await look();
      await move(200);
      await sleep(600);
      const outside = await look();
      const removed = await lua<number>(`
        for _, stop in ipairs(_G.ACCEPTANCE_ZONE_STOPS) do stop() end
        return BR.act.hammer(_G.ACCEPTANCE_BOT, _G.ACCEPTANCE_ZONE.zone).BricksDeleted`);
      const ok =
        inside.events.join(' ') === 'water+ zone+' &&
        inside.game === 1 &&
        inside.ours === 1 &&
        outside.events.join(' ') === 'water- zone-' &&
        outside.game === 0 &&
        outside.ours === 0;
      return {
        ok,
        detail: `in: ${inside.events.join(' ') || 'none'} (game ${inside.game}, ours ${inside.ours}); out: ${outside.events.join(' ') || 'none'} (game ${outside.game}, ours ${outside.ours}); removed ${removed === 1}`,
      };
    },
  ],
  [
    'bot flips a switch',
    async () => {
      const r = await lua<{
        before: boolean;
        after: boolean;
        deleted: number;
      }>(`
        local ps = _G.ACCEPTANCE_BOT
        local v = BR.player.character(ps):K2_GetActorLocation()
        local x, y = math.floor(v.X / 10) * 10 + 60, math.floor(v.Y / 10) * 10
        BR.act.place(ps, { position = { x, y, 6 }, asset = "B_Switch_Test" })
        local switch = assert(BR.world.raycast({ x, y, 300 }, { 0, 0, -1 }).brick, "no switch placed")
        local S = "Component_Internal_AnimatedSwitch"
        local before = BR.component.get(switch, S, "bEnabled")
        BR.act.interact(ps, switch)
        BR.act.stop_interact(ps)
        local after = BR.component.get(switch, S, "bEnabled")
        return { before = before, after = after, deleted = BR.act.hammer(ps, switch).BricksDeleted }`);
      return {
        ok: r.before !== r.after,
        detail: `bEnabled ${r.before} -> ${r.after}, switch removed: ${r.deleted === 1}`,
      };
    },
  ],
  [
    'bot finds a path around a wall',
    async () => {
      const [x, y] = [ox, oy + 360];
      // the wall goes up a tick before the walk: a brick has no collision in the tick it is placed
      await lua(`
        BR.act.place(_G.ACCEPTANCE_BOT, { position = { ${x + 100}, ${y}, 30 }, size = { 5, 60, 30 } })
        BR.world.teleport(BR.player.character(_G.ACCEPTANCE_BOT), ${x}, ${y}, 25)`);
      await sleep(500);
      const straight = await lua<boolean>(`
        _G.ACCEPTANCE_PATHED = "walking"
        BR.bot.path_to(_G.ACCEPTANCE_BOT, { ${x + 200}, ${y}, 25 }, {
          on_arrive = function() _G.ACCEPTANCE_PATHED = "arrived" end,
          on_fail = function() _G.ACCEPTANCE_PATHED = "failed" end })
        return BR.nav.clear({ ${x}, ${y}, 25 }, { ${x + 200}, ${y}, 25 })`);
      const result = await waitFor<string>(
        'return _G.ACCEPTANCE_PATHED',
        v => v !== 'walking',
        15_000,
      );
      const end = await lua<number[]>(`
        local wall = BR.world.raycast({ ${x + 100}, ${y}, 200 }, { 0, 0, -1 })
        if wall and wall.brick then BR.act.hammer(_G.ACCEPTANCE_BOT, wall.brick) end
        local v = BR.player.character(_G.ACCEPTANCE_BOT):K2_GetActorLocation()
        return { v.X, v.Y }`);
      const off = Math.hypot(end[0] - (x + 200), end[1] - y);
      return {
        ok: straight !== true && result === 'arrived' && off <= 40,
        detail: `straight line blocked: ${straight !== true}, ${result} ${Math.round(off)} from the target`,
      };
    },
  ],
  [
    'bake a nav graph and route over it',
    async () => {
      const [x, y] = [ox, oy + 360];
      await lua(
        `BR.act.place(_G.ACCEPTANCE_BOT, { position = { ${x + 100}, ${y}, 30 }, size = { 5, 60, 30 } })`,
      );
      await sleep(500);
      await lua(`_G.ACCEPTANCE_BAKED = nil
        BR.nav.bake({ ${x + 100}, ${y}, 25 }, { radius = 160, done = function(n) _G.ACCEPTANCE_BAKED = n end })`);
      const baked = await waitFor<number | null>(
        'return _G.ACCEPTANCE_BAKED',
        n => typeof n === 'number',
        20_000,
      );
      const r = await lua<{
        open: number[][] | null;
        closed: number[][] | null;
      }>(`
        BR.nav.graph(true)
        local from, to = { ${x}, ${y}, 25 }, { ${x + 200}, ${y}, 25 }
        local open = BR.nav.route(from, to)
        -- close every edge out of the open route's middle node, as a circuit would
        local mid = open and open[math.max(2, #open // 2)]
        local handle
        for _, n in ipairs(BR.nav.graph().nodes) do if mid and n.x == mid[1] and n.y == mid[2] then handle = n.handle end end
        if handle then
          local costs = BR.var.read_array(handle)
          for i = 1, #BR.nav.GRAPH_DIRECTIONS do costs[i] = 0 end
          BR.var.write_array(handle, costs)
        end
        local closed = BR.nav.route(from, to)
        local function xy(p) if not p then return nil end local t = {} for _, q in ipairs(p) do t[#t + 1] = { math.floor(q[1]), math.floor(q[2]) } end return t end
        return { open = xy(open), closed = xy(closed) }`);
      await lua(`
        local wall = BR.world.raycast({ ${x + 100}, ${y}, 200 }, { 0, 0, -1 })
        if wall and wall.brick then BR.act.hammer(_G.ACCEPTANCE_BOT, wall.brick) end
        BR.nav.unbake({ ${x + 100}, ${y} }, 200)`);
      // the open route must go around the wall's end, not through it
      const around =
        r.open !== null &&
        r.open.every(
          ([px, py]) => Math.abs(px - (x + 100)) > 20 || Math.abs(py - y) > 60,
        );
      const rerouted =
        r.closed !== null &&
        JSON.stringify(r.closed) !== JSON.stringify(r.open);
      return {
        ok: (baked ?? 0) > 0 && around && rerouted,
        detail: `${baked} nodes, route ${r.open?.length ?? 'none'} points, after closing a node ${r.closed ? `${r.closed.length} points, different: ${rerouted}` : 'no route'}`,
      };
    },
  ],
  [
    'hook an interaction',
    async () => {
      const r = await lua<{ hit: number[] | null; nearby: boolean }>(`
        local button = assert(BR.brick.place(BR.brick.builder({ asset = "B_Button", owner = BR.player.owner_index() }), ${ox + 320}, ${oy}, 6), "refused")
        if not _G.ACCEPTANCE_HOOKED then
          _G.ACCEPTANCE_HOOKED = true
          BR.event.interact(function(ch, brick, nearby) _G.ACCEPTANCE_SEEN = { brick = BR.brick.info(brick).position, nearby = nearby } end)
        end
        _G.ACCEPTANCE_SEEN = nil
        BR.act.interact(_G.ACCEPTANCE_BOT, button)
        BR.act.stop_interact(_G.ACCEPTANCE_BOT)
        local s = _G.ACCEPTANCE_SEEN
        return { hit = s and s.brick or nil, nearby = s and s.nearby or false }`);
      const ok = r.hit != null && r.hit[0] === ox + 320 && r.hit[1] === oy;
      return {
        ok,
        detail: r.hit
          ? `hook saw the button at [${r.hit}]`
          : 'hook did not fire',
      };
    },
  ],
  [
    'attach an entity to a bot',
    async () => {
      const before = await lua<number[]>(`
        local ps = _G.ACCEPTANCE_BOT
        local cls = StaticFindObject("/Script/Brickadia.Default__BRLuauWorldLibrary"):FindEntityType("Entity_Ball", BR.world.context())
        local v = BR.player.character(ps):K2_GetActorLocation()
        _G.ACCEPTANCE_BALL = BR.entity.spawn(cls, v.X, v.Y, v.Z + 200)
        BR.entity.attach(_G.ACCEPTANCE_BALL, ps, { socket = "Part_Head", offset = { 0, 0, 20 } })
        BR.bot.move(ps, 0, 1)
        return { v.X, v.Y }`);
      await sleep(1500);
      const r = await lua<{
        moved: number;
        offset: number[];
        parent: boolean;
      }>(`
        local ps = _G.ACCEPTANCE_BOT
        BR.bot.stop(ps)
        local ch = BR.player.character(ps)
        local c, b = ch:K2_GetActorLocation(), _G.ACCEPTANCE_BALL:K2_GetActorLocation()
        local head = ch.Mesh:GetSocketLocation(FName("Part_Head"))
        local parent = BR.entity.attached_to(_G.ACCEPTANCE_BALL) ~= nil
        BR.entity.detach(_G.ACCEPTANCE_BALL)
        BR.entity.delete(_G.ACCEPTANCE_BALL)
        return { moved = math.sqrt((c.X - ${before[0]}) ^ 2 + (c.Y - ${before[1]}) ^ 2), offset = { b.X - head.X, b.Y - head.Y, b.Z - head.Z }, parent = parent }`);
      const held = Math.hypot(r.offset[0], r.offset[1], r.offset[2] - 20) < 3;
      return {
        ok: r.parent && r.moved > 100 && held,
        detail: `bot walked ${Math.round(r.moved)}, ball at [${r.offset.map(n => Math.round(n))}] from its head`,
      };
    },
  ],
  [
    'bot shoots another bot',
    async () => {
      const setup = await lua<{ teams: number[] } | string>(`
        -- two teams whose settings allow weapon damage
        local gs = FindFirstOf("BRGameStateBase")
        local ids = {}
        for _, team in ipairs(FindAllOf("BRGameModeTeam") or {}) do
          if team:IsValid() and team.Settings.bWeaponDamageMode then ids[#ids + 1] = gs:GetTeamId(team) end
        end
        if #ids < 2 then return "this game mode has fewer than two teams with weapon damage" end
        local shooter = BR.bot.spawn("shooter ${nonce}", { team = ids[1], weapons = { "Pistol" } })
        local target = BR.bot.spawn("target ${nonce}", { team = ids[2], respawn_after = false })
        _G.ACCEPTANCE_SHOOTER, _G.ACCEPTANCE_TARGET = shooter, target
        for _, e in ipairs(BR.player.inventory(BR.player.character(shooter))) do
          if e.item == "Weapon_Pistol_C" then BR.bot.equip(shooter, e.slot) end
        end
        return { teams = { ids[1], ids[2] } }`);
      if (typeof setup === 'string') return { ok: false, detail: setup };
      await sleep(1500);
      await lua(`
        local s = BR.player.character(_G.ACCEPTANCE_SHOOTER):K2_GetActorLocation()
        BR.world.teleport(BR.player.character(_G.ACCEPTANCE_TARGET), s.X + 150, s.Y, s.Z)
        BR.bot.look(_G.ACCEPTANCE_SHOOTER, 0, 0)
        BR.bot.fire(_G.ACCEPTANCE_SHOOTER, true)`);
      await sleep(300);
      const r = await lua<{ hp: number; ammo: number; weapon: string }>(`
        BR.bot.fire(_G.ACCEPTANCE_SHOOTER, false)
        local w = BR.bot.weapon(_G.ACCEPTANCE_SHOOTER)
        return { hp = BR.player.health(BR.player.character(_G.ACCEPTANCE_TARGET)), ammo = w.SimState.AmmoLoaded, weapon = w:GetFName():ToString() }`);
      return {
        ok: r.hp < 100,
        detail: `${r.weapon.replace(/_C_\d+$/, '')}: target at ${Math.round(r.hp)} health, ${r.ammo} rounds left`,
      };
    },
  ],
  [
    'tuned weapon damage',
    async () => {
      const slot = await lua<number | null>(`
        local ch = BR.player.character(_G.ACCEPTANCE_SHOOTER)
        for _, e in ipairs(BR.player.inventory(ch)) do
          if e.item == "Weapon_Pistol_C" then
            local item = BR.player.tune(ch, e.slot, { damage = 0, name = "Foam pistol" })
            _G.ACCEPTANCE_TUNED = { slot = e.slot, damage = item.DamageMultiplier, name = item.DisplayName:ToString() }
            return e.slot
          end
        end
        return nil`);
      if (slot == null)
        return { ok: false, detail: 'the shooter has no pistol' };
      await lua(`
        local t = BR.player.character(_G.ACCEPTANCE_TARGET)
        BR.player.set_health(t, 100)
        local s = BR.player.character(_G.ACCEPTANCE_SHOOTER):K2_GetActorLocation()
        BR.world.teleport(t, s.X + 150, s.Y, s.Z)
        BR.bot.look(_G.ACCEPTANCE_SHOOTER, 0, 0)
        BR.bot.fire(_G.ACCEPTANCE_SHOOTER, true)`);
      await sleep(300);
      const r = await lua<{ hp: number; damage: number; name: string }>(`
        BR.bot.fire(_G.ACCEPTANCE_SHOOTER, false)
        BR.player.tune(BR.player.character(_G.ACCEPTANCE_SHOOTER), _G.ACCEPTANCE_TUNED.slot, { damage = 1 })
        return { hp = BR.player.health(BR.player.character(_G.ACCEPTANCE_TARGET)), damage = _G.ACCEPTANCE_TUNED.damage, name = _G.ACCEPTANCE_TUNED.name }`);
      const ok = r.hp === 100 && r.damage === 0 && r.name === 'Foam pistol';
      return {
        ok,
        detail: `damage x${r.damage} ("${r.name}"): target still at ${Math.round(r.hp)} health`,
      };
    },
  ],
  [
    'key presses',
    async () => {
      await lua(`
        _G.ACCEPTANCE_KEYS = { events = {} }
        _G.ACCEPTANCE_KEYS.stop = BR.event.on("key", function(p, info)
          if __addr(p) == __addr(_G.ACCEPTANCE_SHOOTER) then table.insert(_G.ACCEPTANCE_KEYS.events, info.key .. (info.down and "+" or "-")) end
        end)
        BR.bot.fire(_G.ACCEPTANCE_SHOOTER, true)`);
      await sleep(400);
      const held = await lua<boolean>(
        'return BR.player.input(BR.player.character(_G.ACCEPTANCE_SHOOTER)).keys.primary == true',
      );
      await lua('BR.bot.fire(_G.ACCEPTANCE_SHOOTER, false)');
      const events = await waitFor<string[]>(
        'return _G.ACCEPTANCE_KEYS.events',
        v => Array.isArray(v) && v.length >= 2,
        2000,
      );
      await lua('_G.ACCEPTANCE_KEYS.stop()');
      const seen = Array.isArray(events) ? events : [];
      const ok = held && seen.join() === 'primary+,primary-';
      return {
        ok,
        detail: `held while firing ${held}; events ${seen.join(' ') || 'none'}`,
      };
    },
  ],
  [
    'bot reloads',
    async () => {
      const before = await lua<number>(
        'BR.bot.reload(_G.ACCEPTANCE_SHOOTER) return BR.bot.weapon(_G.ACCEPTANCE_SHOOTER).SimState.AmmoLoaded',
      );
      const after = await waitFor<number>(
        'return BR.bot.weapon(_G.ACCEPTANCE_SHOOTER).SimState.AmmoLoaded',
        n => n > before,
        5_000,
      );
      return { ok: after > before, detail: `${before} -> ${after} rounds` };
    },
  ],
  [
    'a bot kill names the killer',
    async () => {
      await lua(`
        local shooter = _G.ACCEPTANCE_SHOOTER
        local victim = BR.bot.spawn("victim ${nonce}", { team = BR.player.team(_G.ACCEPTANCE_TARGET) and FindFirstOf("BRGameStateBase"):GetTeamId(BR.player.team(_G.ACCEPTANCE_TARGET)), respawn_after = false })
        _G.ACCEPTANCE_VICTIM = victim
        _G.ACCEPTANCE_KILL = nil
        if _G.ACCEPTANCE_DEATH_HOOK then _G.ACCEPTANCE_DEATH_HOOK() end
        _G.ACCEPTANCE_DEATH_HOOK = BR.event.on("death", function(player, info)
          if player and __addr(player) == __addr(_G.ACCEPTANCE_VICTIM) then
            _G.ACCEPTANCE_KILL = info.killer_player and info.killer_player.PlayerNamePrivate:ToString() or "nobody"
          end
        end)`);
      // a character can't be hurt for a moment after it spawns
      await sleep(1500);
      await lua(`
        local shooter, victim = _G.ACCEPTANCE_SHOOTER, _G.ACCEPTANCE_VICTIM
        local s = BR.player.character(shooter):K2_GetActorLocation()
        local v = BR.player.character(victim)
        BR.world.teleport(v, s.X + 150, s.Y, s.Z)
        BR.player.set_health(v, 1)
        BR.bot.look(shooter, 0, 0)`);
      // a pistol fires once per pull, so pull until a shot lands
      let killer: string | null = null;
      for (let i = 0; i < 5 && typeof killer !== 'string'; i++) {
        await lua('BR.bot.fire(_G.ACCEPTANCE_SHOOTER, true)');
        await sleep(250);
        await lua('BR.bot.fire(_G.ACCEPTANCE_SHOOTER, false)');
        killer = await waitFor<string | null>(
          'return _G.ACCEPTANCE_KILL',
          v => typeof v === 'string',
          500,
        );
      }
      await lua(
        'BR.bot.fire(_G.ACCEPTANCE_SHOOTER, false) _G.ACCEPTANCE_DEATH_HOOK() BR.bot.remove(_G.ACCEPTANCE_VICTIM)',
      );
      return {
        ok: killer === `shooter ${nonce}`,
        detail: `killed by ${killer ?? 'no death event'}`,
      };
    },
  ],
  [
    'bot switches weapons',
    async () => {
      const slot = await lua<number>(
        'local slot = BR.bot.give(_G.ACCEPTANCE_SHOOTER, "Longsword") BR.bot.equip(_G.ACCEPTANCE_SHOOTER, slot) return slot',
      );
      const held = await waitFor<string>(
        'local w = BR.bot.weapon(_G.ACCEPTANCE_SHOOTER) return w and w:GetFName():ToString() or "none"',
        w => w.startsWith('Weapon_Longsword'),
        5_000,
      );
      await lua(
        'BR.bot.remove(_G.ACCEPTANCE_SHOOTER) BR.bot.remove(_G.ACCEPTANCE_TARGET)',
      );
      return {
        ok: held.startsWith('Weapon_Longsword'),
        detail: `slot ${slot}, holding ${held.replace(/_C_\d+$/, '')}`,
      };
    },
  ],
  [
    'bot speaks through voice chat',
    async () => {
      const r = await lua<{ done: boolean } | string>(`
        local ok, err = pcall(function()
          _G.ACCEPTANCE_SPOKE = false
          local frames = {}
          -- the smallest valid Opus packet: a TOC byte for one 20 ms CELT frame, no payload
          for i = 1, 3 do frames[i] = "\\xf8" end
          BR.voice.say(_G.ACCEPTANCE_BOT, frames, { done = function() _G.ACCEPTANCE_SPOKE = true end })
        end)
        if not ok then return tostring(err) end
        return { done = false }`);
      if (typeof r === 'string') return { ok: false, detail: r };
      const done = await waitFor<boolean>(
        'return _G.ACCEPTANCE_SPOKE',
        v => v === true,
        3_000,
      );
      return {
        ok: done === true,
        detail: done === true ? 'three frames routed' : 'never finished',
      };
    },
  ],
  [
    'record voice chat',
    async () => {
      const r = await lua<{ seconds: number; name: string } | string>(`
        if _G.ACCEPTANCE_RECORDER then _G.ACCEPTANCE_RECORDER() end
        _G.ACCEPTANCE_RECORDER = BR.voice.recorder({ seconds = 10 })
        _G.ACCEPTANCE_SPOKE = false
        local frames = {}
        for i = 1, 5 do frames[i] = "\\xf8" end
        BR.voice.say(_G.ACCEPTANCE_BOT, frames, { done = function() _G.ACCEPTANCE_SPOKE = true end })
        return "started"`);
      await waitFor<boolean>(
        'return _G.ACCEPTANCE_SPOKE',
        v => v === true,
        3_000,
      );
      await sleep(200);
      const rec = await lua<{ seconds: number } | null>(`
        _G.ACCEPTANCE_RECORDER()
        for _, r in ipairs(BR.voice.recorded()) do
          if r.key == __addr(_G.ACCEPTANCE_BOT) then return { seconds = r.seconds, name = r.name } end
        end
        return nil`);
      const ok = rec != null && Math.abs(rec.seconds - 0.1) < 0.001;
      return {
        ok,
        detail: rec
          ? `${rec.seconds.toFixed(2)} s recorded for ${(rec as { name?: string }).name} (5 frames of 20 ms)`
          : `nothing recorded (${r})`,
      };
    },
  ],
  [
    'remove the bot',
    async () => {
      await lua('BR.bot.remove(_G.ACCEPTANCE_BOT)');
      const listed = await waitFor<boolean>(
        `
        for _, b in ipairs(BR.bot.list()) do if __addr(b) == __addr(_G.ACCEPTANCE_BOT) then return true end end
        return false`,
        v => v === false,
        5_000,
      );
      return {
        ok: listed === false,
        detail: listed === false ? 'gone from BR.bot.list' : 'still listed',
      };
    },
  ],
];

// what is in the world: bricks on the world grid and dynamic grids, to show
// which checks leave things behind (every run otherwise grows the test world)
const FOOTPRINT = `
  local lib = StaticFindObject("/Script/Brickadia.Default__BRLuauGridLibrary")
  local bricks = string.unpack("<i4", BR.raw.call(lib, "BRLuauGridLibrary", "GetCount", { Self = BR.raw.ptr(BR.world.global_grid()) }).ReturnValue)
  local grids = {}
  StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetAllActorsOfClass(BR.world.context(), StaticFindObject("/Script/Brickadia.BrickGridDynamicActor"), grids)
  return { bricks = bricks, grids = #grids }`;

type Footprint = { bricks: number; grids: number };

async function footprint(): Promise<Footprint | undefined> {
  try {
    return await lua<Footprint>(FOOTPRINT);
  } catch {
    return undefined;
  }
}

async function main() {
  let passed = 0;
  const start = await footprint();
  // every world-grid brick there is now, to take out what the run adds
  await lua(`
    _G.ACCEPTANCE_START = {}
    for _, h in ipairs(BR.brick.in_box({ -2000000000, -2000000000, -2000000000 }, { 2000000000, 2000000000, 2000000000 }, { max = 1000000 })) do
      _G.ACCEPTANCE_START[h] = true
    end`).catch(() => undefined);
  for (const [name, run] of checks) {
    const before = await footprint();
    let outcome: Outcome;
    try {
      outcome = await run();
    } catch (e) {
      outcome = {
        ok: false,
        detail: e instanceof Error ? e.message : String(e),
      };
    }
    const tag = outcome.ok ? 'PASS' : 'FAIL';
    if (outcome.ok) passed++;
    const after = await footprint();
    let left = '';
    if (
      before &&
      after &&
      (after.bricks !== before.bricks || after.grids !== before.grids)
    ) {
      const d = (n: number) => (n > 0 ? `+${n}` : `${n}`);
      left = ` [world ${d(after.bricks - before.bricks)} bricks, ${d(after.grids - before.grids)} grids]`;
    }
    console.log(`${tag.padEnd(7)} ${name.padEnd(26)} ${outcome.detail}${left}`);
  }
  // the run's own bricks: new since the start, owned by the server stand-in or
  // a bot of this run (their names carry the nonce); anyone else's stays
  const removed = await lua<number>(`
    local start = _G.ACCEPTANCE_START
    if not start then return 0 end
    local gone = {}
    for _, h in ipairs(BR.brick.in_box({ -2000000000, -2000000000, -2000000000 }, { 2000000000, 2000000000, 2000000000 }, { max = 1000000 })) do
      if not start[h] and BR.brick.valid(h) then
        local o = BR.brick.owner(h)
        if o and (o.index == BR.player.owner_index() or o.display_name:find("${nonce}", 1, true)) then gone[#gone + 1] = h end
      end
    end
    if #gone > 0 then
      BR.brick.transaction(BR.player.server(), function(tx) for _, h in ipairs(gone) do tx.delete(BR.brick.id(h)) end end)
    end
    _G.ACCEPTANCE_START = nil
    return #gone`).catch(() => 0);
  if (removed) console.log(`removed the run's own ${removed} bricks`);
  const end = await footprint();
  if (start && end)
    console.log(
      `left in the world: ${end.bricks - start.bricks} bricks, ${end.grids - start.grids} grids`,
    );
  console.log(`${passed}/${checks.length} passed`);
  process.exit(passed === checks.length ? 0 : 1);
}

void main();

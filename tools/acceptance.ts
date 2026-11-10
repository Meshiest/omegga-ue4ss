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

const socket = process.argv[2] ?? process.env.OMEGGA_UE4SS_SOCKET ?? path.join(process.cwd(), 'data', 'UE4SS', 'bridge.sock');
const bridge = new Bridge(socket);
const lua = <T = unknown>(source: string) => bridge.eval<T>(`BR_RELOAD()\n${source}`);
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function waitFor<T>(source: string, ok: (v: T) => boolean, timeoutMs = 15_000): Promise<T> {
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
        local before = BR.brick_count()
        local h = assert(BR.place(BR.builder({ asset = "PB_DefaultBrick", size = { 10, 10, 6 }, color = { 255, 64, 0, 255 } }), ${ox}, ${oy}, 6), "refused")
        local info = BR.brick_info(h)
        return { before = before, after = BR.brick_count(), asset = info.asset, position = info.position }`);
      return { ok: r.after === r.before + 1 && r.asset.includes('PB_DefaultBrick'), detail: `${shortAsset(r.asset)} at [${r.position}], ${r.before} -> ${r.after} bricks` };
    },
  ],
  [
    'place a bot spawn brick',
    async () => {
      const r = await lua<BrickInfo>(`return BR.brick_info(assert(BR.place(BR.builder({ asset = "B_Bot_Spawn_Point" }), ${ox + 80}, ${oy}, 6), "refused"))`);
      return { ok: r.valid && r.asset.includes('B_Bot_Spawn_Point'), detail: `${shortAsset(r.asset)} at [${r.position}]` };
    },
  ],
  [
    'teleport the bot',
    async () => {
      const n = await waitFor<number>('return #BR.bots()', v => v > 0);
      if (!n) return { ok: false, detail: 'no bot spawned' };
      const [tx, ty, tz] = [ox + 200, oy + 200, 400];
      const r = await lua<{ ok: boolean; before: number[]; after: number[] }>(`
        -- earlier runs leave bots behind; the newest spawned last
        local bots = BR.bots()
        local bot = bots[#bots]
        local function loc() local v = bot:K2_GetActorLocation(); return { v.X, v.Y, v.Z } end
        local before = loc()
        local ok = BR.teleport(bot, ${tx}, ${ty}, ${tz})
        return { ok = ok, before = before, after = loc() }`);
      const close = r.after.every((v, i) => Math.abs(v - [tx, ty, tz][i]) < 1);
      return { ok: r.ok && close, detail: `[${r.before.map(Math.round)}] -> [${r.after.map(Math.round)}]` };
    },
  ],
  [
    "set the bot's health",
    async () => {
      const r = await lua<{ before: number[]; set: number[]; restored: number[] }>(`
        local bots = BR.bots()
        local bot = bots[#bots]
        local before = { BR.health(bot) }
        BR.set_health(bot, 40)
        local set = { BR.health(bot) }
        BR.set_health(bot, before[1])
        return { before = before, set = set, restored = { BR.health(bot) } }`);
      return { ok: r.set[0] === 40 && r.restored[0] === r.before[0], detail: `${r.before[0]}/${r.before[1]} -> ${r.set[0]} -> ${r.restored[0]}` };
    },
  ],
  [
    'send a chat message',
    async () => {
      await lua(`BR.chat("acceptance chat ${nonce}")`);
      const line = await waitFor<string[]>(`return BR.log_tail(1, "LogChat: acceptance chat ${nonce}")`, v => v.length > 0);
      return { ok: line.length > 0, detail: line[0]?.slice(-50) ?? 'not in the log' };
    },
  ],
  [
    'read console logs',
    async () => {
      const r = await lua<string[]>('return BR.log_tail(3, "LogGlobalStatus")');
      return { ok: r.length > 0, detail: `${r.length} LogGlobalStatus lines, last: ${r.at(-1)?.slice(-45) ?? ''}` };
    },
  ],
  [
    'run a console command',
    async () => {
      await lua(`BR.console("br.Chat.Broadcast console ${nonce}")`);
      const line = await waitFor<string[]>(`return BR.log_tail(1, "LogChat: console ${nonce}")`, v => v.length > 0);
      return { ok: line.length > 0, detail: line[0]?.slice(-50) ?? 'not in the log' };
    },
  ],
  [
    'list roles',
    async () => {
      const roles = await lua<string[]>('return BR.roles()');
      return { ok: roles.includes('Owner') && roles.includes('Default'), detail: roles.join(', ') };
    },
  ],
  [
    'place a logic gate',
    async () => {
      // owned by the bridge's player, so its transactions are trusted to edit it
      const r = await lua<BrickInfo>(`
        _G.ACCEPTANCE_GATE = assert(BR.place(BR.builder({ asset = "B_1x1_Gate_Expr_LogicalAND", owner = BR.owner_index() }), ${gate.join(', ')}), "refused")
        return BR.brick_info(_G.ACCEPTANCE_GATE)`);
      return { ok: r.valid && r.asset.includes('LogicalAND'), detail: `${shortAsset(r.asset)} at [${r.position}]` };
    },
  ],
  [
    'set a value on the gate',
    async () => {
      const r = await lua<Record<string, number>>(
        `return BR.set_input(_G.ACCEPTANCE_GATE, "${AND}", "bInputA", BR.wire_bool(true))`,
      );
      const other = Object.entries(r).filter(([k, v]) => k !== 'lines' && v !== 0 && k !== 'ComponentsChanged');
      return { ok: r.ComponentsChanged === 1 && !other.length, detail: `bInputA = true, report ${JSON.stringify(Object.fromEntries(Object.entries(r).filter(([k, v]) => k !== 'lines' && v)))}` };
    },
  ],
  [
    'read the value back',
    async () => {
      // true must read as true; false must not (a negative control, so an
      // oracle that always says "unchanged" can't pass), then restore true
      const r = await lua<{ isTrue: boolean; isFalse: boolean; restored: boolean }>(`
        local isTrue = BR.input_is(_G.ACCEPTANCE_GATE, "${AND}", "bInputA", BR.wire_bool(true))
        local isFalse = BR.input_is(_G.ACCEPTANCE_GATE, "${AND}", "bInputA", BR.wire_bool(false))
        local restored = not BR.input_is(_G.ACCEPTANCE_GATE, "${AND}", "bInputA", BR.wire_bool(true))
        return { isTrue = isTrue, isFalse = isFalse, restored = restored }`);
      return { ok: r.isTrue && !r.isFalse && r.restored, detail: `bInputA reads true: ${r.isTrue}, reads false: ${r.isFalse}` };
    },
  ],
  [
    'leaderboard value',
    async () => {
      const r = await lua<number>(`
        local ps = BR.player()
        BR.set_leaderboard(ps, "Acceptance", 5)
        BR.add_leaderboard(ps, "Acceptance", 2)
        return BR.leaderboard(ps, "Acceptance")`);
      return { ok: r === 7, detail: `set 5, add 2: ${r}` };
    },
  ],
  [
    'fire an exec gate',
    async () => {
      // a trigger wired to Broadcast Chat Message (an admin gate); its empty message logs a bare "LogChat:"
      const wired = await lua<Record<string, number>>(`
        local CHAT = BR.component_type("Gamemode_BroadcastChatMessage"):GetFName():ToString()
        local chat = assert(BR.place(BR.builder({ asset = "B_1x1_Gate_Exec_Gamemode_BroadcastChatMessage", owner = BR.owner_index() }), ${gate[0]}, ${gate[1] + 80}, 6), "refused")
        _G.ACCEPTANCE_TRIGGER = BR.trigger(${gate[0]}, ${gate[1] + 40}, 6)
        return _G.ACCEPTANCE_TRIGGER.connect(chat, CHAT, "Exec")`);
      if (wired.WiresConnected !== 1) return { ok: false, detail: `connect: ${JSON.stringify(wired)}` };
      await sleep(500);
      const count = 'return #BR.log_tail(1000000, "LogChat:")';
      const before = await lua<number>(count);
      await lua('_G.ACCEPTANCE_TRIGGER.fire()');
      const after = await waitFor<number>(count, v => v > before, 5_000);
      return { ok: after === before + 1, detail: `chat lines ${before} -> ${after}` };
    },
  ],
  [
    'raycast onto a brick',
    async () => {
      // placed first: a brick has no collision until the next tick
      await lua(`_G.ACCEPTANCE_RAY = assert(BR.place(BR.builder({ asset = "PB_DefaultBrick", size = { 10, 10, 6 } }), ${ox + 160}, ${oy}, 6), "refused")`);
      await sleep(200);
      const r = await lua<{ z: number; same: boolean } | null>(`
        local hit = BR.raycast({ ${ox + 160}, ${oy}, 500 }, { 0, 0, -1 })
        if not hit then return nil end
        local info = hit.brick and BR.brick_info(hit.brick)
        local mine = BR.brick_info(_G.ACCEPTANCE_RAY)
        return { z = hit.position[3], same = info ~= nil and info.position[1] == mine.position[1] and info.position[2] == mine.position[2] }`);
      return { ok: r !== null && r.same && Math.abs(r.z - 12) < 0.5, detail: r ? `hit z ${r.z}, the placed brick: ${r.same}` : 'no hit' };
    },
  ],
  [
    'set component data',
    async () => {
      const r = await lua<{ gun: boolean; active: boolean }>(`
        local spawn = assert(BR.place(BR.builder({ asset = "B_Bot_Spawn_Point", owner = BR.owner_index() }), ${ox + 240}, ${oy}, 6), "refused")
        BR.set_component(spawn, "BotSpawn", { GunSkill = 0.25, bActiveBot = false, BotName = "acceptance" })
        local T = BR.component_type("BotSpawn"):GetFName():ToString()
        return { gun = BR.input_is(spawn, T, "GunSkill", BR.wire_double(0.25)), active = BR.input_is(spawn, T, "bActiveBot", BR.wire_bool(false)) }`);
      return { ok: r.gun && r.active, detail: `GunSkill 0.25: ${r.gun}, bActiveBot false: ${r.active}` };
    },
  ],
  [
    'custom event by name',
    async () => {
      // a listener for another name must stay quiet, so a name that is ignored can't pass
      await lua(`
        _G.ACCEPTANCE_HEARD, _G.ACCEPTANCE_WRONG = {}, 0
        BR.on_custom_event("acceptance_${nonce}", function(data, count) table.insert(_G.ACCEPTANCE_HEARD, { data[1], data[2], count }) end, { at = { ${ox}, ${oy + 120}, 6 } })
        BR.on_custom_event("other_${nonce}", function() _G.ACCEPTANCE_WRONG = _G.ACCEPTANCE_WRONG + 1 end, { at = { ${ox}, ${oy + 160}, 6 } })
        _G.ACCEPTANCE_EVENT = BR.custom_event("acceptance_${nonce}", { at = { ${ox + 160}, ${oy + 120}, 6 } })`);
      await sleep(300);
      await lua('_G.ACCEPTANCE_EVENT.send(BR.wire_string("payload"), BR.wire_int(7))');
      const heard = await waitFor<[string, number, number][]>('return _G.ACCEPTANCE_HEARD', v => Array.isArray(v) && v.length > 0, 5_000);
      const wrong = await lua<number>('return _G.ACCEPTANCE_WRONG');
      const first = Array.isArray(heard) ? heard[0] : undefined;
      const ok = first?.[0] === 'payload' && first?.[1] === 7 && first?.[2] === 1 && wrong === 0;
      return { ok, detail: first ? `heard ${JSON.stringify(first)}, other listener ${wrong}x` : 'nothing heard' };
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
          local g = W:SpawnEntity(BR.world_context(), GT, xf, true, BR.owner_index(), {})
          assert(BR.place(BR.builder({ asset = "PB_DefaultBrick", size = { 10, 10, 6 }, owner = BR.owner_index(), grid = g }), 0, 0, 6), "refused")
          return g
        end
        local a, b = grid(0), grid(400)
        _G.ACCEPTANCE_TARGETED = { a = 0, b = 0, global = 0 }
        local heard = _G.ACCEPTANCE_TARGETED
        BR.on_custom_event("targeted_${nonce}", function() heard.a = heard.a + 1 end, { entity = a })
        BR.on_custom_event("targeted_${nonce}", function() heard.b = heard.b + 1 end, { entity = b })
        BR.on_custom_event("targeted_${nonce}", function() heard.global = heard.global + 1 end, { at = { ${ox}, ${oy + 200}, 6 } })
        _G.ACCEPTANCE_TARGET_EVENT = BR.custom_event("targeted_${nonce}", { target = a, at = { ${ox + 160}, ${oy + 200}, 6 } })`);
      await sleep(300);
      await lua('_G.ACCEPTANCE_TARGET_EVENT.send()');
      const r = await waitFor<{ a: number; b: number; global: number }>('return _G.ACCEPTANCE_TARGETED', v => v.a > 0, 5_000);
      return { ok: r.a === 1 && r.b === 0 && r.global === 0, detail: `target ${r.a}x, other grid ${r.b}x, global ${r.global}x` };
    },
  ],
  [
    'player event: chat',
    async () => {
      const r = await lua<{ who: string; message: string } | null>(`
        local pc = _G.ACCEPTANCE_PC
        if not (pc and pc:IsValid()) then
          pc = BR.spawn(StaticFindObject("/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"))
          pc:JoinGameModeTeam(-1, true, false)
          _G.ACCEPTANCE_PC = pc
        end
        local seen
        local stop = BR.on("chat", function(player, info) seen = { who = BR.player_info(player).display_name, message = info.message } end)
        pc:ServerPushChatMessage("acceptance ${nonce}")
        stop()
        return seen`);
      return { ok: r?.message === `acceptance ${nonce}`, detail: r ? `${r.who}: ${r.message}` : 'no event' };
    },
  ],
  [
    'read component data',
    async () => {
      const r = await lua<{ gun: number; name: string; active: boolean }>(`
        local spawn = assert(BR.place(BR.builder({ asset = "B_Bot_Spawn_Point", owner = BR.owner_index() }), ${ox + 280}, ${oy}, 6), "refused")
        BR.set_component(spawn, "BotSpawn", { GunSkill = 0.375, BotName = "reader ${nonce}", bActiveBot = false })
        local d = BR.component_data(spawn, "BotSpawn")
        return { gun = d.GunSkill, name = BR.get_component(spawn, "BotSpawn", "BotName"), active = d.bActiveBot }`);
      return { ok: r.gun === 0.375 && r.name === `reader ${nonce}` && r.active === false, detail: `GunSkill ${r.gun}, BotName "${r.name}", bActiveBot ${r.active}` };
    },
  ],
  [
    'hook an interaction',
    async () => {
      // a spawned controller on a team gets a character, standing in for a player
      const r = await lua<{ hit: number[] | null; nearby: boolean }>(`
        local pc = _G.ACCEPTANCE_PC
        if not (pc and pc:IsValid()) then
          pc = BR.spawn(StaticFindObject("/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"))
          pc:JoinGameModeTeam(-1, true, false)
          _G.ACCEPTANCE_PC = pc
        end
        local button = assert(BR.place(BR.builder({ asset = "B_Button", owner = BR.owner_index() }), ${ox + 320}, ${oy}, 6), "refused")
        local seen = {}
        if not _G.ACCEPTANCE_HOOKED then
          _G.ACCEPTANCE_HOOKED = true
          BR.on_interact(function(ch, brick, nearby) _G.ACCEPTANCE_SEEN = { brick = BR.brick_info(brick).position, nearby = nearby } end)
        end
        _G.ACCEPTANCE_SEEN = nil
        local ch = assert(BR.character(pc.PlayerState), "no character")
        BR.interact(ch, button)
        BR.stop_interact(ch)
        local s = _G.ACCEPTANCE_SEEN
        return { hit = s and s.brick or nil, nearby = s and s.nearby or false }`);
      const ok = r.hit !== null && r.hit[0] === ox + 320 && r.hit[1] === oy;
      return { ok, detail: r.hit ? `hook saw the button at [${r.hit}]` : 'hook did not fire' };
    },
  ],
];

async function main() {
  let passed = 0;
  for (const [name, run] of checks) {
    let outcome: Outcome;
    try {
      outcome = await run();
    } catch (e) {
      outcome = { ok: false, detail: (e as Error).message };
    }
    const tag = outcome.ok ? 'PASS' : 'FAIL';
    if (outcome.ok) passed++;
    console.log(`${tag.padEnd(7)} ${name.padEnd(26)} ${outcome.detail}`);
  }
  console.log(`${passed}/${checks.length} passed`);
  process.exit(passed === checks.length ? 0 : 1);
}

void main();

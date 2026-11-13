import fs from 'node:fs';
import path from 'node:path';
import type { OU, PC, PM, PS } from 'omegga';
import { Bridge } from './src/bridge';
import {
  crossSiteWrite,
  findRoute,
  type HttpRequest,
  type HttpResponse,
  toResponse,
} from './src/http';
import { log } from './src/log';
import { LuaDatabases, parseSql } from './src/luadb';
import { LuaStore } from './src/luastore';
import { type ConsoleCommand, type ModConsoleCommand, outputLines, readModCommands } from './src/consolecmd';
import { LuaMetrics } from './src/luametrics';
import { type ModError, ModLogWatcher } from './src/modlog';
import {
  gameTypesDir,
  gameTypesStamp,
  prepare,
  SOCKET_PATH_MAX,
  socketPath,
  ue4ssDir,
} from './src/prepare';

/** A UE4SS mod folder holds mod directories with Scripts/ (Lua) or dlls/ (C++). */
function hasUe4ssMods(dir: string) {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .some(
        e =>
          e.isDirectory() &&
          ['Scripts', 'dlls'].some(sub =>
            fs.existsSync(path.join(dir, e.name, sub)),
          ),
      );
  } catch {
    return false;
  }
}

/**
 * A Lua mod's error, in omegga's log: UE4SS catches them (a failed main.lua
 * leaves that mod not running, the server carries on) but only writes them to
 * UE4SS.log.
 */
function reportModError(err: ModError, repeats: number) {
  const who = err.mod ? `mod ${err.mod}` : 'a Lua mod';
  const more = repeats ? ` (and ${repeats} more times in the last minute)` : '';
  if (err.failedToStart)
    log.error(
      `${who} failed to start and is not running${more}:\n${err.message}`,
    );
  else log.error(`${who} raised an error${more}:\n${err.message}`);
}

// omegga runs this file bundled into .build/
const PLUGIN_DIR = path.resolve(__dirname, '..');

/**
 * Prepares data/UE4SS before omegga launches the game (omegga awaits init()
 * before spawning it), and connects omegga plugins with UE4SS Lua. From another
 * plugin (`ue4ss` is this plugin's name):
 *
 *   const ue4ss = await omegga.getPlugin('ue4ss');
 *   await ue4ss.emitPlugin('exec', 'return 1 + 1');          // { ok: true, result: 2 }
 *   await ue4ss.emitPlugin('call', 'greet', 'world');        // a Lua Omegga.handle('greet', fn)
 *   await ue4ss.emitPlugin('subscribe', 'my-plugin', 'watch'); // Lua events -> my-plugin's
 *                                                            // pluginEvent('ue4ss:watch', from, data)
 *
 * Every Lua event is also emitted on omegga itself as `ue4ss:<event>`. See
 * docs/interop.md. The launch is doc.json's `launch` block (bin/launch.sh).
 */
export default class Ue4ssPlugin {
  readonly #bridge: Bridge;
  /** Lua event name (or '*') -> plugins that asked for it */
  readonly #subscribers = new Map<string, Set<string>>();
  readonly #modLog: ModLogWatcher;
  readonly #luaMetrics: LuaMetrics;
  readonly #databases: LuaDatabases;
  readonly #luaStore: LuaStore | undefined;
  /** Console commands Lua mods declare in their doc.json, read at init. */
  #modCommands: ModConsoleCommand[] = [];
  /** Chat commands Lua mods declare in their doc.json, read at init. */
  #modChatCommands: ModConsoleCommand[] = [];
  /** omegga command listeners added at init, removed again at stop. */
  #consoleListeners: [string, (...args: string[]) => void][] = [];

  constructor(
    private readonly omegga: OU,
    _config?: PC,
    store?: PS,
    metrics?: PM,
  ) {
    this.#luaMetrics = new LuaMetrics(metrics, log.warn);
    this.#luaStore = store && new LuaStore(store);
    this.#databases = new LuaDatabases(
      path.join(omegga.dataPath, 'Saved', 'LuaDatabases'),
    );
    this.#bridge = new Bridge(socketPath(omegga.dataPath), {
      emit: (event, data) => this.#deliver(event, data),
      call: async (plugin, event, args) => {
        const target = await this.omegga.getPlugin(plugin);
        if (!target?.loaded || !target.emitPlugin)
          throw new Error(`plugin ${plugin} is not loaded`);
        return target.emitPlugin(event, ...args);
      },
      warn: log.warn,
    });
    this.#modLog = new ModLogWatcher(
      path.join(ue4ssDir(omegga.dataPath), 'UE4SS.log'),
      reportModError,
    );
  }

  async #deliver(event: string, data: unknown) {
    // BR.metrics updates go to this plugin's own metrics, not to other plugins
    if (event === 'metric') return this.#luaMetrics.apply(data);
    this.omegga.emit(`ue4ss:${event}`, data);
    const names = new Set([
      ...(this.#subscribers.get(event) ?? []),
      ...(this.#subscribers.get('*') ?? []),
    ]);
    for (const name of names) {
      const target = await this.omegga.getPlugin(name);
      if (target?.loaded && target.emitPlugin)
        await target.emitPlugin(`ue4ss:${event}`, data);
      else this.#subscribers.forEach(set => set.delete(name));
    }
  }

  /**
   * `mods/` of every other enabled plugin that contains UE4SS mods. Sandboxed
   * (node_safe) plugins are skipped: UE4SS Lua has unrestricted io/os access and
   * C++ mods are native code, either of which would escape the sandbox.
   */
  pluginModDirs(): string[] {
    const own = fs.realpathSync(PLUGIN_DIR);
    return (this.omegga.pluginLoader?.plugins ?? [])
      .filter(p => p.isEnabled() && p.getFormat() !== 'node_safe')
      .map(p => path.join(p.path, 'mods'))
      .filter(
        dir => hasUe4ssMods(dir) && fs.realpathSync(path.dirname(dir)) !== own,
      );
  }

  async init() {
    // BR.store wrote JSON files under the game's Saved directory before it
    // moved into this plugin's storage
    const imported = await this.#luaStore?.importFiles(
      path.join(this.omegga.dataPath, 'Saved', 'LuaStore'),
    );
    if (imported) log.info(`Imported ${imported} BR.store tables from Saved/LuaStore`);
    const extraModDirs = this.pluginModDirs();
    if (extraModDirs.length)
      log.info('Loading UE4SS mods from', extraModDirs.join(', '));
    const result = await prepare({
      dataDir: this.omegga.dataPath,
      pluginDir: PLUGIN_DIR,
      gameBinary: this.omegga.getGameBinaryPath(),
      extraModDirs,
      log,
    });
    const counts = new Map<string, number>();
    for (const r of result.reports)
      counts.set(r.status, (counts.get(r.status) ?? 0) + 1);
    const summary = [...counts].map(([s, n]) => `${n} ${s}`).join(', ');
    if (result.ready) log.info('UE4SS ready for the next game start:', summary);
    else
      log.warn(
        'UE4SS disabled for the next game start:',
        result.reason,
        summary && `(${summary})`,
      );
    for (const r of result.reports.filter(r => r.status !== 'verified'))
      log.warn(`  ${r.status} ${r.symbol}: ${r.note}`);
    for (const v of result.vtables.filter(v => !v.ok))
      log.warn(`  vtable ${v.name}: ${v.note}`);
    const sock = socketPath(this.omegga.dataPath);
    if (Buffer.byteLength(sock) > SOCKET_PATH_MAX)
      log.warn(
        `the bridge socket path is longer than ${SOCKET_PATH_MAX} bytes, so plugins can't reach Lua: ${sock}`,
      );
    this.#listenCommands(extraModDirs);
    // connects once the game is up, and again after every restart
    this.#bridge.start();
    this.#modLog.start();
    this.omegga.on('mapchange', this.#onMap);
    // reloaded into a running server: no map change is coming
    if (this.omegga.started && this.omegga.currentMap) this.#onMap();
    // registered, so omegga doesn't tell the player the command doesn't exist
    return { registeredCommands: this.#modChatCommands.map(c => c.command.name) };
  }

  /**
   * Requests to `/api/v1/plugin/ue4ss/...` on omegga's web server, answered by
   * the Lua mod that registered the route (`Omegga.route`). doc.json makes the
   * plugin public to omegga, so a route that needs a login is checked here.
   */
  async http(request: HttpRequest): Promise<HttpResponse | undefined> {
    const route = findRoute(
      this.#bridge.handlers.keys(),
      request.method,
      request.path,
    );
    if (!route) return undefined;
    if (!route.public && !request.user)
      return { status: 401, body: { message: 'unauthorized' } };
    if (!route.public && crossSiteWrite(request))
      return { status: 403, body: { message: 'cross-origin request' } };
    // omegga gives up after 10 s; answering just before keeps the error ours
    const reply = await this.#bridge.callLua(route.handler, [request], 9_000);
    if (!reply.ok) {
      log.warn(`route ${route.method} ${route.path}:`, reply.error);
      return { status: 500, body: { message: 'mod error' } };
    }
    return toResponse(reply.result);
  }

  /**
   * `from` is 'unsafe' for every unsafe plugin (omegga doesn't say which), so
   * subscribers name themselves.
   */
  async pluginEvent(event: string, _from: string, ...args: unknown[]) {
    switch (event) {
      case 'exec':
        // with a mod name, the code runs in that mod's own Lua state (its
        // locals and globals) rather than the bridge's
        if (args[1] !== undefined)
          return this.#bridge.callLua(`exec@${String(args[1])}`, [
            String(args[0]),
          ]);
        return this.#bridge.exec(String(args[0]));
      case 'sql': {
        // BR.db: (name, op, sql, params); a thrown SQL error reaches Lua's callback
        const req = parseSql(args);
        if (typeof req === 'string') throw new Error(req);
        return this.#databases.run(req);
      }
      case 'store':
        if (!this.#luaStore) throw new Error('this plugin has no omegga storage');
        return this.#luaStore.handle(args);
      case 'mods':
        return [...this.#bridge.handlers.keys()]
          .filter(n => n.startsWith('exec@'))
          .map(n => n.slice(5))
          .sort();
      case 'call': {
        const [name, ...rest] = args;
        return this.#bridge.callLua(String(name), rest);
      }
      case 'subscribe':
      case 'unsubscribe': {
        const [plugin, luaEvent = '*'] = args.map(String);
        if (!plugin)
          return { ok: false, error: `${event} needs (pluginName, event)` };
        const set = this.#subscribers.get(luaEvent) ?? new Set<string>();
        if (event === 'subscribe') set.add(plugin);
        else set.delete(plugin);
        this.#subscribers.set(luaEvent, set);
        return { ok: true };
      }
    }
    return undefined;
  }

  #generating: Promise<void> | null = null;
  #stopped = false;

  #onMap = () => {
    // A bot's character (BR.bot) is driven by an AI controller, so the game
    // treats it as locally controlled, and aiming at a brick sends it looking
    // for the HUD to show an interaction prompt. A dedicated server has no HUD,
    // so each bot logs an error under LogBRDialogs every tick. The category is
    // only about on-screen dialogs, which a server never shows. The engine
    // ignores -LogCmds for it (the category registers too late), so it goes
    // through the console on each map load, which every server start has.
    this.omegga.writeln('log LogBRDialogs off');
    this.#generating ??= this.#generateTypes()
      .catch(e => log.warn('could not generate Lua types:', e))
      .finally(() => (this.#generating = null));
  };

  /**
   * Generate the game's Lua types once per game binary. Runs after a map load
   * rather than at omegga's `start` or when the bridge connects: Brickadia logs
   * in on a placeholder map before UE4SS is up, most Blueprint classes load only
   * with the real map, and the generator covers loaded classes only.
   */
  async #generateTypes() {
    const marker = path.join(ue4ssDir(this.omegga.dataPath), 'ready');
    if (!fs.existsSync(marker)) return;
    const identity = fs.readFileSync(marker, 'utf8');
    const stamp = gameTypesStamp(this.omegga.dataPath);
    if (fs.existsSync(stamp) && fs.readFileSync(stamp, 'utf8') === identity)
      return;
    // the bridge mod may still be loading on a fast map change
    const deadline = Date.now() + 120_000;
    while (!this.#stopped) {
      const reply = await this.#bridge.exec('GenerateLuaTypes()', 120_000);
      if (reply.ok) {
        fs.writeFileSync(stamp, identity);
        log.info(
          'Generated Lua types for the game in',
          gameTypesDir(this.omegga.dataPath),
        );
        return;
      }
      if (Date.now() > deadline) throw new Error(reply.error);
      await new Promise(resolve => setTimeout(resolve, 2000));
    }
  }

  /**
   * Console commands the Lua mods declare, for omegga's /help and dispatch.
   * omegga asks once, right after init, so a mod's new doc.json shows up after
   * the plugin reloads.
   */
  extraConsoleCommands(): ConsoleCommand[] {
    return this.#modCommands.map(({ mod, command }) => ({
      ...command,
      description: `${command.description} (Lua mod ${mod})`.trim(),
    }));
  }

  #listenCommands(extraModDirs: string[]) {
    const dirs = [
      path.join(this.omegga.dataPath, 'Mods'),
      path.join(PLUGIN_DIR, 'mods'),
      ...extraModDirs,
    ];
    this.#modCommands = readModCommands(dirs, log.warn, 'consoleCommands');
    this.#modChatCommands = readModCommands(dirs, log.warn, 'commands');
    const listen = (event: string, fn: (...args: string[]) => void) => {
      this.omegga.on(event, fn);
      this.#consoleListeners.push([event, fn]);
    };
    for (const { mod, command } of this.#modCommands) {
      // a mod can't take this plugin's own command
      if (command.name === 'lua') continue;
      listen(`consolecmd:${command.name}`, (...args) => void this.#runModCommand(mod, command.name, args));
    }
    listen('consolecmd:lua', (...args) => void this.#luaCommand(args));
    for (const { mod, command } of this.#modChatCommands)
      listen(`cmd:${command.name}`, (player, ...args) => void this.#runChatCommand(mod, command.name, player, args));
  }

  /** A player's /name: the mod's Omegga.on("cmd:<name>", fn) gets (player name, ...words). */
  async #runChatCommand(mod: string, name: string, player: string, args: string[]) {
    const reply = await this.#bridge.callLua(`cmd:${name}`, [player, ...args]);
    if (!reply.ok) log.error(`/${name} from ${player} (Lua mod ${mod}):`, reply.error);
  }

  async #runModCommand(mod: string, name: string, args: string[]) {
    const reply = await this.#bridge.callLua(`consolecmd:${name}`, args);
    if (!reply.ok) return log.error(`/${name} (Lua mod ${mod}):`, reply.error);
    for (const line of outputLines(reply.result)) log.info(line);
  }

  /**
   * /lua mods | exec [Mod] <code>. No reload: UE4SS's RestartMod hung the game
   * thread (a Lua state lock in the bridge's tick) the first time the
   * restarted mod was called, and the engine killed the server.
   */
  async #luaCommand([sub, ...rest]: string[]) {
    const mods = [...this.#bridge.handlers.keys()]
      .filter(n => n.startsWith('exec@'))
      .map(n => n.slice(5))
      .sort();
    if (sub === 'mods') {
      if (!this.#bridge.connected) return log.warn('not connected to the game');
      return log.info('Lua mods:', mods.join(', ') || 'none');
    }
    if (sub === 'exec') {
      const target = rest[0] && mods.includes(rest[0]) ? rest[0] : undefined;
      const code = (target ? rest.slice(1) : rest).join(' ');
      if (!code) return log.warn('usage: /lua exec [Mod] <code>');
      const reply = target
        ? await this.#bridge.callLua(`exec@${target}`, [code])
        : await this.#bridge.exec(code);
      if (!reply.ok) return log.error('/lua exec:', reply.error);
      for (const line of outputLines(reply.result)) log.info(line);
      return;
    }
    log.warn('usage: /lua mods | exec [Mod] <code>');
  }

  async stop() {
    this.#stopped = true;
    this.omegga.off('mapchange', this.#onMap);
    for (const [event, fn] of this.#consoleListeners) this.omegga.off(event, fn);
    this.#consoleListeners = [];
    this.#bridge.close();
    this.#modLog.stop();
    this.#databases.close();
  }
}

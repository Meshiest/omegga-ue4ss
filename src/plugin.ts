import fs from 'node:fs';
import path from 'node:path';
import { Bridge } from './bridge';
import { log } from './log';
import { gameTypesDir, gameTypesStamp, prepare, SOCKET_PATH_MAX, socketPath, ue4ssDir } from './prepare';

interface OmeggaPlugin {
  path: string;
  isEnabled(): boolean;
  getName(): string;
  constructor: { getFormat?(): string };
}

interface PluginInterop {
  loaded: boolean;
  emitPlugin(event: string, ...args: unknown[]): Promise<unknown>;
}

/** The slice of omegga this plugin uses (it runs as an unsafe plugin). */
interface Omegga {
  dataPath: string;
  getGameBinaryPath(): string | null;
  pluginLoader?: { plugins: OmeggaPlugin[] };
  getPlugin(name: string): Promise<PluginInterop | null>;
  emit(event: string, ...args: unknown[]): boolean;
  /** set once Brickadia has logged in */
  started: boolean;
  currentMap: string;
  on(event: string, listener: (...args: unknown[]) => void): unknown;
  off(event: string, listener: (...args: unknown[]) => void): unknown;
}

/** A UE4SS mod folder holds mod directories with Scripts/ (Lua) or dlls/ (C++). */
function hasUe4ssMods(dir: string) {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .some(e => e.isDirectory() && ['Scripts', 'dlls'].some(sub => fs.existsSync(path.join(dir, e.name, sub))));
  } catch {
    return false;
  }
}

interface Config {
  runtimeUrl?: string;
}

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

  constructor(
    private readonly omegga: Omegga,
    private readonly config: Config,
  ) {
    this.#bridge = new Bridge(socketPath(omegga.dataPath), {
      emit: (event, data) => this.#deliver(event, data),
      call: async (plugin, event, args) => {
        const target = await this.omegga.getPlugin(plugin);
        if (!target?.loaded) throw new Error(`plugin ${plugin} is not loaded`);
        return target.emitPlugin(event, ...args);
      },
      warn: log.warn,
    });
  }

  async #deliver(event: string, data: unknown) {
    this.omegga.emit(`ue4ss:${event}`, data);
    const names = new Set([...(this.#subscribers.get(event) ?? []), ...(this.#subscribers.get('*') ?? [])]);
    for (const name of names) {
      const target = await this.omegga.getPlugin(name);
      if (target?.loaded) await target.emitPlugin(`ue4ss:${event}`, data);
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
      .filter(p => p.isEnabled() && p.constructor.getFormat?.() !== 'node_safe')
      .map(p => path.join(p.path, 'mods'))
      .filter(dir => hasUe4ssMods(dir) && fs.realpathSync(path.dirname(dir)) !== own);
  }

  async init() {
    const extraModDirs = this.pluginModDirs();
    if (extraModDirs.length) log.info('Loading UE4SS mods from', extraModDirs.join(', '));
    const result = await prepare({
      dataDir: this.omegga.dataPath,
      pluginDir: PLUGIN_DIR,
      gameBinary: this.omegga.getGameBinaryPath(),
      runtimeUrl: this.config.runtimeUrl || undefined,
      extraModDirs,
      log,
    });
    const counts = new Map<string, number>();
    for (const r of result.reports) counts.set(r.status, (counts.get(r.status) ?? 0) + 1);
    const summary = [...counts].map(([s, n]) => `${n} ${s}`).join(', ');
    if (result.ready) log.info('UE4SS ready for the next game start:', summary);
    else log.warn('UE4SS disabled for the next game start:', result.reason, summary && `(${summary})`);
    for (const r of result.reports.filter(r => r.status !== 'verified'))
      log.warn(`  ${r.status} ${r.symbol}: ${r.note}`);
    for (const v of result.vtables.filter(v => !v.ok)) log.warn(`  vtable ${v.name}: ${v.note}`);
    const sock = socketPath(this.omegga.dataPath);
    if (Buffer.byteLength(sock) > SOCKET_PATH_MAX)
      log.warn(`the bridge socket path is longer than ${SOCKET_PATH_MAX} bytes, so plugins can't reach Lua: ${sock}`);
    // connects once the game is up, and again after every restart
    this.#bridge.start();
    this.omegga.on('mapchange', this.#onMap);
    // reloaded into a running server: no map change is coming
    if (this.omegga.started && this.omegga.currentMap) this.#onMap();
    return { registeredCommands: [] };
  }

  /**
   * `from` is 'unsafe' for every unsafe plugin (omegga doesn't say which), so
   * subscribers name themselves.
   */
  async pluginEvent(event: string, _from: string, ...args: unknown[]) {
    switch (event) {
      case 'exec':
        return this.#bridge.exec(String(args[0]));
      case 'call': {
        const [name, ...rest] = args;
        return this.#bridge.callLua(String(name), rest);
      }
      case 'subscribe':
      case 'unsubscribe': {
        const [plugin, luaEvent = '*'] = args.map(String);
        if (!plugin) return { ok: false, error: `${event} needs (pluginName, event)` };
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
    if (fs.existsSync(stamp) && fs.readFileSync(stamp, 'utf8') === identity) return;
    // the bridge mod may still be loading on a fast map change
    const deadline = Date.now() + 120_000;
    while (!this.#stopped) {
      const reply = await this.#bridge.exec('GenerateLuaTypes()', 120_000);
      if (reply.ok) {
        fs.writeFileSync(stamp, identity);
        log.info('Generated Lua types for the game in', gameTypesDir(this.omegga.dataPath));
        return;
      }
      if (Date.now() > deadline) throw new Error(reply.error);
      await new Promise(resolve => setTimeout(resolve, 2000));
    }
  }

  async stop() {
    this.#stopped = true;
    this.omegga.off('mapchange', this.#onMap);
    this.#bridge.close();
  }
}

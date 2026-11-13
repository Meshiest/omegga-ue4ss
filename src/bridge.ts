import net from 'node:net';

/**
 * Client for the BrickadiaBridge C++ mod's Unix socket (docs/interop.md). Lines
 * sent are `<target>\t<json>`, where the target is a Lua listener: the bridge mod
 * (`BrickadiaBridge`, for exec) or a mod id (for calls into Omegga.handle
 * handlers). Lines received are JSON with a `t` field. The mod hands each line
 * to Lua on the game thread at the start of the next engine tick.
 *
 * Any number of clients can be connected; answers go back to the client that
 * asked, and messages Lua starts (events, calls, handler registrations) go to
 * every client. Only a client with a host answers Lua's calls and delivers
 * its events, so a tool connecting next to the plugin changes nothing.
 */
export type BridgeReply = { ok: true; result?: unknown } | { ok: false; error: string };

/** What Lua sends without being asked (lua/omegga/omegga.lua). */
export type LuaMessage = { mod: string } & (
  | { t: 'event'; event: string; data?: unknown }
  | { t: 'call'; id: string; plugin: string; event: string; args?: unknown[] }
  | { t: 'register'; name: string }
);

type Incoming =
  | LuaMessage
  | ({ t: 'result'; id: string } & BridgeReply)
  | { t: 'undeliverable'; target: string; message: { id?: string } };

export interface InteropHost {
  emit(event: string, data: unknown): Promise<void> | void;
  call(plugin: string, event: string, args: unknown[]): Promise<unknown>;
  /** problems talking to the game */
  warn(...args: unknown[]): void;
}

const BRIDGE_MOD = 'BrickadiaBridge';

export class Bridge {
  #socket: net.Socket | null = null;
  #connecting: Promise<net.Socket> | null = null;
  #buffer = '';
  #requests = 0;
  readonly #pending = new Map<string, { resolve: (r: BridgeReply) => void; timer: NodeJS.Timeout }>();
  #retry: NodeJS.Timeout | undefined;
  #stopped = true;
  #retryMs = 1000;
  /** Lua handler name -> id of the mod that registered it, as last announced */
  readonly handlers = new Map<string, string>();

  constructor(
    readonly socketPath: string,
    private readonly host?: InteropHost,
  ) {}

  get connected() {
    return this.#socket !== null;
  }

  /**
   * Stay connected: retry while the game isn't up and reconnect after it
   * restarts. Without it, requests connect on demand.
   */
  start(retryMs = 1000) {
    this.#stopped = false;
    this.#retryMs = retryMs;
    this.#attempt();
  }

  close() {
    this.#stopped = true;
    clearTimeout(this.#retry);
    this.#socket?.destroy();
  }

  #attempt = () => {
    if (this.#stopped || this.#socket) return;
    this.#connect().catch(() => this.#scheduleRetry());
  };

  #scheduleRetry() {
    if (this.#stopped) return;
    clearTimeout(this.#retry);
    this.#retry = setTimeout(this.#attempt, this.#retryMs);
  }

  #connect(): Promise<net.Socket> {
    if (this.#socket) return Promise.resolve(this.#socket);
    this.#connecting ??= new Promise<net.Socket>((resolve, reject) => {
      const socket = net.createConnection(this.socketPath);
      socket.setEncoding('utf8');
      socket.once('connect', () => {
        this.#socket = socket;
        this.#connecting = null;
        resolve(socket);
      });
      socket.on('data', (chunk: string) => this.#read(chunk));
      socket.on('error', e => {
        if (this.#socket) return; // 'close' follows
        this.#connecting = null;
        reject(e);
      });
      socket.once('close', () => {
        if (this.#socket !== socket) return;
        this.#socket = null;
        this.#buffer = '';
        // handlers belong to the game run that registered them
        this.handlers.clear();
        for (const [id, p] of this.#pending) {
          clearTimeout(p.timer);
          this.#pending.delete(id);
          p.resolve({ ok: false, error: 'the connection to the game closed' });
        }
        this.#scheduleRetry();
      });
    });
    return this.#connecting;
  }

  #read(chunk: string) {
    this.#buffer += chunk;
    let nl: number;
    while ((nl = this.#buffer.indexOf('\n')) >= 0) {
      const line = this.#buffer.slice(0, nl);
      this.#buffer = this.#buffer.slice(nl + 1);
      let message: Incoming;
      try {
        message = JSON.parse(line) as Incoming;
      } catch {
        this.host?.warn('dropping unreadable message from the game:', line.slice(0, 200));
        continue;
      }
      // an exception escaping here would reach omegga, which stops the server for it
      this.#handle(message).catch(e => this.host?.warn('error handling a message from the game:', e));
    }
  }

  async #handle(message: Incoming) {
    switch (message.t) {
      case 'result': {
        const { t: _t, id, ...reply } = message;
        this.#settle(id, reply);
        return;
      }
      case 'undeliverable':
        if (message.message?.id) {
          this.#settle(message.message.id, { ok: false, error: `no Lua listener ${message.target} (was its mod stopped?)` });
        }
        return;
      case 'register':
        this.handlers.set(message.name, message.mod);
        return;
      case 'event':
        await this.host?.emit(message.event, message.data);
        return;
      case 'call': {
        if (!this.host) return;
        let reply: BridgeReply;
        try {
          // Lua sends an empty table as {}, not [], so anything but a list is no arguments
          const args = Array.isArray(message.args) ? message.args : [];
          reply = { ok: true, result: await this.host.call(message.plugin, message.event, args) };
        } catch (e) {
          reply = { ok: false, error: (e as Error)?.message ?? String(e) };
        }
        this.#write(message.mod, { t: 'reply', id: message.id, ...reply });
        return;
      }
    }
  }

  #settle(id: string, reply: BridgeReply) {
    const p = this.#pending.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    this.#pending.delete(id);
    p.resolve(reply);
  }

  #write(target: string, message: object) {
    // JSON.stringify escapes newlines inside strings, so a message is one line;
    // it drops what JSON can't hold (functions, undefined)
    this.#socket?.write(`${target}\t${JSON.stringify(message)}\n`);
  }

  async #request(target: string, message: object, timeoutMs: number, what: string): Promise<BridgeReply> {
    try {
      await this.#connect();
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code ?? String(e);
      return { ok: false, error: `not connected to the game (${code}); is it running with UE4SS?` };
    }
    const id = `js-${process.pid}-${++this.#requests}`;
    return new Promise<BridgeReply>(resolve => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        resolve({ ok: false, error: `${what} did not answer in ${timeoutMs} ms` });
      }, timeoutMs);
      this.#pending.set(id, { resolve, timer });
      this.#write(target, { ...message, id });
    });
  }

  /** Run Lua in the server. A bare expression is returned; otherwise use `return`. */
  exec(source: string, timeoutMs = 30_000): Promise<BridgeReply> {
    return this.#request(BRIDGE_MOD, { t: 'exec', lua: source }, timeoutMs, 'the bridge');
  }

  /** Like exec, but returns the result and throws the Lua error. */
  async eval<T = unknown>(source: string, timeoutMs?: number): Promise<T> {
    const reply = await this.exec(source, timeoutMs);
    if (!reply.ok) throw new Error(reply.error.split('\n')[0]);
    return reply.result as T;
  }

  /** Call the Lua handler `name` registered with Omegga.handle. */
  callLua(name: string, args: unknown[], timeoutMs = 30_000): Promise<BridgeReply> {
    const mod = this.handlers.get(name);
    if (!mod) return Promise.resolve({ ok: false, error: `no Lua handler named ${name}` });
    return this.#request(mod, { t: 'call', name, args }, timeoutMs, `Lua handler ${name}`);
  }
}

import fs from 'node:fs';
import path from 'node:path';

/**
 * BR.store's tables, kept in this plugin's omegga storage as `lua:<name>`.
 * Lua holds a copy of all of them (it can't wait for omegga on the game
 * thread), fetched with `all` and written back one name at a time.
 */

const NAME = /^[A-Za-z0-9_.-]+$/;
const PREFIX = 'lua:';
// set once the files BR.store used to write have been copied in, so a store a
// mod deletes later isn't brought back from its old file
const IMPORTED = 'lua-store-imported';

/** The part of omegga's PluginStore this needs. */
export interface KeyValueStore {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<void>;
  keys(): Promise<string[]>;
}

function checkName(name: unknown): string {
  if (typeof name !== 'string' || !NAME.test(name) || name.startsWith('.'))
    throw new Error("a store name is letters, digits, '_', '-' and '.'");
  return name;
}

export class LuaStore {
  constructor(private readonly store: KeyValueStore) {}

  /** Lua's `store` call: ("all"), ("set", name, value) or ("delete", name). */
  async handle(args: unknown[]): Promise<unknown> {
    const [op, name, value] = args;
    switch (op) {
      case 'all': {
        const out: Record<string, unknown> = {};
        for (const key of await this.store.keys())
          if (key.startsWith(PREFIX)) out[key.slice(PREFIX.length)] = await this.store.get(key);
        return out;
      }
      case 'set':
        if (typeof value !== 'object' || value === null)
          throw new Error('a store holds a table');
        await this.store.set(PREFIX + checkName(name), value);
        return null;
      case 'delete':
        await this.store.delete(PREFIX + checkName(name));
        return null;
    }
    throw new Error('store op is all, set or delete');
  }

  /**
   * Copy the JSON files BR.store used to keep in `dir` into omegga's storage,
   * once. A name already in storage keeps its value. The files are left where
   * they are.
   */
  async importFiles(dir: string): Promise<number> {
    if (await this.store.get(IMPORTED)) return 0;
    let count = 0;
    const files = fs.existsSync(dir) ? fs.readdirSync(dir) : [];
    for (const file of files) {
      const name = file.endsWith('.json') ? file.slice(0, -5) : '';
      if (!NAME.test(name) || name.startsWith('.')) continue;
      const key = PREFIX + name;
      // omegga's store answers null for a key it doesn't have
      if ((await this.store.get(key)) != null) continue;
      let value: unknown;
      try {
        value = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
      } catch {
        continue;
      }
      if (typeof value !== 'object' || value === null) continue;
      await this.store.set(key, value);
      count++;
    }
    await this.store.set(IMPORTED, true);
    return count;
  }
}

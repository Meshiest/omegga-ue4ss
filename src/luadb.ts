import fs from 'node:fs';
import path from 'node:path';
import type { DatabaseSync, SQLInputValue } from 'node:sqlite';

/**
 * SQLite databases for Lua mods (BR.db), one file per name in one directory;
 * neither the name nor the SQL can reach a file outside it. Lua can't wait on the
 * socket from the game thread, so every call answers through a callback; the
 * queries themselves run here, synchronously, in omegga's process.
 */

const NAME = /^[A-Za-z0-9_.-]+$/;

// SQLite's authorizer action and result codes, fixed by its C API (sqlite3.h).
// @types/node doesn't list them, and omegga's node may predate the constants.
const SQLITE_OK = 0;
const SQLITE_DENY = 1;
const SQLITE_PRAGMA = 19;
const SQLITE_ATTACH = 24;
const SQLITE_DETACH = 25;

// Pragmas that only read the schema or set per-connection behaviour. The rest
// can touch files (temp_store_directory) or settings the bridge relies on.
const PRAGMAS = new Set([
  'foreign_keys',
  'foreign_key_list',
  'index_info',
  'index_list',
  'index_xinfo',
  'table_info',
  'table_list',
  'table_xinfo',
  'user_version',
]);

declare module 'node:sqlite' {
  interface DatabaseSync {
    /**
     * Missing from the @types/node this builds against, and from older Nodes.
     * better-sqlite3 (OMEGGA_UTIL.Sqlite) has no equivalent, which is why this
     * uses node:sqlite.
     */
    setAuthorizer?(
      fn: ((action: number, a: string | null, b: string | null, db: string | null, trigger: string | null) => number) | null,
    ): void;
  }
}

/**
 * Whether a statement may run: no ATTACH (which `VACUUM INTO` also goes
 * through) or DETACH, so a mod's SQL can't create or open a file outside its
 * own database, and only the pragmas in PRAGMAS.
 */
export function authorize(action: number, a: string | null): number {
  if (action === SQLITE_ATTACH || action === SQLITE_DETACH) return SQLITE_DENY;
  if (action === SQLITE_PRAGMA) return a !== null && PRAGMAS.has(a.toLowerCase()) ? SQLITE_OK : SQLITE_DENY;
  return SQLITE_OK;
}

export type SqlOp = 'query' | 'run' | 'exec';

export interface SqlRequest {
  name: string;
  op: SqlOp;
  sql: string;
  params: SQLInputValue[];
}

/** The request `args` describe (from Lua: name, op, sql, params), or why not. */
export function parseSql(args: unknown[]): SqlRequest | string {
  const [name, op, sql, params] = args;
  if (typeof name !== 'string' || !NAME.test(name) || name.startsWith('.'))
    return "a database name is letters, digits, '_', '-' and '.'";
  if (op !== 'query' && op !== 'run' && op !== 'exec') return 'op is query, run or exec';
  if (typeof sql !== 'string' || !sql.trim()) return 'no SQL';
  // Lua sends an empty table as {}, so anything but a list is no parameters
  const list = Array.isArray(params) ? params : [];
  const values: SQLInputValue[] = [];
  for (const p of list) {
    if (p === null || typeof p === 'number' || typeof p === 'string') values.push(p);
    else if (typeof p === 'boolean') values.push(p ? 1 : 0);
    else return `a parameter is a number, string, boolean or nil, not ${typeof p}`;
  }
  return { name, op, sql, params: values };
}

let sqlite: typeof import('node:sqlite') | undefined;

/**
 * node:sqlite, loaded the first time a mod opens a database rather than when
 * the plugin starts. Node warns that it is experimental as it loads, and omegga
 * runs with --trace-warnings, so that one warning (only that one) is dropped.
 */
function loadSqlite(): typeof import('node:sqlite') {
  if (sqlite) return sqlite;
  const emitWarning = process.emitWarning;
  process.emitWarning = (warning: string | Error, ...rest: unknown[]) => {
    const text = typeof warning === 'string' ? warning : warning.message;
    if (text.startsWith('SQLite is an experimental feature')) return;
    Reflect.apply(emitWarning, process, [warning, ...rest]);
  };
  try {
    sqlite = process.getBuiltinModule('node:sqlite');
  } finally {
    process.emitWarning = emitWarning;
  }
  return sqlite;
}

export class LuaDatabases {
  readonly #open = new Map<string, DatabaseSync>();

  constructor(private readonly dir: string) {}

  #db(name: string) {
    let db = this.#open.get(name);
    if (!db) {
      fs.mkdirSync(this.dir, { recursive: true });
      db = new (loadSqlite().DatabaseSync)(path.join(this.dir, `${name}.sqlite`), { allowExtension: false });
      if (typeof db.setAuthorizer !== 'function') {
        db.close();
        throw new Error(`BR.db needs node:sqlite's setAuthorizer, which Node ${process.version} lacks, to keep SQL inside its own file`);
      }
      // readers don't block the writer, and a crash mid-write keeps the file
      // whole. Set before the authorizer, which refuses this pragma.
      db.exec('PRAGMA journal_mode = WAL');
      db.setAuthorizer(authorize);
      this.#open.set(name, db);
    }
    return db;
  }

  /**
   * query: the rows; run: `{ changes, last_id }`; exec: runs a script of
   * statements (a schema) and returns nothing.
   */
  run(req: SqlRequest): unknown {
    const db = this.#db(req.name);
    if (req.op === 'exec') {
      db.exec(req.sql);
      return null;
    }
    const stmt = db.prepare(req.sql);
    if (req.op === 'query') return stmt.all(...req.params);
    const r = stmt.run(...req.params);
    return { changes: Number(r.changes), last_id: Number(r.lastInsertRowid) };
  }

  close() {
    for (const db of this.#open.values()) db.close();
    this.#open.clear();
  }
}

import fs from 'node:fs';
import path from 'node:path';

/**
 * Commands Lua mods declare in `<mods dir>/<Mod>/doc.json`, shaped like an
 * omegga plugin's (name, description, example, args): `commands` for chat,
 * `consoleCommands` for omegga's console. omegga registers them for this
 * plugin and hands a typed one over, which calls the mod's
 * `Omegga.on("cmd:<name>", fn)` or `Omegga.on("consolecmd:<name>", fn)`.
 */

export interface ConsoleCommandArg {
  name: string;
  description: string;
  required?: boolean;
}

export interface ConsoleCommand {
  name: string;
  description: string;
  example?: string;
  args: ConsoleCommandArg[];
}

export interface ModConsoleCommand {
  mod: string;
  command: ConsoleCommand;
}

const NAME = /^[A-Za-z0-9_-]+$/;

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** One declared command, or undefined when it can't be used. */
export function parseCommand(v: unknown): ConsoleCommand | undefined {
  if (!isRecord(v) || typeof v.name !== 'string') return undefined;
  const name = v.name.replace(/^\//, '').toLowerCase();
  if (!NAME.test(name)) return undefined;
  const args: ConsoleCommandArg[] = [];
  for (const a of Array.isArray(v.args) ? v.args : []) {
    if (!isRecord(a) || typeof a.name !== 'string') continue;
    args.push({
      name: a.name,
      description: typeof a.description === 'string' ? a.description : '',
      required: a.required === true,
    });
  }
  return {
    name,
    description: typeof v.description === 'string' ? v.description : '',
    ...(typeof v.example === 'string' ? { example: v.example } : {}),
    args,
  };
}

export type CommandList = 'commands' | 'consoleCommands';

/**
 * The commands every mod in `dirs` declares in its doc.json's `list`, in
 * folder order. A doc.json that doesn't parse is reported through `warn` and
 * skipped; a name a mod earlier in the list already took is skipped with a
 * warning too.
 */
export function readModCommands(
  dirs: string[],
  warn: (...args: unknown[]) => void,
  list: CommandList = 'consoleCommands',
): ModConsoleCommand[] {
  const out: ModConsoleCommand[] = [];
  const taken = new Map<string, string>();
  for (const dir of dirs) {
    let mods: fs.Dirent[];
    try {
      mods = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of mods.filter(e => e.isDirectory()).sort((a, b) => a.name.localeCompare(b.name))) {
      const file = path.join(dir, entry.name, 'doc.json');
      if (!fs.existsSync(file)) continue;
      let doc: unknown;
      try {
        doc = JSON.parse(fs.readFileSync(file, 'utf8'));
      } catch (e) {
        warn(`${file} isn't valid JSON:`, e instanceof Error ? e.message : e);
        continue;
      }
      const declared = isRecord(doc) ? doc[list] : undefined;
      for (const raw of Array.isArray(declared) ? declared : []) {
        const command = parseCommand(raw);
        if (!command) continue;
        const owner = taken.get(command.name);
        if (owner) {
          warn(`/${command.name} from mod ${entry.name} is skipped: mod ${owner} declares it too`);
          continue;
        }
        taken.set(command.name, entry.name);
        out.push({ mod: entry.name, command });
      }
    }
  }
  return out;
}

/** A handler's answer as console lines: text, a list of lines, or JSON. */
export function outputLines(result: unknown): string[] {
  if (result === undefined || result === null) return [];
  if (typeof result === 'string') return result.split('\n');
  if (Array.isArray(result) && result.every(r => typeof r === 'string')) return result;
  if (typeof result === 'number' || typeof result === 'boolean') return [String(result)];
  return JSON.stringify(result, null, 2).split('\n');
}

import fs from 'node:fs';

/** A Lua mod error found in UE4SS.log. */
export interface ModError {
  /** the mod's folder name, when the error names a file under Mods/<name>/ */
  mod?: string;
  /** a mod whose main.lua failed, so it isn't running at all */
  failedToStart: boolean;
  message: string;
}

// every UE4SS log line starts with its time; a line without one continues the
// one before (a traceback)
const STAMP = /^\[\d{4}-\d\d-\d\d [\d:.]+\] /;

// Mods/<name>/ (the server's mods) or <plugin>/mods/<name>/; Mods/shared is
// the BR library itself, not a mod
function modOf(text: string): string | undefined {
  const name = /[/\\]mods[/\\]([^/\\]+)[/\\]/i.exec(text)?.[1];
  return name === 'shared' ? undefined : name;
}

/**
 * Picks mod errors out of UE4SS.log lines, fed in order:
 * - a main.lua that raised: UE4SS logs "Error executing script: <error>", the
 *   traceback, then "Failed to execute main script: <path>". The mod isn't
 *   running, which is the case worth shouting about.
 * - a callback a BR module caught (an event handler, a timer): "[Lua] [BR error] ...",
 *   written by the Lua side's I.report.
 * - a callback UE4SS itself ran (RegisterHook, ExecuteInGameThread):
 *   "lua_pcall returned LUA_ERRRUN => <error>".
 */
export class ModLogParser {
  #script: string[] | null = null;

  /** Feed one line; returns the errors it completes. */
  line(raw: string): ModError[] {
    const line = raw.replace(/\r$/, '');
    if (!STAMP.test(line)) {
      if (this.#script && line.trim()) this.#script.push(line.trimEnd());
      return [];
    }
    const text = line.replace(STAMP, '');
    const out: ModError[] = [];
    if (this.#script && !text.startsWith('Failed to execute main script: ')) {
      // an error UE4SS logged without the closing line: report it as it was
      out.push(this.#flushScript(false));
    }
    if (text.startsWith('Error executing script: ')) {
      this.#script = [text.slice('Error executing script: '.length)];
    } else if (text.startsWith('Failed to execute main script: ')) {
      const path = text.slice('Failed to execute main script: '.length);
      const err = this.#script
        ? this.#flushScript(true)
        : { failedToStart: true, message: path };
      err.mod ??= modOf(path);
      out.push(err);
    } else if (text.startsWith('[Lua] [BR error] ')) {
      const message = text.slice('[Lua] [BR error] '.length);
      out.push({ mod: modOf(message), failedToStart: false, message });
    } else {
      const m = /lua_pcall returned LUA_ERR\w+ => (.*)$/.exec(text);
      if (m) out.push({ mod: modOf(m[1]), failedToStart: false, message: m[1] });
    }
    return out;
  }

  #flushScript(failedToStart: boolean): ModError {
    const lines = this.#script ?? [];
    this.#script = null;
    const message = lines.join('\n');
    return { mod: modOf(message), failedToStart, message };
  }
}

/** How long a repeated error stays quiet: a broken tick handler fails every frame. */
const REPEAT_MS = 60_000;

/**
 * Follows UE4SS.log and passes each mod error to `report`, so a broken mod
 * shows in omegga's log instead of only in a file nobody is reading. The game
 * starts a fresh UE4SS.log every launch; that is noticed by the first line
 * changing, and reading starts over. Errors already in the file when this
 * starts are skipped. The same message within a minute is counted, not
 * repeated.
 */
export class ModLogWatcher {
  #offset = 0;
  #head = '';
  #partial = '';
  #parser = new ModLogParser();
  #recent = new Map<string, { at: number; quiet: number }>();
  #timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly file: string,
    private readonly report: (err: ModError, repeats: number) => void,
  ) {}

  start(intervalMs = 1000) {
    if (this.#timer) return;
    this.#skipExisting();
    this.#timer = setInterval(() => this.poll(), intervalMs);
    this.#timer.unref();
  }

  stop() {
    if (this.#timer) clearInterval(this.#timer);
    this.#timer = null;
  }

  #readHead(fd: number): string {
    const buf = Buffer.alloc(64);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    return buf.subarray(0, n).toString('utf8');
  }

  #skipExisting() {
    try {
      const fd = fs.openSync(this.file, 'r');
      try {
        this.#head = this.#readHead(fd);
        this.#offset = fs.fstatSync(fd).size;
      } finally {
        fs.closeSync(fd);
      }
    } catch {
      // no log yet: the game hasn't started, so everything to come is new
    }
  }

  poll() {
    let fd: number;
    try {
      fd = fs.openSync(this.file, 'r');
    } catch {
      return;
    }
    try {
      const head = this.#readHead(fd);
      const size = fs.fstatSync(fd).size;
      if (head !== this.#head || size < this.#offset) {
        this.#head = head;
        this.#offset = 0;
        this.#partial = '';
        this.#parser = new ModLogParser();
      }
      if (size <= this.#offset) return;
      const buf = Buffer.alloc(size - this.#offset);
      fs.readSync(fd, buf, 0, buf.length, this.#offset);
      this.#offset = size;
      const lines = (this.#partial + buf.toString('utf8')).split('\n');
      this.#partial = lines.pop() ?? '';
      for (const line of lines)
        for (const err of this.#parser.line(line)) this.#emit(err);
    } finally {
      fs.closeSync(fd);
    }
  }

  #emit(err: ModError) {
    const now = Date.now();
    const seen = this.#recent.get(err.message);
    if (seen && now - seen.at < REPEAT_MS) {
      seen.quiet++;
      return;
    }
    this.#recent.set(err.message, { at: now, quiet: 0 });
    this.report(err, seen?.quiet ?? 0);
    if (this.#recent.size > 500) {
      for (const [k, v] of this.#recent)
        if (now - v.at >= REPEAT_MS) this.#recent.delete(k);
    }
  }
}

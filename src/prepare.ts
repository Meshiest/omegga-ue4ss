import fs from 'node:fs';
import path from 'node:path';
import { Elf } from './elf';
import type { Log } from './log';
import { formatReport, type SymbolReport, usable, verifySignatures, writeSignatures } from './verify';
import { buildChangelist } from './version';
import { checkRuntime } from './runtime';
import { checkVTables, parseVTableOffsets, type VTableCheck } from './vtables';

export interface PrepareOptions {
  /** omegga's data directory */
  dataDir: string;
  /** this plugin's directory */
  pluginDir: string;
  /** the game binary omegga will launch, when it can tell */
  gameBinary: string | null;
  /** mod folders of other plugins to load as well (see Ue4ssPlugin.pluginModDirs) */
  extraModDirs?: string[];
  log: Log;
}

export interface PrepareResult {
  ready: boolean;
  reason: string;
  reports: SymbolReport[];
  vtables: VTableCheck[];
}

/** Signature results by symbol, for checks that build on them. */
export function addresses(reports: SymbolReport[]) {
  const out: Record<string, number | undefined> = {};
  for (const r of reports) if (r.status !== 'unresolved' && r.status !== 'conflict') out[r.symbol] = r.address;
  return out;
}

/** Where everything UE4SS reads and writes at run time lives. */
export const ue4ssDir = (dataDir: string) => path.join(dataDir, 'UE4SS');

/** Where the BrickadiaBridge C++ mod listens (doc.json passes it as OMEGGA_UE4SS_SOCKET). */
export const socketPath = (dataDir: string) => path.join(ue4ssDir(dataDir), 'bridge.sock');

/**
 * Where UE4SS's GenerateLuaTypes() writes its LuaLS annotations for every loaded
 * class. The generator first deletes every .lua file here, so nothing else may
 * live in it.
 */
export const gameTypesDir = (dataDir: string) => path.join(ue4ssDir(dataDir), 'Mods', 'shared', 'types');

/** Names the game binary the generated types were made from. */
export const gameTypesStamp = (dataDir: string) => path.join(gameTypesDir(dataDir), '.binary');

/**
 * data/Mods/.luarc.json for Lua Language Server, so opening data/Mods in an
 * editor completes this plugin's API and every game class. Written only when
 * absent: an owner's own settings win, and they can delete it to get it back.
 */
export function writeEditorConfig(dataDir: string, pluginDir: string) {
  const file = path.join(dataDir, 'Mods', '.luarc.json');
  if (fs.existsSync(file)) return false;
  const config = {
    'runtime.version': 'Lua 5.4',
    // require("omegga.brickadia") resolves through shared/ in game too
    'runtime.path': ['?.lua', '?/init.lua', 'shared/?.lua', 'shared/?/?.lua'],
    'workspace.library': [path.join(pluginDir, 'types'), gameTypesDir(dataDir)],
    // the generated Engine.lua and Brickadia.lua are about 1 MB each, over the
    // default 500 KB at which LuaLS skips a file
    'workspace.preloadFileSize': 4096,
  };
  writeAtomic(file, `${JSON.stringify(config, null, 2)}\n`);
  return true;
}

/**
 * Longest socket path the mod can bind: sun_path holds 107 bytes, and the mod
 * binds `<path>.tmp-<pid>` first (pids are at most 7 digits) before renaming.
 */
export const SOCKET_PATH_MAX = 107 - '.tmp-'.length - 7;

/**
 * Identity of a game binary for the ready marker. launch.sh recomputes the same
 * string with readlink/stat, so a Steam update between prepare and launch makes
 * them differ and the game starts without UE4SS instead of with stale addresses.
 */
export function binaryIdentity(binary: string) {
  const real = fs.realpathSync(binary);
  const st = fs.statSync(real);
  return `${real} ${st.size} ${Math.floor(st.mtimeMs / 1000)}`;
}

/**
 * Replace `dest` atomically. The running game maps libUE4SS.so and the bridge's
 * main.so; overwriting them in place would change code under it, while a rename
 * leaves the old inode alive until the process exits.
 */
function install(src: string, dest: string, mode?: number) {
  const s = fs.statSync(src);
  if (fs.existsSync(dest)) {
    const d = fs.statSync(dest);
    if (d.size === s.size && d.mtimeMs === s.mtimeMs) return;
  }
  const tmp = `${dest}.tmp-${process.pid}`;
  fs.copyFileSync(src, tmp);
  fs.utimesSync(tmp, s.atime, s.mtime);
  if (mode !== undefined) fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, dest);
}

/**
 * Make `link` a symlink to directory `target`. Whatever is at `link` is
 * replaced: it is generated, an older copy or link of the same files.
 */
function linkDir(target: string, link: string) {
  const current = fs.lstatSync(link, { throwIfNoEntry: false });
  if (current?.isSymbolicLink() && fs.readlinkSync(link) === target) return;
  if (current) fs.rmSync(link, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(link), { recursive: true });
  fs.symlinkSync(target, link, 'dir');
}

function writeAtomic(dest: string, text: string) {
  const tmp = `${dest}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, dest);
}

/**
 * UE4SS-settings.ini from the shipped template, with the mod folders pointed at
 * omegga's data/Mods (the server owner's mods) plus this plugin's mods/.
 */
function settings(template: string, dataDir: string, modDirs: string[]) {
  const lines = template.split(/\r?\n/);
  const at = lines.findIndex(l => /^\s*ModsFolderPath\s*=/.test(l));
  if (at < 0) throw new Error('settings template has no ModsFolderPath line');
  lines[at] = `ModsFolderPath = ${path.join(dataDir, 'Mods')}`;
  lines.splice(at + 1, 0, ...modDirs.map(d => `+ModsFolderPaths = ${d}`));
  return lines.join('\n');
}

/**
 * Build data/UE4SS for the coming launch. Never throws for an unusable setup:
 * it reports why and clears the ready marker, and launch.sh then starts the
 * game without UE4SS.
 */
export async function prepare(opts: PrepareOptions): Promise<PrepareResult> {
  const dir = ue4ssDir(opts.dataDir);
  const marker = path.join(dir, 'ready');
  fs.mkdirSync(dir, { recursive: true });
  fs.mkdirSync(path.join(opts.dataDir, 'Mods'), { recursive: true });
  fs.rmSync(marker, { force: true });
  fs.rmSync(path.join(dir, 'build-cl'), { force: true });

  const fail = (reason: string, reports: SymbolReport[] = [], vtables: VTableCheck[] = []): PrepareResult => ({
    ready: false,
    reason,
    reports,
    vtables,
  });

  if (!opts.gameBinary || !fs.existsSync(opts.gameBinary))
    return fail('omegga could not tell which game binary it will launch');

  let runtime: string;
  try {
    runtime = checkRuntime(opts.pluginDir, opts.log);
  } catch (e) {
    return fail((e as Error).message);
  }

  const overlay = path.join(opts.pluginDir, 'overlay');
  install(path.join(runtime, 'libUE4SS.so'), path.join(dir, 'libUE4SS.so'), 0o755);
  install(path.join(opts.pluginDir, 'bin', 'run_ue4ss.sh'), path.join(dir, 'run_ue4ss.sh'), 0o755);
  for (const f of ['MemberVariableLayout.ini', 'VTableLayout.ini', 'VTableOffsets.linux.ini'])
    install(path.join(overlay, f), path.join(dir, f));
  writeAtomic(
    path.join(dir, 'UE4SS-settings.ini'),
    settings(fs.readFileSync(path.join(overlay, 'UE4SS-settings.ini'), 'utf8'), opts.dataDir, [
      path.join(opts.pluginDir, 'mods'),
      ...(opts.extraModDirs ?? []),
    ]),
  );
  // shared Lua libraries for every mod: require("omegga"), require("omegga.brickadia")
  // resolve through UE4SS's `<mods>/shared/?/?.lua` and `shared/?.lua` paths. A
  // link rather than a copy, so the game always runs the plugin's own Lua: an edit
  // or update is live after a BR_RELOAD, and nothing stale is left behind
  linkDir(path.join(opts.pluginDir, 'lua', 'omegga'), path.join(opts.dataDir, 'Mods', 'shared', 'omegga'));

  const dlls = path.join(opts.pluginDir, 'mods', 'BrickadiaBridge', 'dlls');
  fs.mkdirSync(dlls, { recursive: true });
  install(path.join(runtime, 'BrickadiaBridge', 'main.so'), path.join(dlls, 'main.so'), 0o755);

  const identity = binaryIdentity(opts.gameBinary);
  const elf = new Elf(opts.gameBinary);
  // launch.sh turns this into Brickadia's crash reporter switch, which only
  // applies with the binary's own changelist; written even when UE4SS won't load
  const cl = buildChangelist(elf.data);
  if (cl !== null) fs.writeFileSync(path.join(dir, 'build-cl'), `${identity}\n${cl}\n`);
  else {
    fs.rmSync(path.join(dir, 'build-cl'), { force: true });
    opts.log.warn('could not read the game changelist; crash reports may be uploaded');
  }
  const reports = verifySignatures(elf, path.join(overlay, 'UE4SS_Signatures'));
  writeSignatures(reports, path.join(overlay, 'UE4SS_Signatures'), path.join(dir, 'UE4SS_Signatures'));
  const vtables = checkVTables(
    elf,
    parseVTableOffsets(fs.readFileSync(path.join(overlay, 'VTableOffsets.linux.ini'), 'utf8')),
    addresses(reports),
  );
  const vtableText = vtables.map(v => `${v.ok ? 'verified' : 'FAILED  '}   ${v.name.padEnd(32)} 0x${v.offset.toString(16).padEnd(10)} ${v.note}`);
  fs.writeFileSync(path.join(dir, 'signatures.txt'), `${identity}\n${formatReport(reports)}\n${vtableText.join('\n')}\n`);

  if (writeEditorConfig(opts.dataDir, opts.pluginDir)) opts.log.info('Wrote data/Mods/.luarc.json for Lua editor completion');

  if (!usable(reports)) return fail('a required signature is unresolved (see data/UE4SS/signatures.txt)', reports, vtables);
  if (vtables.length < 3 || vtables.some(v => !v.ok))
    return fail('a vtable offset does not match this binary (see data/UE4SS/signatures.txt)', reports, vtables);
  fs.writeFileSync(marker, identity);
  return { ready: true, reason: 'ready', reports, vtables };
}

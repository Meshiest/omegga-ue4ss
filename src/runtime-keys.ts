import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

// Shared by the plugin (the start-time check, src/runtime.ts) and the tools that
// fetch and publish the binaries (tools/fetch-runtime.ts, tools/runtime-keys.ts).
// The tools run this file with Node's type stripping, so it must import no other
// module of this repo and use only erasable TypeScript.

/**
 * Content keys for the two native binaries, so a checkout downloads exactly the
 * builds made from its own source, and CI builds only what a release lacks.
 *
 * - `ue4ss` covers what libUE4SS.so is built from: the pinned base commits and
 *   patches for the Linux port, and build.sh (its compiler flags).
 * - `mod` covers BrickadiaBridge's sources plus the ue4ss key: main.so links
 *   against libUE4SS.so and is compiled against its headers, so it only works
 *   with the UE4SS build it was made with.
 */
export interface RuntimeKeys {
  ue4ss: string;
  mod: string;
}

const KEY_LENGTH = 16;

function filesUnder(root: string, rel: string): string[] {
  const full = path.join(root, rel);
  if (!fs.statSync(full).isDirectory()) return [rel];
  return fs.readdirSync(full).flatMap(name => filesUnder(root, path.posix.join(rel, name)));
}

// each file contributes its repo-relative path and bytes, in a fixed order, so
// the key is the same on any machine with the same checkout
function hashFiles(root: string, rels: string[], prefix = ''): string {
  const h = crypto.createHash('sha256').update(prefix);
  const files = rels.flatMap(rel => filesUnder(root, rel)).sort();
  for (const rel of files) {
    h.update(rel).update('\0').update(fs.readFileSync(path.join(root, rel))).update('\0');
  }
  return h.digest('hex').slice(0, KEY_LENGTH);
}

/** The keys for the checkout at `pluginDir`. */
export function runtimeKeys(pluginDir: string): RuntimeKeys {
  const ue4ss = hashFiles(pluginDir, ['native/patches', 'native/build.sh']);
  const mod = hashFiles(pluginDir, ['native/BrickadiaBridge'], `${ue4ss}\0`);
  return { ue4ss, mod };
}

/** Release asset names for the binaries with these keys. */
export const runtimeAssets = (keys: RuntimeKeys) => ({
  ue4ss: `libUE4SS-${keys.ue4ss}.so`,
  mod: `BrickadiaBridge-${keys.mod}.so`,
});

/**
 * native/build.sh leaves this in runtime/: binaries built from the local source,
 * which a download must never replace.
 */
export const LOCAL_MARKER = '.local';

/** Which keys the downloaded binaries in runtime/ were built from. */
export const STAMP = 'keys.json';

export const runtimeDir = (pluginDir: string) => path.join(pluginDir, 'runtime');

/** Where each binary lives in runtime/. */
export function runtimeFiles(pluginDir: string): RuntimeKeys {
  const dir = runtimeDir(pluginDir);
  return {
    ue4ss: path.join(dir, 'libUE4SS.so'),
    mod: path.join(dir, 'BrickadiaBridge', 'main.so'),
  };
}

/** The keys recorded for the installed binaries; empty when there are none. */
export function readStamp(pluginDir: string): Partial<RuntimeKeys> {
  let v: unknown;
  try {
    v = JSON.parse(fs.readFileSync(path.join(runtimeDir(pluginDir), STAMP), 'utf8'));
  } catch {
    return {};
  }
  const field = (key: string) => {
    const x: unknown = typeof v === 'object' && v !== null ? Object.getOwnPropertyDescriptor(v, key)?.value : undefined;
    return typeof x === 'string' ? x : undefined;
  };
  return { ue4ss: field('ue4ss'), mod: field('mod') };
}

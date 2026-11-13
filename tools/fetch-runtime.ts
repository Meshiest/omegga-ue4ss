// Downloads the native binaries this checkout's source needs into runtime/.
// setup.sh runs it, which omegga does on `omegga install` and on every plugin
// update; a failure warns without failing the install, and the server start
// then reports what's missing.
//
//   node tools/fetch-runtime.ts [plugin dir]     (RUNTIME_BASE_URL overrides the host)
//
// Run by Node directly (type stripping), not built: it's not part of the plugin.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  LOCAL_MARKER,
  readStamp,
  runtimeAssets,
  runtimeDir,
  runtimeFiles,
  runtimeKeys,
  STAMP,
} from '../src/runtime-keys.ts';

/** Where CI publishes the binaries. */
export const DEFAULT_RUNTIME_BASE_URL =
  'https://github.com/Meshiest/omegga-ue4ss/releases/download/runtime';

interface Log {
  info(...args: unknown[]): void;
}

/** A binary for this source isn't in the release (yet). */
export class NotPublished extends Error {}

async function download(url: string): Promise<Buffer> {
  const res = await fetch(url);
  if (res.status === 404) throw new NotPublished(`not published yet: ${url}`);
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return Buffer.from(await res.arrayBuffer());
}

/**
 * Download the binaries runtime/ lacks for this source, only those (a mod-only
 * update fetches only main.so). Every one is downloaded before any is
 * installed, so a failure leaves the installed pair as it was: a main.so never
 * runs against a libUE4SS.so it wasn't built with. Leaves a local build
 * (native/build.sh) alone. Returns the names fetched.
 */
export async function fetchRuntime(
  pluginDir: string,
  baseUrl: string,
  log: Log,
): Promise<string[]> {
  const dir = runtimeDir(pluginDir);
  if (fs.existsSync(path.join(dir, LOCAL_MARKER))) return [];
  const keys = runtimeKeys(pluginDir);
  const assets = runtimeAssets(keys);
  const files = runtimeFiles(pluginDir);
  const stamp = readStamp(pluginDir);
  const names = ['ue4ss', 'mod'] as const;
  const stale = names.filter(
    n => stamp[n] !== keys[n] || !fs.existsSync(files[n]),
  );

  const fetched: { name: (typeof names)[number]; bytes: Buffer }[] = [];
  for (const name of stale) {
    const url = `${baseUrl.replace(/\/+$/, '')}/${assets[name]}`;
    log.info('Downloading', url);
    fetched.push({ name, bytes: await download(url) });
  }
  // each file is replaced by a rename: a running game maps them
  for (const { name, bytes } of fetched) {
    fs.mkdirSync(path.dirname(files[name]), { recursive: true });
    const tmp = `${files[name]}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, bytes, { mode: 0o755 });
    fs.renameSync(tmp, files[name]);
  }
  if (fetched.length) {
    const tmp = path.join(dir, `${STAMP}.tmp-${process.pid}`);
    fs.writeFileSync(
      tmp,
      `${JSON.stringify({ ue4ss: keys.ue4ss, mod: keys.mod }, null, 2)}\n`,
    );
    fs.renameSync(tmp, path.join(dir, STAMP));
  }
  return fetched.map(f => f.name);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const pluginDir = path.resolve(
    process.argv[2] ??
      path.join(path.dirname(fileURLToPath(import.meta.url)), '..'),
  );
  const log = { info: (...a: unknown[]) => console.log('[ue4ss]', ...a) };
  fetchRuntime(
    pluginDir,
    process.env.RUNTIME_BASE_URL || DEFAULT_RUNTIME_BASE_URL,
    log,
  ).then(
    fetched => {
      if (!fetched.length) log.info('The native runtime needs no download');
    },
    (e: Error) => {
      console.warn('[ue4ss] Could not fetch the native runtime:', e.message);
      if (e instanceof NotPublished) {
        // a fresh push: CI publishes the binaries for each commit on main a
        // little after it lands
        console.warn(
          [
            '[ue4ss] CI is probably still building the binaries for this version: a few minutes',
            '[ue4ss] for a mod change, much longer when UE4SS itself changed. Progress:',
            '[ue4ss]   https://github.com/Meshiest/omegga-ue4ss/actions',
            '[ue4ss] When it finishes, download them and restart the server:',
            `[ue4ss]   cd ${pluginDir} && node --experimental-strip-types tools/fetch-runtime.ts`,
            '[ue4ss] Until then the server keeps the binaries it has, or starts without UE4SS.',
          ].join('\n'),
        );
      }
    },
  );
}

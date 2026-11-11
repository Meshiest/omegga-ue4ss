import fs from 'node:fs';
import path from 'node:path';
import type { Log } from './log';
import { LOCAL_MARKER, readStamp, runtimeDir, runtimeFiles, runtimeKeys } from './runtime-keys';

/**
 * runtime/ for a server start: the two native binaries, libUE4SS.so and the
 * BrickadiaBridge mod's main.so. setup.sh (tools/fetch-runtime.ts) downloads
 * them when the plugin is installed or updated, the only time the source they
 * must match changes, so this only checks, without the network. Throws when a
 * binary is missing, and warns when the installed pair was built from other
 * source (an update whose binaries weren't published yet when setup.sh ran),
 * which still works but may lack what newer Lua calls.
 */
export function checkRuntime(pluginDir: string, log: Log): string {
  const dir = runtimeDir(pluginDir);
  const files = runtimeFiles(pluginDir);
  const missing = [files.ue4ss, files.mod].filter(f => !fs.existsSync(f));
  if (missing.length) {
    throw new Error(`runtime/ lacks ${missing.join(', ')}; run the plugin's setup.sh, or native/build.sh`);
  }
  if (fs.existsSync(path.join(dir, LOCAL_MARKER))) return dir;
  const keys = runtimeKeys(pluginDir);
  const stamp = readStamp(pluginDir);
  if (stamp.ue4ss !== keys.ue4ss || stamp.mod !== keys.mod) {
    log.warn("The native runtime was built from other source than this plugin's; run setup.sh to update it");
  }
  return dir;
}

/** The part of omegga's Logger used here. */
interface OmeggaLogger {
  log(...args: unknown[]): void;
  warn(...args: unknown[]): void;
}

declare global {
  // omegga sets this in its own process, where unsafe plugins run; it writes
  // to the console and omegga's log file (which strips the colours)
  var Logger: OmeggaLogger | undefined;
}

// the same `name >>` prefix omegga gives sandboxed plugins' console output
const NAME = '\x1b[4mue4ss\x1b[24m';
const INFO = '\x1b[32m>>\x1b[39m';
const WARN = '\x1b[33m>>\x1b[39m';

/**
 * Plugin output through omegga's Logger. An unsafe plugin's console.log goes
 * straight to stdout and misses omegga's log file. Falls back to the console
 * where there is no omegga (unit tests, the dev CLIs).
 */
export const log = {
  info(...args: unknown[]) {
    if (globalThis.Logger) globalThis.Logger.log(NAME, INFO, ...args);
    else console.log('[ue4ss]', ...args);
  },
  warn(...args: unknown[]) {
    if (globalThis.Logger) globalThis.Logger.warn(NAME, WARN, ...args);
    else console.warn('[ue4ss]', ...args);
  },
};

export type Log = typeof log;

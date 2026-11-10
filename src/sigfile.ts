import fs from 'node:fs';
import path from 'node:path';
import { type Elf } from './elf';
import { Pattern } from './pattern';

/**
 * A UE4SS_Signatures/*.lua file, understood well enough to evaluate offline.
 *
 * Supported shapes (the ones this plugin ships and writes):
 * - `Register()` returns a pattern; `OnMatchFound` returns `MatchAddress`
 * - `OnMatchFound` decodes a RIP-relative operand:
 *     `local Insn = MatchAddress + N` ... `return Insn + L + DerefToInt32(Insn + D)`
 * - `return MatchAddress + L + DerefToInt32(MatchAddress + D) - K`
 * - a pinned file whose chunk is just `return 0xADDRESS`
 */
export interface SignatureFile {
  symbol: string;
  file: string;
  pattern?: Pattern;
  pinned?: number;
  evaluate?: (match: number, elf: Elf) => number;
}

function evaluator(body: string): SignatureFile['evaluate'] {
  if (/return\s+MatchAddress\s*\n/.test(body)) return m => m;
  const base = body.match(/local\s+Insn\s*=\s*MatchAddress\s*\+\s*(\d+)/);
  const ret = body.match(
    /return\s+Insn\s*\+\s*(\d+)\s*\+\s*DerefToInt32\(Insn\s*\+\s*(\d+)\)/,
  );
  if (base && ret) {
    const [n, len, disp] = [Number(base[1]), Number(ret[1]), Number(ret[2])];
    return (m, elf) => m + n + len + elf.i32(m + n + disp);
  }
  const inline = body.match(
    /return\s+MatchAddress\s*\+\s*(\d+)\s*\+\s*DerefToInt32\(MatchAddress\s*\+\s*(\d+)\)\s*-\s*(\d+)/,
  );
  if (inline) {
    const [len, disp, k] = inline.slice(1).map(Number);
    return (m, elf) => m + len + elf.i32(m + disp) - k;
  }
  return undefined;
}

const stripComments = (lua: string) => lua.replace(/--.*$/gm, '');

export function readSignatureFile(file: string): SignatureFile {
  const symbol = path.basename(file, '.lua');
  const lua = stripComments(fs.readFileSync(file, 'utf8'));

  const pinned = lua.trim().match(/^return\s+(0x[0-9a-fA-F]+|\d+)\s*$/);
  if (pinned) return { symbol, file, pinned: Number(pinned[1]) };

  const [register, onMatch = ''] = lua.split(/function\s+OnMatchFound/);
  const pattern = register.match(/return\s+"([0-9A-Fa-f? ]+)"/);
  if (!pattern) throw new Error(`${file}: no pattern returned by Register()`);
  const evaluate = evaluator(onMatch);
  if (!evaluate) throw new Error(`${file}: unsupported OnMatchFound`);
  return { symbol, file, pattern: new Pattern(pattern[1]), evaluate };
}

export function readSignatureDir(dir: string): SignatureFile[] {
  return fs
    .readdirSync(dir)
    .filter(f => f.endsWith('.lua'))
    .sort()
    .map(f => readSignatureFile(path.join(dir, f)));
}

/**
 * What UE4SS would resolve: scan the executable code, evaluate each hit in
 * address order, and take the first. Also returns every distinct result, so a
 * caller can tell a unique match from an ambiguous one.
 */
export function resolveSignature(
  sig: SignatureFile,
  elf: Elf,
): { address?: number; hits: number; results: number[] } {
  if (sig.pinned !== undefined)
    return { address: sig.pinned, hits: 1, results: [sig.pinned] };
  const { start, end } = elf.textRange();
  const hits = sig.pattern!.scan(elf.data, start, end).map(o => elf.vaddrOf(o));
  const results = [...new Set(hits.map(h => sig.evaluate!(h, elf)))];
  return { address: hits.length ? sig.evaluate!(hits[0], elf) : undefined, hits: hits.length, results };
}

/** A signature file that resolves to one fixed address in one binary. */
export function pinnedSignature(symbol: string, address: number, reason: string) {
  return (
    `-- ${symbol}: pinned by omegga-ue4ss for one game binary (${reason}).\n` +
    `-- Rewritten on every server start; the shipped AOB is in the plugin's overlay.\n` +
    `return 0x${address.toString(16)}\n`
  );
}

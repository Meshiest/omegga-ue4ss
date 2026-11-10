import fs from 'node:fs';
import path from 'node:path';
import { type Elf } from './elf';
import { hex, type Resolved, resolveAnchors } from './resolvers';
import { pinnedSignature, readSignatureDir, resolveSignature } from './sigfile';

/** Symbols UE4SS returns as code addresses; everything else is a global. */
const FUNCTIONS = new Set([
  'CallFunctionByNameWithArguments',
  'ProcessLocalScriptFunction',
  'GameEngineTick',
  'StaticConstructObject',
  'FName_Constructor',
  'FName_ToString',
]);

/**
 * Without these UE4SS can't start (or, for GameEngineTick, can't use the
 * FName_Constructor override, and ExecuteInGameThread has no game thread).
 */
export const REQUIRED = new Set([
  'GUObjectArray',
  'GMalloc',
  'StaticConstructObject',
  'FName_Constructor',
  'GameEngineTick',
]);

/**
 * - verified: AOB and anchor agree on a plausible address
 * - corrected: the AOB misses or gives an implausible address; the anchor's is pinned
 * - unverified: only the AOB resolves
 * - conflict: both look plausible but disagree. Nothing is written: pinning the
 *   wrong one hooks the wrong function, so the symbol counts as unresolved
 * - unresolved: neither resolves
 */
export type Status = 'verified' | 'corrected' | 'unverified' | 'conflict' | 'unresolved';

export interface SymbolReport {
  symbol: string;
  status: Status;
  /** what UE4SS will use, when anything */
  address?: number;
  aob: { address?: number; hits: number; distinct: number; plausible: boolean };
  anchor: Resolved & { plausible: boolean };
  note: string;
}

function plausible(elf: Elf, symbol: string, address: number | undefined) {
  if (address === undefined) return false;
  return FUNCTIONS.has(symbol) ? elf.isFunctionStart(address) : elf.isWritable(address);
}

/**
 * Check the shipped signatures against a game binary two independent ways: the
 * AOB as UE4SS would scan it, and an anchor resolver. See Status for how they
 * combine.
 */
export function verifySignatures(elf: Elf, sigDir: string): SymbolReport[] {
  const sigs = readSignatureDir(sigDir);
  const anchors = resolveAnchors(elf, sigs.map(s => s.symbol));

  return sigs.map(sig => {
    const r = resolveSignature(sig, elf);
    const aob = {
      address: r.address,
      hits: r.hits,
      distinct: r.results.length,
      plausible: plausible(elf, sig.symbol, r.address),
    };
    const a = anchors.get(sig.symbol)!;
    const anchor = { ...a, plausible: plausible(elf, sig.symbol, a.address) };
    const base = { symbol: sig.symbol, aob, anchor };

    if (aob.plausible && anchor.plausible && aob.address === anchor.address)
      return { ...base, status: 'verified', address: aob.address, note: anchor.detail };
    if (aob.plausible && anchor.plausible)
      return {
        ...base,
        status: 'conflict',
        note: `AOB gives ${hex(aob.address!)}, anchor ${hex(anchor.address!)} (${anchor.detail})`,
      };
    if (anchor.plausible) {
      const why =
        aob.address === undefined
          ? 'AOB has no match'
          : `AOB result ${hex(aob.address)} is not a ${FUNCTIONS.has(sig.symbol) ? 'function entry' : 'global'}`;
      return { ...base, status: 'corrected', address: anchor.address, note: why };
    }
    if (aob.plausible)
      return { ...base, status: 'unverified', address: aob.address, note: `anchor: ${anchor.detail}` };
    return { ...base, status: 'unresolved', note: `AOB ${aob.hits} hits; anchor: ${anchor.detail}` };
  });
}

/** True when every required symbol resolves to something usable. */
export function usable(reports: SymbolReport[]) {
  return [...REQUIRED].every(s => {
    const r = reports.find(x => x.symbol === s);
    return r && r.status !== 'unresolved' && r.status !== 'conflict';
  });
}

/**
 * Write the signature set UE4SS will load: the shipped file where the AOB is
 * good, a pinned address where it was corrected, nothing where unresolved (so
 * UE4SS falls back to its own scan for that symbol).
 */
export function writeSignatures(reports: SymbolReport[], shippedDir: string, outDir: string) {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  for (const r of reports) {
    const file = path.join(outDir, `${r.symbol}.lua`);
    if (r.status === 'verified' || r.status === 'unverified')
      fs.copyFileSync(path.join(shippedDir, `${r.symbol}.lua`), file);
    else if (r.status === 'corrected') fs.writeFileSync(file, pinnedSignature(r.symbol, r.address!, r.note));
  }
}

export function formatReport(reports: SymbolReport[]) {
  return reports
    .map(r => {
      const at = r.address === undefined ? '-' : hex(r.address);
      return `${r.status.padEnd(10)} ${r.symbol.padEnd(32)} ${at.padEnd(12)} ${r.note}`;
    })
    .join('\n');
}

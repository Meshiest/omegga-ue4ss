import { type Elf } from './elf';
import { Pattern } from './pattern';

/**
 * Anchor-based resolvers: find each core symbol by what the code does (a flag
 * constant, an opcode compare, a string it references, an exported caller)
 * instead of by its prologue bytes. Slower than an AOB but much less sensitive
 * to codegen drift, so they verify the shipped signatures and stand in for
 * them when a game patch breaks one.
 *
 * Keys match the signature file names in overlay/UE4SS_Signatures.
 */
export type Resolved = { address?: number; detail: string };

class Context {
  readonly text: { start: number; end: number };
  #leaIndex: Map<number, number[]> | null = null;
  #leaWanted = new Set<number>();

  constructor(readonly elf: Elf) {
    this.text = elf.textRange();
  }

  scan(pattern: string): number[] {
    return new Pattern(pattern)
      .scan(this.elf.data, this.text.start, this.text.end)
      .map(o => this.elf.vaddrOf(o));
  }

  byte(vaddr: number) {
    return this.elf.data[this.elf.offsetOf(vaddr)];
  }

  /** Target of a 5-byte `call rel32` at vaddr. */
  callTarget(vaddr: number) {
    return vaddr + 5 + this.elf.i32(vaddr + 1);
  }

  /**
   * Addresses of NUL-terminated UTF-16 literals equal to `text` (or starting
   * with it when `prefix`). No check on the preceding character: .rodata is
   * SHF_MERGE|STRINGS, so a short literal is often the tail of a longer one.
   */
  utf16(text: string, prefix = false): number[] {
    const needle = Buffer.from(prefix ? text : text + '\0', 'utf16le');
    const out: number[] = [];
    for (let at = this.elf.data.indexOf(needle); at >= 0; at = this.elf.data.indexOf(needle, at + 1))
      if (at % 2 === 0) out.push(this.elf.vaddrOf(at));
    return out.filter(v => v >= 0);
  }

  /**
   * Instructions `lea r64, [rip + disp32]` (REX.W 8D /r, mod 00 rm 101) that
   * point at any of `targets`. One pass over .text per new batch of targets.
   */
  leaRefs(targets: number[]): number[] {
    const fresh = targets.filter(t => !this.#leaWanted.has(t));
    if (fresh.length || !this.#leaIndex) {
      fresh.forEach(t => this.#leaWanted.add(t));
      this.#leaIndex = new Map();
      const d = this.elf.data;
      const { start, end } = this.text;
      for (let p = d.indexOf(0x8d, start + 1); p >= 0 && p + 6 < end; p = d.indexOf(0x8d, p + 1)) {
        const rex = d[p - 1];
        if ((rex !== 0x48 && rex !== 0x4c) || (d[p + 1] & 0xc7) !== 0x05) continue;
        const insn = this.elf.vaddrOf(p - 1);
        const target = insn + 7 + d.readInt32LE(p + 2);
        if (!this.#leaWanted.has(target)) continue;
        const list = this.#leaIndex.get(target) ?? [];
        list.push(insn);
        this.#leaIndex.set(target, list);
      }
    }
    return targets.flatMap(t => this.#leaIndex!.get(t) ?? []);
  }

  /** Target of the first `lea/mov r64, [rip+disp32]` (8D or 8B) within `range` bytes. */
  firstRipOperand(from: number, range: number, opcode: 0x8d | 0x8b): number | undefined {
    for (let v = from; v < from + range; v++) {
      const rex = this.byte(v);
      if ((rex === 0x48 || rex === 0x4c) && this.byte(v + 1) === opcode && (this.byte(v + 2) & 0xc7) === 0x05)
        return v + 7 + this.elf.i32(v + 3);
    }
    return undefined;
  }

  functionsOf(addresses: number[]): number[] {
    return [...new Set(addresses.map(a => this.elf.functionContaining(a)))].filter(f => f >= 0);
  }
}

function tally(values: number[]): [number, number][] {
  const counts = new Map<number, number>();
  for (const v of values) counts.set(v, (counts.get(v) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1]);
}

function unique(addresses: number[], what: string): Resolved {
  if (addresses.length === 1) return { address: addresses[0], detail: what };
  return { detail: `${what}: ${addresses.length} candidates` };
}

const hex = (n: number) => `0x${n.toString(16)}`;

const resolvers: Record<string, (c: Context) => Resolved> = {
  // the module's only `mov eax, 0x200 (FUNC_Exec); and eax, [reg+0xB0]`
  // (UFunction::FunctionFlags)
  CallFunctionByNameWithArguments(c) {
    const fns: number[] = [];
    for (const hit of c.scan('B8 00 02 00 00')) {
      let v = hit + 5;
      if ((c.byte(v) & 0xf0) === 0x40) v++;
      if (c.byte(v) !== 0x23) continue;
      const modrm = c.byte(v + 1);
      if (modrm >> 6 !== 2 || ((modrm >> 3) & 7) !== 0) continue;
      const dispAt = v + 2 + ((modrm & 7) === 4 ? 1 : 0);
      if (c.elf.i32(dispAt) === 0xb0) fns.push(c.elf.functionContaining(hit));
    }
    return unique([...new Set(fns)], 'FUNC_Exec test');
  },

  // loads Stack.Code ([rsi+0x20]) and compares the opcode with EX_Return (4)
  // within its first instructions
  ProcessLocalScriptFunction(c) {
    const fns = c
      .scan('48 8B 46 20 80 38 04')
      .filter(h => h - c.elf.functionContaining(h) < 0x40)
      .map(h => c.elf.functionContaining(h));
    return unique([...new Set(fns)], 'EX_Return compare on Stack.Code');
  },

  // the opcode table that ProcessLocalScriptFunction's loop indexes
  GNatives(c) {
    const plsf = resolvers.ProcessLocalScriptFunction(c).address;
    if (plsf === undefined) return { detail: 'needs ProcessLocalScriptFunction' };
    const hit = c.scan('48 8B 46 20 80 38 04').find(h => c.elf.functionContaining(h) === plsf)!;
    const table = c.firstRipOperand(hit, 0x30, 0x8d);
    return table === undefined ? { detail: 'no lea after the EX_Return test' } : { address: table, detail: 'lea in PLSF loop' };
  },

  // UGameEngine::Tick is the only function referencing u"causeevent="
  GameEngineTick(c) {
    return unique(c.functionsOf(c.leaRefs(c.utf16('causeevent='))), 'u"causeevent=" reference');
  },

  // NewObject<T> inlines u"NewObject with empty name can't be used to create
  // default subobjects" and then calls StaticConstructObject_Internal; take the
  // most called target there that has its big (0x2xx) frame
  StaticConstructObject(c) {
    const refs = c.leaRefs(c.utf16('NewObject with empty name can', true));
    const calls: number[] = [];
    for (const r of refs)
      for (let v = r; v < r + 0xc0; v++)
        if (c.byte(v) === 0xe8) {
          const t = c.callTarget(v);
          if (c.elf.isFunctionStart(t)) calls.push(t);
        }
    const frame = new Pattern('48 81 EC ?? 02 00 00');
    for (const [target] of tally(calls).slice(0, 6)) {
      const off = c.elf.offsetOf(target);
      for (let i = 0; i < 16; i++) if (frame.matchesAt(c.elf.data, off + i)) return { address: target, detail: `called after ${refs.length} NewObject checks` };
    }
    return { detail: 'no big-frame callee after the NewObject check' };
  },

  // FNameHelper::MakeDetectNumber: every inlined FName(const TCHAR*) does
  // `lea rdi, str; mov esi, len; mov edx, 1 (FNAME_Add); call`. Its ANSI twin
  // is called the same way (and more often in some builds), so only count
  // sites whose string is UTF-16
  FName_Constructor(c) {
    const d = c.elf.data;
    const calls = c
      .scan('48 8D 3D ?? ?? ?? ?? BE ?? ?? ?? ?? BA 01 00 00 00 E8')
      .filter(h => {
        const str = c.elf.offsetOf(h + 7 + c.elf.i32(h + 3));
        return str >= 0 && d[str] !== 0 && d[str + 1] === 0;
      })
      .map(h => c.callTarget(h + 17));
    const [top] = tally(calls);
    return top ? { address: top[0], detail: `${top[1]} UTF-16 literal FName constructions` } : { detail: 'no literal FName constructions' };
  },

  // FName::ToString(FString&): right after the FName helper, the first
  // function with a 0x8xx frame that indexes the name pool by
  // ComparisonIndex >> 16 (`shr eax,16` ... `mov rax,[base+idx*8+0x40]`)
  FName_ToString(c) {
    const helper = resolvers.FName_Constructor(c).address;
    if (helper === undefined) return { detail: 'needs FName_Constructor' };
    const frame = new Pattern('48 81 EC ?? 08 00 00');
    const pool = new Pattern('C1 E8 10');
    const load = new Pattern('48 8B 44 ?? 40');
    const d = c.elf.data;
    for (const fn of c.elf.functionStarts()) {
      if (fn <= helper) continue;
      if (fn > helper + 0x40000) break;
      const o = c.elf.offsetOf(fn);
      let hasFrame = false;
      for (let i = 0; i < 0x14 && !hasFrame; i++) hasFrame = frame.matchesAt(d, o + i);
      if (!hasFrame) continue;
      for (let i = 0; i < 0x80; i++)
        if (pool.matchesAt(d, o + i) && [...Array(16).keys()].some(j => load.matchesAt(d, o + i + 3 + j)))
          return { address: fn, detail: 'name-pool lookup with a 0x8xx frame' };
    }
    return { detail: 'no name-pool lookup after the FName helper' };
  },

  // operator new[] (exported as _Znam) is `mov rdi, [rip+GMalloc]; test rdi, rdi`
  GMalloc(c) {
    const znam = c.elf.dynamicSymbol('_Znam');
    if (znam === undefined) return { detail: 'no exported operator new[]' };
    const g = c.firstRipOperand(znam, 0x40, 0x8b);
    return g === undefined ? { detail: 'no global load in operator new[]' } : { address: g, detail: 'loaded by operator new[]' };
  },

  // the GC sets GObjectCountDuringLastMarkPhase to ObjObjects.NumElements -
  // (ObjAvailableListEstimateCount + ObjFirstGCIndex); NumElements is +8
  GUObjectArray(c) {
    const ripModrm = (v: number) => (c.byte(v) & 0xc7) === 0x05;
    const bases = c
      .scan('8B ?? ?? ?? ?? ?? 8B ?? ?? ?? ?? ?? 03 ?? ?? ?? ?? ?? 29 ?? 87')
      .filter(h => ripModrm(h + 1) && ripModrm(h + 7) && ripModrm(h + 13))
      .map(h => h + 6 + c.elf.i32(h + 2) - 8);
    return unique([...new Set(bases)], 'GC object count');
  },

  // every cvar registration null-tests the console manager singleton first
  ConsoleManager(c) {
    const loads = c.scan('48 8B 3D ?? ?? ?? ?? 48 85 FF').map(h => h + 7 + c.elf.i32(h + 3));
    const [top, second] = tally(loads);
    if (!top) return { detail: 'no null-tested globals' };
    return { address: top[0], detail: `${top[1]} null-tests (next ${second?.[1] ?? 0})` };
  },
};

export const RESOLVABLE = Object.keys(resolvers);

/** Resolve the given symbols by anchor; unknown symbols come back unresolved. */
export function resolveAnchors(elf: Elf, symbols: string[]): Map<string, Resolved> {
  const c = new Context(elf);
  const out = new Map<string, Resolved>();
  for (const s of symbols) {
    const r = resolvers[s];
    try {
      out.set(s, r ? r(c) : { detail: 'no anchor resolver' });
    } catch (e) {
      out.set(s, { detail: `resolver failed: ${(e as Error).message}` });
    }
  }
  return out;
}

export { hex };

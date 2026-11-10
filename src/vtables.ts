import { type Elf } from './elf';
import { hex } from './resolvers';

/**
 * Check the exact vtable offsets in overlay/VTableOffsets.linux.ini against a
 * binary. UE4SS calls and hooks these virtuals by slot, so a wrong slot means
 * hooking the wrong function; an AOB check can't catch it.
 *
 * The anchor is the UGameEngine vtable: the one slot holding the verified
 * GameEngineTick address. In it:
 * - ProcessConsoleExec is a thunk that tail-jumps into
 *   CallFunctionByNameWithArguments (that is its whole body)
 * - ProcessEvent opens by validating `this` through GUObjectArray:
 *   `mov eax, [rdi+0xc]` (InternalIndex) and a compare with NumElements
 *   (GUObjectArray+8)
 */
export interface VTableCheck {
  name: string;
  offset: number;
  ok: boolean;
  note: string;
}

export function parseVTableOffsets(text: string): Map<string, number> {
  const out = new Map<string, number>();
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/;.*$/, '').trim();
    const m = line.match(/^(\w+)\.(\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)$/);
    if (m) out.set(`${m[1]}.${m[2]}`, Number(m[3]));
  }
  return out;
}

/** Address points of vtables (slot 0) that hold `fn` at `offset`. */
function vtablesWith(elf: Elf, fn: number, offset: number): number[] {
  const needle = Buffer.alloc(8);
  needle.writeBigUInt64LE(BigInt(fn));
  const out: number[] = [];
  for (let at = elf.data.indexOf(needle); at >= 0; at = elf.data.indexOf(needle, at + 1)) {
    if (at % 8) continue;
    const slot = elf.vaddrOf(at);
    if (slot >= 0) out.push(slot - offset);
  }
  return out;
}

const slot = (elf: Elf, vtable: number, offset: number) =>
  Number(elf.data.readBigUInt64LE(elf.offsetOf(vtable + offset)));

export function checkVTables(
  elf: Elf,
  offsets: Map<string, number>,
  symbols: { GameEngineTick?: number; CallFunctionByNameWithArguments?: number; GUObjectArray?: number },
): VTableCheck[] {
  const checks: VTableCheck[] = [];
  const tickAt = offsets.get('UEngine.Tick');
  const tick = symbols.GameEngineTick;
  if (tickAt === undefined || tick === undefined) return checks;

  // the UGameEngine vtable and its subclasses' all hold Tick at the same slot;
  // a single match proves nothing about the others, so require at least one
  const vtables = vtablesWith(elf, tick, tickAt).filter(v => elf.isExecutable(slot(elf, v, 0)));
  checks.push({
    name: 'UEngine.Tick',
    offset: tickAt,
    ok: vtables.length > 0,
    note: vtables.length ? `GameEngineTick at slot ${tickAt / 8} of ${vtables.length} vtable(s)` : 'no vtable holds GameEngineTick there',
  });
  if (!vtables.length) return checks;
  const vt = vtables[0];
  const d = elf.data;

  const pce = offsets.get('UObject.ProcessConsoleExec');
  if (pce !== undefined && symbols.CallFunctionByNameWithArguments !== undefined) {
    const fn = slot(elf, vt, pce);
    const o = elf.offsetOf(fn);
    // `jmp rel32` within the first few bytes (an adjustor may come first)
    let target: number | undefined;
    for (let i = 0; i < 8 && target === undefined; i++)
      if (d[o + i] === 0xe9) target = fn + i + 5 + d.readInt32LE(o + i + 1);
    checks.push({
      name: 'UObject.ProcessConsoleExec',
      offset: pce,
      ok: target === symbols.CallFunctionByNameWithArguments,
      note: target === undefined ? `slot holds ${hex(fn)}, not a thunk` : `thunk to ${hex(target)}`,
    });
  }

  const pe = offsets.get('UObject.ProcessEvent');
  if (pe !== undefined && symbols.GUObjectArray !== undefined) {
    const fn = slot(elf, vt, pe);
    const o = elf.offsetOf(fn);
    const body = d.subarray(o, o + 0x40);
    const internalIndex = body.indexOf(Buffer.from([0x8b, 0x47, 0x0c]));
    // cmp eax, [rip+disp32] against NumElements
    let comparesCount = false;
    for (let i = 0; i + 6 <= body.length && !comparesCount; i++)
      if (body[i] === 0x3b && body[i + 1] === 0x05)
        comparesCount = fn + i + 6 + body.readInt32LE(i + 2) === symbols.GUObjectArray + 8;
    checks.push({
      name: 'UObject.ProcessEvent',
      offset: pe,
      ok: internalIndex >= 0 && comparesCount,
      note: `slot holds ${hex(fn)}${internalIndex >= 0 && comparesCount ? ', validates this through GUObjectArray' : ', not the ProcessEvent prologue'}`,
    });
  }
  return checks;
}

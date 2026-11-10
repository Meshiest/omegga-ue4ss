import fs from 'node:fs';

interface Segment {
  offset: number;
  vaddr: number;
  filesz: number;
  memsz: number;
  flags: number;
}

interface Section {
  name: string;
  addr: number;
  offset: number;
  size: number;
}

const PT_LOAD = 1;
const PF_X = 1;
const PF_W = 2;

/**
 * A 64-bit little-endian ELF executable, read whole. Built for the stripped,
 * non-PIE Brickadia server: addresses are absolute, so nothing here relocates.
 */
export class Elf {
  readonly data: Buffer;
  readonly segments: Segment[];
  readonly sections: Section[];
  #functionStarts: Float64Array | null = null;

  constructor(readonly path: string) {
    this.data = fs.readFileSync(path);
    if (this.data.readUInt32BE(0) !== 0x7f454c46 || this.data[4] !== 2)
      throw new Error(`${path} is not a 64-bit ELF`);
    this.segments = this.#readSegments();
    this.sections = this.#readSections();
  }

  #readSegments(): Segment[] {
    const d = this.data;
    const phoff = Number(d.readBigUInt64LE(0x20));
    const phentsize = d.readUInt16LE(0x36);
    const phnum = d.readUInt16LE(0x38);
    const out: Segment[] = [];
    for (let i = 0; i < phnum; i++) {
      const h = phoff + i * phentsize;
      if (d.readUInt32LE(h) !== PT_LOAD) continue;
      out.push({
        flags: d.readUInt32LE(h + 4),
        offset: Number(d.readBigUInt64LE(h + 8)),
        vaddr: Number(d.readBigUInt64LE(h + 16)),
        filesz: Number(d.readBigUInt64LE(h + 32)),
        memsz: Number(d.readBigUInt64LE(h + 40)),
      });
    }
    return out;
  }

  #readSections(): Section[] {
    const d = this.data;
    const shoff = Number(d.readBigUInt64LE(0x28));
    const shentsize = d.readUInt16LE(0x3a);
    const shnum = d.readUInt16LE(0x3c);
    const shstrndx = d.readUInt16LE(0x3e);
    if (!shoff) return [];
    const strtab = Number(d.readBigUInt64LE(shoff + shstrndx * shentsize + 0x18));
    const out: Section[] = [];
    for (let i = 0; i < shnum; i++) {
      const h = shoff + i * shentsize;
      const nameOff = strtab + d.readUInt32LE(h);
      out.push({
        name: d.toString('latin1', nameOff, d.indexOf(0, nameOff)),
        addr: Number(d.readBigUInt64LE(h + 0x10)),
        offset: Number(d.readBigUInt64LE(h + 0x18)),
        size: Number(d.readBigUInt64LE(h + 0x20)),
      });
    }
    return out;
  }

  section(name: string): Section | undefined {
    return this.sections.find(s => s.name === name);
  }

  /** File offset of a virtual address, or -1 when it isn't backed by the file. */
  offsetOf(vaddr: number): number {
    for (const s of this.segments)
      if (vaddr >= s.vaddr && vaddr < s.vaddr + s.filesz)
        return s.offset + vaddr - s.vaddr;
    return -1;
  }

  vaddrOf(offset: number): number {
    for (const s of this.segments)
      if (offset >= s.offset && offset < s.offset + s.filesz)
        return s.vaddr + offset - s.offset;
    return -1;
  }

  /** Executable code range (file offsets), from the `.text` section. */
  textRange(): { start: number; end: number } {
    const text = this.section('.text');
    if (!text) throw new Error('no .text section');
    return { start: text.offset, end: text.offset + text.size };
  }

  isExecutable(vaddr: number): boolean {
    return this.segments.some(
      s => s.flags & PF_X && vaddr >= s.vaddr && vaddr < s.vaddr + s.memsz,
    );
  }

  /** In a writable segment: where globals (.data/.bss) live. */
  isWritable(vaddr: number): boolean {
    return this.segments.some(
      s => s.flags & PF_W && vaddr >= s.vaddr && vaddr < s.vaddr + s.memsz,
    );
  }

  i32(vaddr: number): number {
    return this.data.readInt32LE(this.offsetOf(vaddr));
  }

  /**
   * Every function entry, sorted, from the `.eh_frame_hdr` binary-search
   * table. Stripping keeps it (exceptions and crash backtraces need it), so it
   * is the reliable source of function boundaries in this binary.
   */
  functionStarts(): Float64Array {
    if (this.#functionStarts) return this.#functionStarts;
    const hdr = this.section('.eh_frame_hdr');
    if (!hdr) throw new Error('no .eh_frame_hdr section');
    const d = this.data;
    const o = hdr.offset;
    const [version, , fdeCountEnc, tableEnc] = [d[o], d[o + 1], d[o + 2], d[o + 3]];
    // version 1; count as udata4 (0x03); table as datarel sdata4 (0x3b), which
    // is what LLVM emits. Anything else is unexpected enough to stop on.
    if (version !== 1 || fdeCountEnc !== 0x03 || tableEnc !== 0x3b)
      throw new Error(
        `unsupported .eh_frame_hdr encoding (${version}, ${fdeCountEnc}, ${tableEnc})`,
      );
    const count = d.readUInt32LE(o + 8);
    const starts = new Float64Array(count);
    for (let i = 0; i < count; i++)
      starts[i] = hdr.addr + d.readInt32LE(o + 12 + i * 8);
    starts.sort();
    this.#functionStarts = starts;
    return starts;
  }

  isFunctionStart(vaddr: number): boolean {
    const s = this.functionStarts();
    let lo = 0;
    let hi = s.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (s[mid] === vaddr) return true;
      if (s[mid] < vaddr) lo = mid + 1;
      else hi = mid - 1;
    }
    return false;
  }

  /** Entry of the function containing `vaddr` (the nearest start at or below it). */
  functionContaining(vaddr: number): number {
    const s = this.functionStarts();
    let lo = 0;
    let hi = s.length - 1;
    let best = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (s[mid] <= vaddr) {
        best = mid;
        lo = mid + 1;
      } else hi = mid - 1;
    }
    return best < 0 ? -1 : s[best];
  }

  /** Address of a dynamic (exported) symbol, or undefined. */
  dynamicSymbol(name: string): number | undefined {
    const dynsym = this.section('.dynsym');
    const dynstr = this.section('.dynstr');
    if (!dynsym || !dynstr) return undefined;
    const d = this.data;
    for (let p = dynsym.offset; p < dynsym.offset + dynsym.size; p += 24) {
      const nameOff = dynstr.offset + d.readUInt32LE(p);
      if (d.toString('latin1', nameOff, d.indexOf(0, nameOff)) === name)
        return Number(d.readBigUInt64LE(p + 8));
    }
    return undefined;
  }
}

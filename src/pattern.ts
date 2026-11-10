/** A byte pattern with `??` wildcards, as UE4SS signature files write them. */
export class Pattern {
  readonly bytes: number[];
  readonly mask: boolean[];
  // the longest run of literal bytes, searched with Buffer.indexOf
  readonly #anchor: Buffer;
  readonly #anchorAt: number;

  constructor(readonly text: string) {
    const tokens = text.trim().split(/\s+/);
    this.bytes = tokens.map(t => (t === '??' || t === '?' ? 0 : parseInt(t, 16)));
    this.mask = tokens.map(t => !(t === '??' || t === '?'));
    if (this.bytes.some((b, i) => this.mask[i] && Number.isNaN(b)))
      throw new Error(`bad pattern: ${text}`);

    let bestAt = 0;
    let bestLen = 0;
    for (let i = 0; i < this.mask.length; ) {
      if (!this.mask[i]) {
        i++;
        continue;
      }
      let j = i;
      while (j < this.mask.length && this.mask[j]) j++;
      if (j - i > bestLen) {
        bestLen = j - i;
        bestAt = i;
      }
      i = j;
    }
    if (!bestLen) throw new Error(`pattern has no literal bytes: ${text}`);
    this.#anchor = Buffer.from(this.bytes.slice(bestAt, bestAt + bestLen));
    this.#anchorAt = bestAt;
  }

  get length() {
    return this.bytes.length;
  }

  matchesAt(data: Buffer, offset: number): boolean {
    if (offset < 0 || offset + this.bytes.length > data.length) return false;
    for (let i = 0; i < this.bytes.length; i++)
      if (this.mask[i] && data[offset + i] !== this.bytes[i]) return false;
    return true;
  }

  /** File offsets of every match within [start, end). */
  scan(data: Buffer, start = 0, end = data.length): number[] {
    const hits: number[] = [];
    let from = start + this.#anchorAt;
    for (;;) {
      const at = data.indexOf(this.#anchor, from);
      if (at < 0 || at >= end) break;
      const begin = at - this.#anchorAt;
      if (begin >= start && begin + this.bytes.length <= end && this.matchesAt(data, begin))
        hits.push(begin);
      from = at + 1;
    }
    return hits;
  }
}

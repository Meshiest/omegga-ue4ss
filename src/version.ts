/**
 * The changelist the game binary was built from, from its UTF-16LE build stamp
 * `<Branch> (<Platform>-<Config>-CL<changelist>)`, e.g.
 * `Release-X (PC-Shipping-CL12345)`. Same rule as omegga's readBinaryVersion:
 * the digits must end in `)`, and only an unambiguous single value counts.
 */
export function buildChangelist(data: Buffer): number | null {
  const needle = Buffer.from('-CL', 'utf16le');
  const found = new Set<number>();
  for (let i = data.indexOf(needle), scans = 0; i >= 0 && scans < 10_000; i = data.indexOf(needle, i + 2), scans++) {
    let p = i + needle.length;
    let digits = '';
    while (p + 1 < data.length && data[p + 1] === 0 && data[p] >= 0x30 && data[p] <= 0x39) {
      digits += String.fromCharCode(data[p]);
      p += 2;
    }
    if (digits && data[p] === 0x29 && data[p + 1] === 0) found.add(Number(digits));
  }
  return found.size === 1 ? [...found][0] : null;
}

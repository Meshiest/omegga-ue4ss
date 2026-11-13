// Check the shipped signatures against a game binary without starting it.
//
//   npm run verify -- <BrickadiaServer-Linux-Shipping> [signature dir]
//
// Exit status: 0 when every required symbol resolves (some may be pinned)
// and the exact vtable offsets match, 1 otherwise.
import path from 'node:path';
import fs from 'node:fs';
import { Elf } from '../src/elf';
import { addresses } from '../src/prepare';
import { checkVTables, parseVTableOffsets } from '../src/vtables';
import { formatReport, usable, verifySignatures } from '../src/verify';

const [
  binary,
  sigDir = path.join(__dirname, '..', '..', 'overlay', 'UE4SS_Signatures'),
] = process.argv.slice(2);
if (!binary) {
  console.error('usage: verify-cli <game binary> [signature dir]');
  process.exit(2);
}
const started = Date.now();
const elf = new Elf(binary);
const reports = verifySignatures(elf, sigDir);
console.log(formatReport(reports));
const offsets = parseVTableOffsets(
  fs.readFileSync(path.join(sigDir, '..', 'VTableOffsets.linux.ini'), 'utf8'),
);
const vtables = checkVTables(elf, offsets, addresses(reports));
for (const v of vtables)
  console.log(
    `${v.ok ? 'verified' : 'FAILED  '}   ${v.name.padEnd(32)} 0x${v.offset.toString(16).padEnd(10)} ${v.note}`,
  );
const ok = usable(reports) && vtables.length === 3 && vtables.every(v => v.ok);
console.log(`${ok ? 'usable' : 'NOT usable'} (${Date.now() - started} ms)`);
process.exit(ok ? 0 : 1);

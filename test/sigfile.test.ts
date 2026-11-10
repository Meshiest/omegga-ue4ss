import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { type Elf } from '../src/elf';
import { pinnedSignature, readSignatureFile } from '../src/sigfile';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'omegga-ue4ss-sig-'));
const write = (name: string, text: string) => {
  const file = path.join(tmp, `${name}.lua`);
  fs.writeFileSync(file, text);
  return file;
};
// i32 reads a fixed displacement, enough to check the arithmetic
const fakeElf = { i32: () => 0x100 } as unknown as Elf;

test('entry signatures return the match', () => {
  const sig = readSignatureFile(write('A', 'function Register()\n    return "48 8B ??"\nend\nfunction OnMatchFound(MatchAddress)\n    return MatchAddress\nend\n'));
  assert.equal(sig.evaluate!(0x1000, fakeElf), 0x1000);
});

test('RIP-relative signatures decode the operand', () => {
  const sig = readSignatureFile(
    write('B', 'function Register() return "48 8B" end\nfunction OnMatchFound(MatchAddress)\n    local Insn = MatchAddress + 14\n    return Insn + 7 + DerefToInt32(Insn + 3)\nend\n'),
  );
  assert.equal(sig.evaluate!(0x1000, fakeElf), 0x1000 + 14 + 7 + 0x100);
});

test('inline RIP-relative signatures with an adjustment', () => {
  const sig = readSignatureFile(
    write('C', 'function Register() return "8B 05" end\nfunction OnMatchFound(MatchAddress)\n    return MatchAddress + 6 + DerefToInt32(MatchAddress + 2) - 8\nend\n'),
  );
  assert.equal(sig.evaluate!(0x1000, fakeElf), 0x1000 + 6 + 0x100 - 8);
});

test('pinned files round-trip', () => {
  const sig = readSignatureFile(write('GMalloc', pinnedSignature('GMalloc', 0xa233e40, 'test')));
  assert.equal(sig.pinned, 0xa233e40);
});

test('unsupported OnMatchFound is an error, not a guess', () => {
  assert.throws(() => readSignatureFile(write('D', 'function Register() return "90" end\nfunction OnMatchFound(m) return m * 2 end\n')));
});

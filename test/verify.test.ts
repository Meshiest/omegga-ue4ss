import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { Elf } from '../src/elf';
import { readSignatureFile } from '../src/sigfile';
import { usable, verifySignatures, writeSignatures } from '../src/verify';

// Needs a real BrickadiaServer-Linux-Shipping, which can't be redistributed:
//   GAME_BINARY=/path/to/BrickadiaServer-Linux-Shipping npm test
const binary = process.env.GAME_BINARY;
const shipped = path.join(__dirname, '..', '..', 'overlay', 'UE4SS_Signatures');

test('shipped signatures verify', { skip: !binary && 'GAME_BINARY not set' }, () => {
  const reports = verifySignatures(new Elf(binary!), shipped);
  assert.ok(usable(reports));
  for (const r of reports) assert.equal(r.status, 'verified', `${r.symbol}: ${r.note}`);
});

test('a drifted AOB is corrected by its anchor', { skip: !binary && 'GAME_BINARY not set' }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omegga-ue4ss-drift-'));
  for (const f of fs.readdirSync(shipped)) fs.copyFileSync(path.join(shipped, f), path.join(dir, f));
  // a prologue that exists nowhere, as after a codegen change
  fs.writeFileSync(
    path.join(dir, 'CallFunctionByNameWithArguments.lua'),
    'function Register()\n    return "55 48 89 E5 CC CC CC CC CC CC"\nend\nfunction OnMatchFound(MatchAddress)\n    return MatchAddress\nend\n',
  );
  const elf = new Elf(binary!);
  const good = verifySignatures(elf, shipped).find(r => r.symbol === 'CallFunctionByNameWithArguments')!;
  const drifted = verifySignatures(elf, dir).find(r => r.symbol === 'CallFunctionByNameWithArguments')!;
  assert.equal(drifted.status, 'corrected');
  assert.equal(drifted.address, good.address);

  const out = path.join(dir, 'out');
  writeSignatures([drifted], dir, out);
  assert.equal(readSignatureFile(path.join(out, 'CallFunctionByNameWithArguments.lua')).pinned, good.address);
});

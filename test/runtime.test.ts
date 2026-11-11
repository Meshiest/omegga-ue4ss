import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { checkRuntime } from '../src/runtime';
import { runtimeAssets, runtimeKeys, STAMP } from '../src/runtime-keys';

function checkout() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omegga-ue4ss-keys-'));
  const write = (rel: string, text: string) => {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  };
  write('native/build.sh', 'build');
  write('native/patches/RE-UE4SS.base', 'abc');
  write('native/patches/RE-UE4SS.patch', 'diff');
  write('native/BrickadiaBridge/CMakeLists.txt', 'cmake');
  write('native/BrickadiaBridge/src/main.cpp', 'int main;');
  return { dir, write };
}

test('a mod-only change keeps the ue4ss key and changes the mod key', () => {
  const { dir, write } = checkout();
  const before = runtimeKeys(dir);
  write('native/BrickadiaBridge/src/main.cpp', 'int main2;');
  const after = runtimeKeys(dir);
  assert.equal(after.ue4ss, before.ue4ss);
  assert.notEqual(after.mod, before.mod);
});

test('a ue4ss change changes both keys, since the mod is built against it', () => {
  const { dir, write } = checkout();
  const before = runtimeKeys(dir);
  write('native/patches/RE-UE4SS.patch', 'diff2');
  const after = runtimeKeys(dir);
  assert.notEqual(after.ue4ss, before.ue4ss);
  assert.notEqual(after.mod, before.mod);
});

test('keys depend on content, not on where the checkout is', () => {
  const a = checkout();
  const b = checkout();
  assert.deepEqual(runtimeKeys(a.dir), runtimeKeys(b.dir));
  assert.match(runtimeAssets(runtimeKeys(a.dir)).mod, /^BrickadiaBridge-[0-9a-f]{16}\.so$/);
});

// what tools/fetch-runtime.ts leaves after a download
function installed(dir: string, write: (rel: string, text: string) => void) {
  write('runtime/libUE4SS.so', 'lib');
  write('runtime/BrickadiaBridge/main.so', 'mod');
  write(`runtime/${STAMP}`, JSON.stringify(runtimeKeys(dir)));
}

test('a server start needs both binaries', () => {
  const { dir, write } = checkout();
  assert.throws(() => checkRuntime(dir, { info() {}, warn() {} }), /lacks/);
  write('runtime/libUE4SS.so', 'lib');
  assert.throws(() => checkRuntime(dir, { info() {}, warn() {} }), /main\.so/);
});

test('a server start warns when the binaries were built from other source', () => {
  const { dir, write } = checkout();
  installed(dir, write);
  const warnings: unknown[] = [];
  const log = { info() {}, warn: (...a: unknown[]) => void warnings.push(a) };
  checkRuntime(dir, log);
  assert.equal(warnings.length, 0);
  write('native/BrickadiaBridge/src/main.cpp', 'int main2;');
  checkRuntime(dir, log);
  assert.equal(warnings.length, 1);
});

test('a local build is never other source', () => {
  const { dir, write } = checkout();
  write('runtime/.local', '');
  write('runtime/libUE4SS.so', 'lib');
  write('runtime/BrickadiaBridge/main.so', 'mod');
  write('native/BrickadiaBridge/src/main.cpp', 'changed');
  const warnings: unknown[] = [];
  checkRuntime(dir, { info() {}, warn: (...a: unknown[]) => void warnings.push(a) });
  assert.deepEqual(warnings, []);
});

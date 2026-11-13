// Run by Node directly (type stripping), with the tools: `npm test`.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { runtimeAssets, runtimeKeys } from '../src/runtime-keys.ts';
import { fetchRuntime, NotPublished } from './fetch-runtime.ts';

function checkout() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omegga-ue4ss-fetch-'));
  const write = (rel: string, text: string) => {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  };
  write('native/build.sh', 'build');
  write('native/patches/RE-UE4SS.patch', 'diff');
  write('native/BrickadiaBridge/src/main.cpp', 'int main;');
  return { dir, write };
}

async function serve(files: Map<string, string>) {
  const server = http.createServer((req, res) => {
    const body = files.get((req.url ?? '').slice(1));
    res.writeHead(body === undefined ? 404 : 200).end(body);
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  return {
    url: `http://127.0.0.1:${address.port}`,
    close: () => server.close(),
  };
}

const quiet = { info() {} };
const installed = (dir: string) =>
  ['libUE4SS.so', 'BrickadiaBridge/main.so'].map(f =>
    fs.readFileSync(path.join(dir, 'runtime', f), 'utf8'),
  );

test('fetches each binary by key, and only the one that changed', async () => {
  const { dir, write } = checkout();
  const served = new Map<string, string>();
  const server = await serve(served);
  try {
    let assets = runtimeAssets(runtimeKeys(dir));
    served.set(assets.ue4ss, 'lib1').set(assets.mod, 'mod1');
    assert.deepEqual(await fetchRuntime(dir, server.url, quiet), [
      'ue4ss',
      'mod',
    ]);
    assert.deepEqual(installed(dir), ['lib1', 'mod1']);
    assert.deepEqual(
      await fetchRuntime(dir, server.url, quiet),
      [],
      'nothing changed, nothing fetched',
    );

    write('native/BrickadiaBridge/src/main.cpp', 'int main2;');
    assets = runtimeAssets(runtimeKeys(dir));
    served.set(assets.mod, 'mod2');
    assert.deepEqual(await fetchRuntime(dir, server.url, quiet), ['mod']);
    assert.deepEqual(installed(dir), ['lib1', 'mod2']);
  } finally {
    server.close();
  }
});

test('a failed download leaves the installed pair as it was', async () => {
  const { dir, write } = checkout();
  const served = new Map<string, string>();
  const server = await serve(served);
  try {
    const before = runtimeAssets(runtimeKeys(dir));
    served.set(before.ue4ss, 'lib1').set(before.mod, 'mod1');
    await fetchRuntime(dir, server.url, quiet);

    // a UE4SS change: the new libUE4SS is published, its mod isn't yet
    write('native/patches/RE-UE4SS.patch', 'diff2');
    served.set(runtimeAssets(runtimeKeys(dir)).ue4ss, 'lib2');
    await assert.rejects(fetchRuntime(dir, server.url, quiet), NotPublished);
    assert.deepEqual(
      installed(dir),
      ['lib1', 'mod1'],
      'no new libUE4SS under the old mod',
    );
  } finally {
    server.close();
  }
});

test('a local build in runtime/ is never replaced', async () => {
  const { dir, write } = checkout();
  write('runtime/.local', '');
  write('runtime/libUE4SS.so', 'local lib');
  write('runtime/BrickadiaBridge/main.so', 'local mod');
  assert.deepEqual(await fetchRuntime(dir, 'http://127.0.0.1:9/', quiet), []);
  assert.deepEqual(installed(dir), ['local lib', 'local mod']);
});

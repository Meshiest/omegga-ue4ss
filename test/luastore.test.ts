import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { type KeyValueStore, LuaStore } from '../src/luastore';

function memory(): KeyValueStore & { map: Map<string, unknown> } {
  const map = new Map<string, unknown>();
  return {
    map,
    // like omegga's PluginStorage, null for a missing key
    get: async key => (map.has(key) ? map.get(key) : null),
    set: async (key, value) => void map.set(key, value),
    delete: async key => void map.delete(key),
    keys: async () => [...map.keys()],
  };
}

test('keeps tables under lua: and lists only those', async () => {
  const kv = memory();
  kv.map.set('other', 1);
  const s = new LuaStore(kv);
  await s.handle(['set', 'scores', { a: 1 }]);
  assert.deepEqual(await s.handle(['all']), { scores: { a: 1 } });
  await s.handle(['delete', 'scores']);
  assert.deepEqual(await s.handle(['all']), {});
  await assert.rejects(s.handle(['set', '../x', {}]));
  await assert.rejects(s.handle(['set', 'x', 5]));
  await assert.rejects(s.handle(['drop', 'x']));
});

test('imports the old JSON files once', async () => {
  // under the build output, not a system temp directory
  const dir = path.join(__dirname, 'luastore-import');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  try {
    fs.writeFileSync(path.join(dir, 'perms.json'), '{"roles":{}}');
    fs.writeFileSync(path.join(dir, 'kept.json'), '{"old":true}');
    fs.writeFileSync(path.join(dir, 'broken.json'), '{');
    const kv = memory();
    kv.map.set('lua:kept', { new: true });
    const s = new LuaStore(kv);
    assert.equal(await s.importFiles(dir), 1);
    assert.deepEqual(await s.handle(['all']), { perms: { roles: {} }, kept: { new: true } });
    // a store deleted after the import doesn't come back
    await s.handle(['delete', 'perms']);
    assert.equal(await s.importFiles(dir), 0);
    assert.deepEqual(await s.handle(['all']), { kept: { new: true } });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

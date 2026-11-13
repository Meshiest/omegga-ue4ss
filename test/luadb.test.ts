import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { LuaDatabases, parseSql } from '../src/luadb';

test('checks requests from Lua', () => {
  assert.deepEqual(parseSql(['kills', 'run', 'insert into t values (?, ?)', [1, true]]), {
    name: 'kills', op: 'run', sql: 'insert into t values (?, ?)', params: [1, 1],
  });
  // an empty Lua table arrives as {}
  assert.deepEqual(parseSql(['kills', 'query', 'select 1', {}]), { name: 'kills', op: 'query', sql: 'select 1', params: [] });
  assert.equal(typeof parseSql(['../x', 'query', 'select 1', []]), 'string');
  assert.equal(typeof parseSql(['x', 'drop', 'select 1', []]), 'string');
  assert.equal(typeof parseSql(['x', 'run', 'select ?', [{}]]), 'string');
});

test('runs schema, writes and queries', () => {
  // under the build output, not a system temp directory
  const dir = path.join(__dirname, 'luadb-test');
  fs.rmSync(dir, { recursive: true, force: true });
  const dbs = new LuaDatabases(dir);
  try {
    dbs.run({ name: 'h', op: 'exec', sql: 'create table k (who text, n integer)', params: [] });
    assert.deepEqual(dbs.run({ name: 'h', op: 'run', sql: 'insert into k values (?, ?)', params: ['a', 2] }), { changes: 1, last_id: 1 });
    dbs.run({ name: 'h', op: 'run', sql: 'insert into k values (?, ?)', params: ['b', 5] });
    const rows = dbs.run({ name: 'h', op: 'query', sql: 'select who, n from k order by n desc', params: [] });
    assert.deepEqual(JSON.parse(JSON.stringify(rows)), [{ who: 'b', n: 5 }, { who: 'a', n: 2 }]);
    assert.ok(fs.existsSync(path.join(dir, 'h.sqlite')));
  } finally {
    dbs.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('SQL stays inside its own file', () => {
  const dir = path.join(__dirname, 'luadb-escape');
  fs.rmSync(dir, { recursive: true, force: true });
  const dbs = new LuaDatabases(dir);
  const outside = path.join(__dirname, 'luadb-escape-out.sqlite');
  try {
    dbs.run({ name: 'h', op: 'exec', sql: 'create table k (n integer)', params: [] });
    for (const sql of [
      `attach database '${outside}' as o`,
      `vacuum into '${outside}'`,
      `pragma temp_store_directory = '${dir}'`,
    ]) {
      assert.throws(() => dbs.run({ name: 'h', op: 'exec', sql, params: [] }), /authoriz|not authorized/i, sql);
    }
    assert.ok(!fs.existsSync(outside));
    // schema pragmas still read
    assert.match(JSON.stringify(dbs.run({ name: 'h', op: 'query', sql: 'pragma table_info(k)', params: [] })), /"name":"n"/);
  } finally {
    dbs.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(outside, { force: true });
  }
});

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { outputLines, parseCommand, readModCommands } from '../src/consolecmd';

test('parses a declared command', () => {
  assert.deepEqual(parseCommand({ name: '/Arena', description: 'rounds', args: [{ name: 'action', required: true }, 5] }), {
    name: 'arena',
    description: 'rounds',
    args: [{ name: 'action', description: '', required: true }],
  });
  assert.equal(parseCommand({ name: 'two words' }), undefined);
  assert.equal(parseCommand('arena'), undefined);
});

test('reads each mod doc.json, first mod keeps a name', () => {
  // under the build output, not a system temp directory
  const dir = path.join(__dirname, 'consolecmd-mods');
  fs.rmSync(dir, { recursive: true, force: true });
  try {
    for (const [mod, doc] of [
      ['Alpha', { consoleCommands: [{ name: 'arena', description: 'a' }, { name: 'shared' }] }],
      ['Beta', { consoleCommands: [{ name: 'shared' }, { name: 'beta' }], commands: [{ name: 'heal' }] }],
    ] as const) {
      fs.mkdirSync(path.join(dir, mod), { recursive: true });
      fs.writeFileSync(path.join(dir, mod, 'doc.json'), JSON.stringify(doc));
    }
    fs.mkdirSync(path.join(dir, 'Broken'));
    fs.writeFileSync(path.join(dir, 'Broken', 'doc.json'), '{');
    const warnings: unknown[][] = [];
    const list = readModCommands([dir, path.join(dir, 'missing')], (...a) => warnings.push(a));
    assert.deepEqual(list.map(c => `${c.mod}:${c.command.name}`), ['Alpha:arena', 'Alpha:shared', 'Beta:beta']);
    assert.equal(warnings.length, 2);
    const chat = readModCommands([dir], () => {}, 'commands');
    assert.deepEqual(chat.map(c => `${c.mod}:${c.command.name}`), ['Beta:heal']);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('turns handler results into lines', () => {
  assert.deepEqual(outputLines('a\nb'), ['a', 'b']);
  assert.deepEqual(outputLines(['x', 'y']), ['x', 'y']);
  assert.deepEqual(outputLines(null), []);
  assert.deepEqual(outputLines({ a: 1 }), ['{', '  "a": 1', '}']);
});

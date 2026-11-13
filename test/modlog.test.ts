import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { type ModError, ModLogParser, ModLogWatcher } from '../src/modlog';

const T = '[2026-11-12 08:57:31.608964297] ';

function feed(lines: string[]) {
  const p = new ModLogParser();
  return lines.flatMap(l => p.line(l));
}

test('a main.lua that raised is one error naming the mod', () => {
  const errs = feed([
    `${T}[Lua] [ErrTest] starting`,
    `${T}Error executing script: ...a/Mods/ErrTest/Scripts/main.lua:4: attempt to index a nil value (field 'removed')`,
    'stack traceback:',
    '\t...a/Mods/ErrTest/Scripts/main.lua:4: in main chunk',
    `${T}Failed to execute main script: /srv/data/Mods/ErrTest/Scripts/main.lua`,
    `${T}Starting mods`,
  ]);
  assert.equal(errs.length, 1);
  assert.equal(errs[0].mod, 'ErrTest');
  assert.equal(errs[0].failedToStart, true);
  assert.match(errs[0].message, /field 'removed'\)\nstack traceback:\n\t.*in main chunk$/);
});

test('handler errors from BR and from UE4SS callbacks', () => {
  const errs = feed([
    `${T}[Lua] [BR error] BR.event.on chat: /p/plugins/x/mods/Greeter/Scripts/main.lua:3: boom`,
    `${T}[Lua::call_function] lua_pcall returned LUA_ERRRUN => .../Mods/Hooky/Scripts/main.lua:9: nil`,
    `${T}[Lua] [BR error] BR.timer: .../Mods/shared/omegga/brickadia/bot.lua:1: inside BR`,
    `${T}[Lua] an ordinary print`,
  ]);
  assert.deepEqual(
    errs.map(e => [e.mod, e.failedToStart]),
    [['Greeter', false], ['Hooky', false], [undefined, false]],
  );
});

test('an error with no closing line is still reported', () => {
  const errs = feed([`${T}Error executing script: x.lua:1: oops`, `${T}something else`]);
  assert.equal(errs.length, 1);
  assert.equal(errs[0].failedToStart, false);
});

test('the watcher skips old errors, follows new ones, and quiets repeats', () => {
  const dir = path.join(__dirname, '..', '..', '.scratch', 'modlog-test');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'UE4SS.log');
  const boom = `${T}[Lua] [BR error] BR.timer: .../Mods/A/Scripts/main.lua:1: boom\n`;
  fs.writeFileSync(file, `${T}first\n${boom}`);
  const got: [ModError, number][] = [];
  const w = new ModLogWatcher(file, (e, n) => got.push([e, n]));
  w.start(1_000_000);
  w.poll();
  assert.equal(got.length, 0);
  fs.appendFileSync(file, boom + boom);
  w.poll();
  assert.equal(got.length, 1);
  assert.equal(got[0][0].mod, 'A');
  // a new game start writes a fresh log
  fs.writeFileSync(file, `[2026-11-12 09:00:00.000000000] first\n${T}[Lua] [BR error] BR.timer: other\n`);
  w.poll();
  assert.equal(got.length, 2);
  w.stop();
  fs.rmSync(dir, { recursive: true, force: true });
});

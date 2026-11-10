import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { Bridge, type InteropHost } from '../src/bridge';
import { buildChangelist } from '../src/version';

/**
 * Plays the game side of the socket: the C++ mod plus Lua. `onLine` sees each
 * `<target>\t<json>` line a client sends; `send` writes a line back.
 */
async function fakeGame(onLine: (target: string, message: Record<string, unknown>, send: (m: object) => void) => void) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omegga-ue4ss-'));
  const sock = path.join(dir, 'bridge.sock');
  const clients = new Set<net.Socket>();
  const server = net.createServer(c => {
    clients.add(c);
    c.setEncoding('utf8');
    let buf = '';
    const send = (m: object) => c.write(`${JSON.stringify(m)}\n`);
    c.on('data', (chunk: string) => {
      buf += chunk;
      let nl: number;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        const tab = line.indexOf('\t');
        onLine(line.slice(0, tab), JSON.parse(line.slice(tab + 1)), send);
      }
    });
  });
  await new Promise<void>(r => server.listen(sock, r));
  return {
    sock,
    broadcast: (m: object) => clients.forEach(c => c.write(`${JSON.stringify(m)}\n`)),
    close: () => {
      clients.forEach(c => c.destroy());
      server.close();
    },
  };
}

function recordingHost() {
  const seen: { emits: [string, unknown][]; calls: [string, string, unknown[]][] } = { emits: [], calls: [] };
  const host: InteropHost = {
    emit: (event, data) => void seen.emits.push([event, data]),
    call: async (plugin, event, args) => {
      seen.calls.push([plugin, event, args]);
      if (event === 'fail') throw new Error('nope');
      return (args as number[]).reduce((a, b) => a + b, 0);
    },
    warn: () => {},
  };
  return { host, seen };
}

const until = async (ok: () => boolean) => {
  for (let i = 0; i < 200 && !ok(); i++) await new Promise(r => setTimeout(r, 5));
};

test('exec goes to the bridge mod and the answer comes back by id', async () => {
  const game = await fakeGame((target, m, send) => {
    assert.equal(target, 'BrickadiaBridge');
    send({ t: 'result', id: m.id, ok: true, result: `ran ${m.lua}` });
  });
  const bridge = new Bridge(game.sock);
  assert.deepEqual(await bridge.exec('1 + 1'), { ok: true, result: 'ran 1 + 1' });
  assert.equal(await bridge.eval('x'), 'ran x');
  bridge.close();
  game.close();
});

test('events, calls from Lua, and calls into the mod that registered a handler', async () => {
  const replies: Record<string, unknown>[] = [];
  const game = await fakeGame((target, m, send) => {
    if (m.t === 'reply') replies.push({ target, ...m });
    else if (m.t === 'call' && target === 'abc') send({ t: 'result', id: m.id, ok: true, result: `hi ${(m.args as string[])[0]}` });
  });
  const { host, seen } = recordingHost();
  const bridge = new Bridge(game.sock, host);
  bridge.start(10);
  await until(() => bridge.connected);

  game.broadcast({ t: 'event', mod: 'abc', event: 'hello', data: { x: 1 } });
  game.broadcast({ t: 'call', mod: 'abc', id: 'abc-1', plugin: 'p', event: 'add', args: [2, 3] });
  game.broadcast({ t: 'call', mod: 'abc', id: 'abc-2', plugin: 'p', event: 'fail', args: [] });
  game.broadcast({ t: 'register', mod: 'abc', name: 'greet' });
  await until(() => replies.length === 2 && bridge.handlers.has('greet'));

  assert.deepEqual(seen.emits, [['hello', { x: 1 }]]);
  assert.deepEqual(replies, [
    { target: 'abc', t: 'reply', id: 'abc-1', ok: true, result: 5 },
    { target: 'abc', t: 'reply', id: 'abc-2', ok: false, error: 'nope' },
  ]);
  assert.deepEqual(await bridge.callLua('greet', ['world']), { ok: true, result: 'hi world' });
  bridge.close();
  game.close();
});

test('failures resolve instead of throwing', async () => {
  const missing = new Bridge(path.join(os.tmpdir(), 'omegga-ue4ss-no-such.sock'));
  const r = await missing.exec('1');
  assert.equal(r.ok, false);

  const game = await fakeGame((target, m, send) => {
    if (target === 'gone') send({ t: 'undeliverable', target, message: m });
  });
  const bridge = new Bridge(game.sock);
  assert.deepEqual(await bridge.callLua('nope', []), { ok: false, error: 'no Lua handler named nope' });
  bridge.handlers.set('h', 'gone');
  assert.deepEqual(await bridge.callLua('h', []), { ok: false, error: 'no Lua listener gone (was its mod stopped?)' });
  assert.deepEqual(await bridge.exec('slow', 50), { ok: false, error: 'the bridge did not answer in 50 ms' });
  bridge.close();
  game.close();
});

test('reads the build changelist stamp', () => {
  assert.equal(buildChangelist(Buffer.from('x Release-X (PC-Shipping-CL12345) y', 'utf16le')), 12345);
  assert.equal(buildChangelist(Buffer.from('%s-CL-%u', 'utf16le')), null);
  assert.equal(buildChangelist(Buffer.from('(PC-Shipping-CL1) (PC-Shipping-CL2)', 'utf16le')), null);
});

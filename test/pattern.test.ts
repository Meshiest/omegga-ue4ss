import assert from 'node:assert/strict';
import { test } from 'node:test';
import { Pattern } from '../src/pattern';

test('finds every masked match', () => {
  const data = Buffer.from([0x90, 0x48, 0x8b, 0x05, 0x11, 0x48, 0x8b, 0x05, 0x22, 0x48, 0x8b]);
  assert.deepEqual(new Pattern('48 8B 05 ??').scan(data), [1, 5]);
});

test('respects the scan range', () => {
  const data = Buffer.from([0x48, 0x8b, 0x48, 0x8b]);
  assert.deepEqual(new Pattern('48 8B').scan(data, 1), [2]);
  assert.deepEqual(new Pattern('48 8B').scan(data, 0, 3), [0]);
});

test('rejects all-wildcard patterns', () => {
  assert.throws(() => new Pattern('?? ??'));
});

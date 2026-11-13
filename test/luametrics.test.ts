import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { MetricCounter, MetricGauge, MetricHistogram, PluginMetricLabels, PM } from 'omegga';
import { LuaMetrics, parseUpdate } from '../src/luametrics';

test('parses updates and refuses bad ones', () => {
  assert.deepEqual(parseUpdate({ kind: 'counter', op: 'inc', name: 'kills', value: 2, labels: {} }), {
    kind: 'counter', op: 'inc', name: 'kills', help: 'kills', value: 2, labels: undefined, labelNames: undefined, buckets: undefined,
  });
  assert.match(String(parseUpdate({ kind: 'counter', op: 'inc', name: 'Bad-Name' })), /bad name/);
  assert.match(String(parseUpdate({ kind: 'meter', op: 'inc', name: 'x' })), /bad kind/);
  assert.match(String(parseUpdate({ kind: 'gauge', op: 'set', name: 'x', labels: { a: {} } })), /labels/);
});

test('applies updates to the plugin registry', () => {
  const calls: string[] = [];
  const counter: MetricCounter = {
    inc: (a?: number | PluginMetricLabels, b?: number) => void calls.push(`inc ${JSON.stringify(a)} ${b ?? ''}`.trim()),
    reset: () => void calls.push('reset'),
  };
  const gauge: MetricGauge = {
    set: (a: number | PluginMetricLabels, b?: number) => void calls.push(`set ${JSON.stringify(a)} ${b ?? ''}`.trim()),
    inc: () => {}, dec: () => {}, remove: () => {}, collect: () => {}, reset: () => {},
  };
  const histogram: MetricHistogram = { observe: () => {}, startTimer: () => () => 0, reset: () => {} };
  const pm: PM = { enabled: true, counter: () => counter, gauge: () => gauge, histogram: () => histogram };
  const warnings: unknown[][] = [];
  const m = new LuaMetrics(pm, (...a) => warnings.push(a));
  m.apply({ kind: 'counter', op: 'inc', name: 'kills', value: 1, labels: { team: 'red' } });
  m.apply({ kind: 'gauge', op: 'set', name: 'players', value: 4 });
  m.apply({ kind: 'gauge', op: 'set', name: 'kills', value: 4 });
  assert.deepEqual(calls, ['inc {"team":"red"} 1', 'set 4']);
  assert.equal(warnings.length, 1);
});

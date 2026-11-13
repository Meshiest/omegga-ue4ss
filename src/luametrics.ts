import type { MetricCounter, MetricGauge, MetricHistogram, PluginMetricLabels, PluginMetrics } from './metric-types';

/**
 * One metric update from Lua (BR.metrics), sent as the Lua event "metric".
 * `kind` picks the handle, `op` what to do with it.
 */
export interface MetricUpdate {
  kind: 'counter' | 'gauge' | 'histogram';
  op: 'inc' | 'dec' | 'set' | 'observe' | 'reset';
  name: string;
  help: string;
  value?: number;
  labels?: PluginMetricLabels;
  /** the label names the metric is declared with; omegga refuses others */
  labelNames?: string[];
  buckets?: number[];
}

const KINDS: readonly MetricUpdate['kind'][] = ['counter', 'gauge', 'histogram'];
const OPS: readonly MetricUpdate['op'][] = ['inc', 'dec', 'set', 'observe', 'reset'];
// omegga's own rule for plugin metric names
const NAME = /^[a-z][a-z0-9_]*$/;

const isKind = (v: unknown): v is MetricUpdate['kind'] => KINDS.some(k => k === v);
const isOp = (v: unknown): v is MetricUpdate['op'] => OPS.some(o => o === v);

function isLabels(v: unknown): v is PluginMetricLabels {
  return (
    typeof v === 'object' &&
    v !== null &&
    !Array.isArray(v) &&
    Object.values(v).every(x => ['string', 'number', 'boolean'].includes(typeof x))
  );
}

/** The update `data` describes, or a reason it doesn't describe one. */
export function parseUpdate(data: unknown): MetricUpdate | string {
  if (typeof data !== 'object' || data === null) return 'not an object';
  const kind = 'kind' in data ? data.kind : undefined;
  const op = 'op' in data ? data.op : undefined;
  const name = 'name' in data ? data.name : undefined;
  const help = 'help' in data ? data.help : undefined;
  const value = 'value' in data ? data.value : undefined;
  const labels = 'labels' in data ? data.labels : undefined;
  const buckets = 'buckets' in data ? data.buckets : undefined;
  const labelNames = 'label_names' in data ? data.label_names : undefined;
  if (!isKind(kind)) return `bad kind ${String(kind)}`;
  if (!isOp(op)) return `bad op ${String(op)}`;
  if (typeof name !== 'string' || !NAME.test(name)) return `bad name ${String(name)}: lowercase letters, digits and _`;
  if (value !== undefined && (typeof value !== 'number' || !Number.isFinite(value))) return 'value is not a number';
  // Lua sends an empty table as {}, which means no labels
  const noLabels = labels === undefined || (typeof labels === 'object' && labels !== null && Object.keys(labels).length === 0);
  if (!noLabels && !isLabels(labels)) return 'labels are not { name = string|number|boolean }';
  if (buckets !== undefined && !(Array.isArray(buckets) && buckets.every(b => typeof b === 'number'))) return 'buckets are not numbers';
  if (labelNames !== undefined && !(Array.isArray(labelNames) && labelNames.every(n => typeof n === 'string'))) return 'labels (names) are not strings';
  return {
    kind,
    op,
    name,
    help: typeof help === 'string' && help ? help : name,
    value,
    labels: !noLabels && isLabels(labels) ? labels : undefined,
    labelNames: Array.isArray(labelNames) ? labelNames.filter((n): n is string => typeof n === 'string') : undefined,
    buckets: Array.isArray(buckets) ? buckets.filter((b): b is number => typeof b === 'number') : undefined,
  };
}

type Handle =
  | { kind: 'counter'; h: MetricCounter }
  | { kind: 'gauge'; h: MetricGauge }
  | { kind: 'histogram'; h: MetricHistogram };

/**
 * Applies BR.metrics updates to this plugin's Prometheus registry, so Lua
 * mods' metrics come out as `omegga_plugin_ue4ss_<name>`. A name keeps the kind
 * it was first used with.
 */
export class LuaMetrics {
  readonly #handles = new Map<string, Handle>();

  constructor(
    private readonly metrics: PluginMetrics | undefined,
    private readonly warn: (...args: unknown[]) => void,
  ) {}

  #handle(u: MetricUpdate): Handle | undefined {
    const known = this.#handles.get(u.name);
    if (known) return known.kind === u.kind ? known : undefined;
    if (!this.metrics) return undefined;
    const opts = { name: u.name, help: u.help, labels: u.labelNames };
    const made: Handle =
      u.kind === 'counter'
        ? { kind: 'counter', h: this.metrics.counter(opts) }
        : u.kind === 'gauge'
          ? { kind: 'gauge', h: this.metrics.gauge(opts) }
          : { kind: 'histogram', h: this.metrics.histogram({ ...opts, buckets: u.buckets }) };
    this.#handles.set(u.name, made);
    return made;
  }

  apply(data: unknown) {
    const u = parseUpdate(data);
    if (typeof u === 'string') return this.warn('BR.metrics:', u);
    const handle = this.#handle(u);
    if (!handle) {
      if (this.metrics) this.warn(`BR.metrics: ${u.name} is already a ${this.#handles.get(u.name)?.kind}`);
      return;
    }
    const v = u.value;
    const labels = u.labels;
    if (u.op === 'reset') return handle.h.reset();
    switch (handle.kind) {
      case 'counter':
        if (u.op !== 'inc') return this.warn(`BR.metrics: a counter can't ${u.op}`);
        return labels ? handle.h.inc(labels, v ?? 1) : handle.h.inc(v ?? 1);
      case 'gauge':
        if (u.op === 'set') return labels ? handle.h.set(labels, v ?? 0) : handle.h.set(v ?? 0);
        if (u.op === 'inc') return labels ? handle.h.inc(labels, v ?? 1) : handle.h.inc(v ?? 1);
        if (u.op === 'dec') return labels ? handle.h.dec(labels, v ?? 1) : handle.h.dec(v ?? 1);
        return this.warn(`BR.metrics: a gauge can't ${u.op}`);
      case 'histogram':
        if (u.op !== 'observe' || v === undefined) return this.warn('BR.metrics: a histogram observes a value');
        return labels ? handle.h.observe(labels, v) : handle.h.observe(v);
    }
  }
}

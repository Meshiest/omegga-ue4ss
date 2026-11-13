/**
 * omegga's plugin metrics types, as LuaMetrics and its tests need them.
 * omegga.d.ts isn't in the repo (omegga copies it in on load) and src and test
 * are built without it, as in CI, so these mirror its declarations. omegga's
 * own PluginMetrics satisfies them.
 */

export type PluginMetricLabels = Record<string, string | number | boolean>;

export interface PluginMetricOptions {
  name: string;
  help?: string;
  labels?: string[];
}

export interface MetricCounter {
  inc(value?: number): void;
  inc(labels: PluginMetricLabels, value?: number): void;
  reset(): void;
}

export interface MetricGauge {
  set(value: number): void;
  set(labels: PluginMetricLabels, value: number): void;
  inc(value?: number): void;
  inc(labels: PluginMetricLabels, value?: number): void;
  dec(value?: number): void;
  dec(labels: PluginMetricLabels, value?: number): void;
  remove(labels?: PluginMetricLabels): void;
  collect(fn: () => number | void): void;
  reset(): void;
}

export interface MetricHistogram {
  observe(value: number): void;
  observe(labels: PluginMetricLabels, value: number): void;
  startTimer(labels?: PluginMetricLabels): () => number;
  reset(): void;
}

export interface PluginMetrics {
  readonly enabled: boolean;
  counter(opts: PluginMetricOptions): MetricCounter;
  gauge(opts: PluginMetricOptions): MetricGauge;
  histogram(opts: PluginMetricOptions & { buckets?: number[] }): MetricHistogram;
}

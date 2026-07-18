import { useQuery } from '@tanstack/solid-query';
import { createSignal, createMemo, onMount, For, Show } from 'solid-js';
import { AreaChart, BarChart, LineChart, type Datum } from '../components/charts';
import { Skeleton } from '../components/Skeleton';
import { t } from '../i18n';
import { formatDuration, truncate } from '../utils';
import { basePath } from '../basePath';

// Matches Wurk::Api::Serializers.metric_row — processed (successes), failed,
// and total runtime ms across both.
interface TopJob {
  klass: string;
  processed: number;
  failed: number;
  runtime_ms: number;
}

interface MetricsResponse {
  minutes: number;
  top_jobs: TopJob[];
}

interface HistoryPoint {
  at: number;
  processed: number;
  failed: number;
  runtime_ms: number;
}

interface HistoryResponse {
  bucket: string;
  window: number;
  series: HistoryPoint[];
}

interface QueueGaugePoint {
  at: number;
  size: number;
  latency: number;
}

interface QueueSeries {
  name: string;
  points: QueueGaugePoint[];
}

interface QueueHistoryResponse {
  bucket: string;
  window: number;
  queues: QueueSeries[];
}

interface StatsData {
  processed: number;
  failed: number;
  latency: number;
  processes: number;
}

const QUEUE_COLORS = [
  'var(--accent)', '#e0b341', '#46b3a8', '#d4737e', '#8a7fd1', '#5fa8d3', '#c08457', '#7bb274',
] as const;
const queueColor = (i: number) => QUEUE_COLORS[i % QUEUE_COLORS.length];

// Greyscale dots for the Top Job Types table (luminance, not hue).
const JOB_DOTS = ['#fafafa', '#d4d4d8', '#a1a1aa', '#71717a', '#52525b', '#3f3f46'];

// Range buttons → rollup bucket + retention window. "1h" reuses the 1m/24h
// rollup and slices client-side; the rest map 1:1 to a stored window.
// `minutes` is the corresponding /api/metrics window so Top Job Types tracks
// the toolbar instead of being permanently pinned to the last hour.
const RANGES = [
  { key: '1h', bucket: '1m', window: '24h', slice: 60, minutes: 60 },
  { key: '24h', bucket: '1m', window: '24h', minutes: 24 * 60 },
  { key: '7d', bucket: '5m', window: '7d', minutes: 7 * 24 * 60 },
  { key: '30d', bucket: '1h', window: '30d', minutes: 30 * 24 * 60 },
] as const;

const fmtBucket = (at: number, bucket: string) => {
  const d = new Date(at * 1000);
  const hh = String(d.getHours()).padStart(2, '0');
  return bucket === '1h'
    ? `${d.getMonth() + 1}/${d.getDate()} ${hh}:00`
    : `${hh}:${String(d.getMinutes()).padStart(2, '0')}`;
};

function deltaPct(series: HistoryPoint[], key: 'processed' | 'failed'): number | null {
  if (series.length < 2) return null;
  const now = series[series.length - 1].at;
  let cur = 0;
  let prev = 0;
  for (const p of series) {
    if (p.at > now - 3600) cur += p[key];
    else if (p.at > now - 7200) prev += p[key];
  }
  if (prev === 0) return cur === 0 ? null : 100;
  return Math.round(((cur - prev) / prev) * 100);
}

function Delta(props: { pct: number | null; goodWhenUp: boolean }) {
  return (
    <Show when={props.pct !== null}>
      {(() => {
        const up = () => props.pct! >= 0;
        const good = () => up() === props.goodWhenUp;
        return (
          <span style={{ 'font-size': '12px', 'margin-inline-start': '8px', color: good() ? 'var(--success)' : 'var(--danger)' }}>
            {up() ? '↑' : '↓'}{Math.abs(props.pct!)}%
          </span>
        );
      })()}
    </Show>
  );
}

// Even downsample that anchors both endpoints — Math.floor with step =
// arr.length/n never lands on the last index, so the highlighted peak could
// silently drop the newest bucket. Math.round across (n-1) intervals keeps
// the latest sample.
const sample = <T,>(arr: T[], n: number): T[] => {
  if (n <= 0) return [];
  if (arr.length <= n) return arr;
  if (n === 1) return [arr[arr.length - 1]];
  const step = (arr.length - 1) / (n - 1);
  return Array.from({ length: n }, (_, i) => arr[Math.round(i * step)]);
};

// Centered spinner sized to a chart/table box. Shown while a query is pending —
// i.e. the initial load and every range-filter change, where the query key flips
// and there's no cached data yet — so the panel doesn't flash an empty state for
// a beat before the data lands.
function ChartLoader(props: { height: number }) {
  return (
    <div style={{ height: `${props.height}px` }} role="status" aria-label={t('common.loading')}>
      <Skeleton height="100%" />
    </div>
  );
}

export default function Metrics() {
  const [rangeIdx, setRangeIdx] = createSignal(2); // default 7d, matching the mock
  const range = () => RANGES[rangeIdx()];

  onMount(() => {
    document.title = `${t('nav.metrics')} — Wurk`;
  });

  const statsQuery = useQuery(() => ({
    queryKey: ['stats'],
    queryFn: () => fetch(`${basePath()}/api/stats`).then((r) => r.json() as Promise<StatsData>),
    refetchInterval: 5000,
  }));

  const historyQuery = useQuery(() => ({
    queryKey: ['history', range().bucket, range().window],
    queryFn: () =>
      fetch(`${basePath()}/api/history/${range().bucket}?window=${range().window}`).then((r) => r.json() as Promise<HistoryResponse>),
    refetchInterval: 30000,
  }));

  const metricsQuery = useQuery(() => ({
    queryKey: ['metrics', range().minutes],
    queryFn: () => fetch(`${basePath()}/api/metrics?minutes=${range().minutes}`).then((r) => r.json() as Promise<MetricsResponse>),
    refetchInterval: 30000,
  }));

  const queueQuery = useQuery(() => ({
    queryKey: ['queue-history', range().bucket, range().window],
    queryFn: async () => {
      const r = await fetch(`${basePath()}/api/queue-history/${range().bucket}?window=${range().window}`);
      if (!r.ok) throw new Error(`queue-history failed (${r.status})`);
      return r.json() as Promise<QueueHistoryResponse>;
    },
    refetchInterval: 30000,
  }));

  // Keep the full history for deltaPct() — slicing first would drop the
  // previous-hour comparison window and force the 100% fallback on the 1h tab.
  const fullSeries = createMemo(() =>
    (historyQuery.data?.series ?? []).map((p) => ({ ...p, label: fmtBucket(p.at, range().bucket) })),
  );
  const series = createMemo(() => {
    const r = range();
    const sliceN = 'slice' in r ? r.slice : undefined;
    return sliceN ? fullSeries().slice(-sliceN) : fullSeries();
  });
  const hasThroughput = createMemo(() => series().some((p) => p.processed > 0 || p.failed > 0));

  // Queue depth = total jobs enqueued across all queues per bucket, downsampled
  // to a readable number of bars; the busiest bar is highlighted (design spec).
  const queues = createMemo(() => queueQuery.data?.queues ?? []);
  const ats = createMemo(() => queues()[0]?.points.map((p) => p.at) ?? []);
  const depthRows = createMemo(() =>
    sample(
      ats().map((at, i) => ({
        label: fmtBucket(at, range().bucket),
        depth: queues().reduce((s, q) => s + (q.points[i]?.size ?? 0), 0),
      })),
      16,
    ),
  );
  const maxDepth = createMemo(() => Math.max(0, ...depthRows().map((r) => r.depth)));

  // % Total compares each top job against the full returned volume — the
  // jobs.slice(0, 6) trims the displayed rows only; computing the total off
  // the slice would let three jobs at 30/30/30 each report 33%.
  const allJobs = createMemo(() =>
    (metricsQuery.data?.top_jobs ?? [])
      .map((j) => ({ klass: j.klass, count: j.processed + j.failed }))
      .sort((a, b) => b.count - a.count),
  );
  const jobsTotal = createMemo(() => allJobs().reduce((s, j) => s + j.count, 0));
  const jobs = createMemo(() => allJobs().slice(0, 6));

  return (
    <div class="obs">
      <div class="obs-toolbar">
        <span class="obs-toolbar__label"><i class="fa-regular fa-calendar" aria-hidden="true" /> {t('metrics.time_range')}</span>
        <div class="obs-seg" role="tablist" aria-label={t('metrics.time_range')}>
          <For each={RANGES}>
            {(r, i) => (
              <button
                role="tab"
                aria-selected={i() === rangeIdx()}
                class={i() === rangeIdx() ? 'is-active' : ''}
                onClick={() => setRangeIdx(i())}
              >
                {r.key}
              </button>
            )}
          </For>
        </div>
      </div>

      <div class="obs-metrics">
        <div class="obs-card obs-metric">
          <div class="obs-metric__head">
            <span class="obs-mono">{t('metrics.total_processed')}</span>
            <i class="fa-solid fa-circle-check obs-metric__icon" aria-hidden="true" />
          </div>
          <span class="obs-metric__value">
            {(statsQuery.data?.processed ?? 0).toLocaleString()}
            <Delta pct={deltaPct(fullSeries(), 'processed')} goodWhenUp />
          </span>
          <span class="obs-metric__sub">{t('metrics.across_all_queues')}</span>
        </div>
        <div class="obs-card obs-metric">
          <div class="obs-metric__head">
            <span class="obs-mono">{t('metrics.failed_jobs')}</span>
            <i class="fa-solid fa-triangle-exclamation obs-metric__icon" aria-hidden="true" />
          </div>
          <span class="obs-metric__value">
            {(statsQuery.data?.failed ?? 0).toLocaleString()}
            <Delta pct={deltaPct(fullSeries(), 'failed')} goodWhenUp={false} />
          </span>
          <span class="obs-metric__sub">{t('metrics.total_failures')}</span>
        </div>
        <div class="obs-card obs-metric">
          <div class="obs-metric__head">
            <span class="obs-mono">{t('metrics.avg_latency')}</span>
            <i class="fa-solid fa-stopwatch obs-metric__icon" aria-hidden="true" />
          </div>
          <span class="obs-metric__value">{statsQuery.data ? formatDuration(statsQuery.data.latency) : '—'}</span>
          <span class="obs-metric__sub">{t('metrics.head_of_line')}</span>
        </div>
        <div class="obs-card obs-metric">
          <div class="obs-metric__head">
            <span class="obs-mono">{t('metrics.active_workers')}</span>
            <i class="fa-solid fa-gears obs-metric__icon" aria-hidden="true" />
          </div>
          <span class="obs-metric__value">{(statsQuery.data?.processes ?? 0).toLocaleString()}</span>
          <span class="obs-metric__sub">{(statsQuery.data?.processes ?? 0) > 0 ? t('metrics.stable') : t('metrics.no_workers')}</span>
        </div>
      </div>

      <div class="obs-card obs-panel">
        <div class="obs-panel__head">
          <div>
            <h2 class="obs-panel__title">{t('metrics.throughput_failures')}</h2>
            <p class="obs-panel__sub">{t('metrics.throughput_sub', { range: range().key })}</p>
          </div>
          <div class="obs-legend">
            <span><i class="dot dot--processed" /> {t('dashboard.processed')}</span>
            <span><i class="dot dot--failed" /> {t('dashboard.failed')}</span>
          </div>
        </div>
        <div class="obs-chartbox">
          <Show when={!historyQuery.isPending} fallback={<ChartLoader height={300} />}>
            <Show
              when={hasThroughput()}
              fallback={
                <div class="empty-state" style={{ height: '300px', display: 'grid', 'place-items': 'center' }}>
                  {t('dashboard.no_history')}
                </div>
              }
            >
              <AreaChart
                data={series()}
                height={300}
                yAxisWidth={36}
                yDecimals={false}
                xMinTickGap={56}
                series={[
                  { key: 'processed', name: t('dashboard.processed'), stroke: '#fafafa', strokeWidth: 2, fill: 'gradient' },
                  { key: 'failed', name: t('dashboard.failed'), stroke: '#a1a1aa', strokeWidth: 1.5, strokeDasharray: '5 4', fill: 'none' },
                ]}
              />
            </Show>
          </Show>
        </div>
      </div>

      <div class="obs-grid2">
        <div class="obs-card obs-panel">
          <div class="obs-panel__head">
            <h2 class="obs-panel__title" style={{ 'font-size': '18px' }}>{t('metrics.queue_depth')}</h2>
            <span class="obs-mono">{maxDepth() > 0 ? t('metrics.peak', { n: maxDepth().toLocaleString() }) : ''}</span>
          </div>
          <div class="obs-chartbox">
            <Show when={!queueQuery.isPending} fallback={<ChartLoader height={240} />}>
              <Show
                when={depthRows().length > 0}
                fallback={
                  <div class="empty-state" style={{ height: '240px', display: 'grid', 'place-items': 'center' }}>
                    {t('metrics.no_queue_history')}
                  </div>
                }
              >
                <BarChart
                  data={depthRows().map((r) => ({
                    label: r.label,
                    value: r.depth,
                    color: r.depth === maxDepth() && maxDepth() > 0 ? '#fafafa' : '#3f3f46',
                  }))}
                  height={240}
                  name={t('metrics.queue_depth')}
                  yAxisWidth={36}
                  yDecimals={false}
                  xMinTickGap={40}
                />
              </Show>
            </Show>
          </div>
        </div>

        <div class="obs-card obs-table">
          <div class="obs-table__head">
            <h2 class="obs-table__title" style={{ 'font-size': '18px' }}>{t('metrics.top_job_types')}</h2>
          </div>
          <Show when={!metricsQuery.isPending} fallback={<ChartLoader height={240} />}>
            <Show when={jobs().length > 0} fallback={<div class="obs-empty">{t('common.empty')}</div>}>
              <div class="obs-tablescroll">
                <table>
                  <thead>
                    <tr>
                      <th>{t('metrics.job_class')}</th>
                      <th style={{ 'text-align': 'end' }}>{t('table.count')}</th>
                      <th style={{ 'text-align': 'end' }}>{t('metrics.pct_total')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <For each={jobs()}>
                      {(j, i) => (
                        <tr>
                          <td style={{ color: 'var(--obs-text)' }} title={j.klass}>
                            <span class="obs-jobdot" style={{ background: JOB_DOTS[i() % JOB_DOTS.length] }} />
                            {truncate(j.klass.split('::').pop() ?? j.klass, 36)}
                          </td>
                          <td style={{ 'text-align': 'end', 'font-variant-numeric': 'tabular-nums' }}>{j.count.toLocaleString()}</td>
                          <td class="obs-pct" style={{ 'text-align': 'end' }}>
                            {jobsTotal() > 0 ? Math.round((j.count / jobsTotal()) * 100) : 0}%
                          </td>
                        </tr>
                      )}
                    </For>
                  </tbody>
                </table>
              </div>
            </Show>
          </Show>
        </div>
      </div>

      <QueueLatencyHistory range={range()} />
      <HistoricalSnapshots />
    </div>
  );
}

// Per-queue head-of-line latency over the selected window (Ent Historical tab,
// §5.2) — kept below the mock layout so the feature isn't lost.
function QueueLatencyHistory(props: { range: (typeof RANGES)[number] }) {
  const data = useQuery(() => ({
    queryKey: ['queue-history-lat', props.range.bucket, props.range.window],
    queryFn: async () => {
      const r = await fetch(`${basePath()}/api/queue-history/${props.range.bucket}?window=${props.range.window}`);
      if (!r.ok) throw new Error(`queue-history failed (${r.status})`);
      return r.json() as Promise<QueueHistoryResponse>;
    },
    refetchInterval: 30000,
  }));

  const queues = createMemo(() => data.data?.queues ?? []);
  // Dots in a queue name (`emails.critical`) were a nested-object-accessor
  // hazard in recharts, so we pivot through synthetic `queue_<i>` keys and carry
  // the real queue name for the legend + tooltip.
  const queueKeys = createMemo(() => queues().map((q, i) => ({ key: `queue_${i}`, name: q.name })));
  const ats = createMemo(() => queues()[0]?.points.map((p) => p.at) ?? []);
  const rows = createMemo(() =>
    ats().map((at, i) => {
      const row: Datum = { label: fmtBucket(at, props.range.bucket) };
      queues().forEach((q, qi) => { row[queueKeys()[qi].key] = q.points[i]?.latency ?? 0; });
      return row;
    }),
  );
  const lineSeries = createMemo(() =>
    queueKeys().map((q, i) => ({ key: q.key, name: q.name, stroke: queueColor(i), strokeWidth: 2 })),
  );
  const hasData = createMemo(() => queues().some((q) => q.points.some((p) => p.latency > 0)));

  return (
    <Show when={hasData()}>
      <div class="obs-card obs-panel">
        <div class="obs-panel__head">
          <h2 class="obs-panel__title" style={{ 'font-size': '18px' }}>{t('metrics.queue_latency_seconds')}</h2>
        </div>
        <div class="obs-chartbox">
          <LineChart data={rows()} series={lineSeries()} height={240} legend yAxisWidth={40} xMinTickGap={48} />
        </div>
      </div>
    </Show>
  );
}

interface Snapshot {
  at: number;
  [field: string]: number;
}
const CUMULATIVE_FIELDS = new Set(['processed', 'failures']);

function HistoricalSnapshots() {
  const data = useQuery(() => ({
    queryKey: ['history-snapshots'],
    queryFn: async () => {
      const r = await fetch(`${basePath()}/api/history/snapshots?limit=1000`);
      if (!r.ok) throw new Error(`history snapshots request failed (${r.status})`);
      return r.json() as Promise<{ snapshots: Snapshot[] }>;
    },
    refetchInterval: 30000,
  }));

  const snapshots = createMemo(() => data.data?.snapshots ?? []);
  const fields = createMemo(() =>
    Array.from(
      new Set(
        snapshots().flatMap((s) =>
          Object.keys(s).filter((k) => k !== 'at' && !CUMULATIVE_FIELDS.has(k) && typeof s[k] === 'number'),
        ),
      ),
    ),
  );
  const rows = createMemo(() =>
    snapshots().map((s) => {
      const d = new Date(s.at * 1000);
      const row: Datum = { label: `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}` };
      for (const k of Object.keys(s)) row[k] = s[k];
      return row;
    }),
  );
  const lineSeries = createMemo(() =>
    fields().map((f, i) => ({ key: f, name: f, stroke: queueColor(i), strokeWidth: 2 })),
  );

  return (
    <Show when={snapshots().length > 0 && fields().length > 0}>
      <div class="obs-card obs-panel">
        <div class="obs-panel__head">
          <h2 class="obs-panel__title" style={{ 'font-size': '18px' }}>{t('metrics.historical_snapshots')}</h2>
        </div>
        <div class="obs-chartbox">
          <LineChart data={rows()} series={lineSeries()} height={240} legend yAxisWidth={40} yDecimals={false} xMinTickGap={48} />
        </div>
      </div>
    </Show>
  );
}

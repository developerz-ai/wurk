import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import {
  AreaChart,
  Area,
  BarChart,
  Bar,
  Cell,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts';
import { Skeleton } from '../components/Skeleton';
import { t } from '../i18n';
import { formatDuration, truncate } from '../utils';

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

function Delta({ pct, goodWhenUp }: { pct: number | null; goodWhenUp: boolean }) {
  if (pct === null) return null;
  const up = pct >= 0;
  const good = up === goodWhenUp;
  return (
    <span style={{ fontSize: 12, marginInlineStart: 8, color: good ? 'var(--success)' : 'var(--danger)' }}>
      {up ? '↑' : '↓'}{Math.abs(pct)}%
    </span>
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

const tooltipStyle = {
  background: '#161618',
  border: '1px solid #272729',
  color: '#e4e4e7',
  borderRadius: 6,
  fontSize: 12,
  fontFamily: 'JetBrains Mono, monospace',
};

// Centered spinner sized to a chart/table box. Shown while a query is pending —
// i.e. the initial load and every range-filter change, where the query key flips
// and there's no cached data yet — so the panel doesn't flash an empty state for
// a beat before the data lands.
function ChartLoader({ height }: { height: number }) {
  return (
    <div style={{ height }} role="status" aria-label={t('common.loading')}>
      <Skeleton height="100%" />
    </div>
  );
}

export default function Metrics() {
  const [rangeIdx, setRangeIdx] = useState(2); // default 7d, matching the mock
  const range = RANGES[rangeIdx];

  useEffect(() => {
    document.title = `${t('nav.metrics')} — Wurk`;
  }, []);

  const { data: stats } = useQuery<StatsData>({
    queryKey: ['stats'],
    queryFn: () => fetch('/wurk/api/stats').then((r) => r.json() as Promise<StatsData>),
    refetchInterval: 5000,
  });

  const { data: history, isPending: historyPending } = useQuery<HistoryResponse>({
    queryKey: ['history', range.bucket, range.window],
    queryFn: () =>
      fetch(`/wurk/api/history/${range.bucket}?window=${range.window}`).then((r) => r.json() as Promise<HistoryResponse>),
    refetchInterval: 30000,
  });

  const { data: metrics, isPending: metricsPending } = useQuery<MetricsResponse>({
    queryKey: ['metrics', range.minutes],
    queryFn: () => fetch(`/wurk/api/metrics?minutes=${range.minutes}`).then((r) => r.json() as Promise<MetricsResponse>),
    refetchInterval: 30000,
  });

  const { data: queueHistory, isPending: queuePending } = useQuery<QueueHistoryResponse>({
    queryKey: ['queue-history', range.bucket, range.window],
    queryFn: async () => {
      const r = await fetch(`/wurk/api/queue-history/${range.bucket}?window=${range.window}`);
      if (!r.ok) throw new Error(`queue-history failed (${r.status})`);
      return r.json() as Promise<QueueHistoryResponse>;
    },
    refetchInterval: 30000,
  });

  // Keep the full history for deltaPct() — slicing first would drop the
  // previous-hour comparison window and force the 100% fallback on the 1h tab.
  const fullSeries = (history?.series ?? []).map((p) => ({ ...p, label: fmtBucket(p.at, range.bucket) }));
  const sliceN = 'slice' in range ? range.slice : undefined;
  const series = sliceN ? fullSeries.slice(-sliceN) : fullSeries;
  const hasThroughput = series.some((p) => p.processed > 0 || p.failed > 0);

  // Queue depth = total jobs enqueued across all queues per bucket, downsampled
  // to a readable number of bars; the busiest bar is highlighted (design spec).
  const queues = queueHistory?.queues ?? [];
  const ats = queues[0]?.points.map((p) => p.at) ?? [];
  const depthRows = sample(
    ats.map((at, i) => ({
      label: fmtBucket(at, range.bucket),
      depth: queues.reduce((s, q) => s + (q.points[i]?.size ?? 0), 0),
    })),
    16,
  );
  const maxDepth = Math.max(0, ...depthRows.map((r) => r.depth));

  // % Total compares each top job against the full returned volume — the
  // jobs.slice(0, 6) trims the displayed rows only; computing the total off
  // the slice would let three jobs at 30/30/30 each report 33%.
  const allJobs = (metrics?.top_jobs ?? [])
    .map((j) => ({ klass: j.klass, count: j.processed + j.failed }))
    .sort((a, b) => b.count - a.count);
  const jobsTotal = allJobs.reduce((s, j) => s + j.count, 0);
  const jobs = allJobs.slice(0, 6);

  return (
    <div className="obs">
      <div className="obs-toolbar">
        <span className="obs-toolbar__label"><i className="fa-regular fa-calendar" aria-hidden="true" /> Time Range:</span>
        <div className="obs-seg" role="tablist" aria-label="Time range">
          {RANGES.map((r, i) => (
            <button
              key={r.key}
              role="tab"
              aria-selected={i === rangeIdx}
              className={i === rangeIdx ? 'is-active' : ''}
              onClick={() => setRangeIdx(i)}
            >
              {r.key}
            </button>
          ))}
        </div>
      </div>

      <div className="obs-metrics">
        <div className="obs-card obs-metric">
          <div className="obs-metric__head">
            <span className="obs-mono">Total Processed</span>
            <i className="fa-solid fa-circle-check obs-metric__icon" aria-hidden="true" />
          </div>
          <span className="obs-metric__value">
            {(stats?.processed ?? 0).toLocaleString()}
            <Delta pct={deltaPct(fullSeries, 'processed')} goodWhenUp />
          </span>
          <span className="obs-metric__sub">across all queues</span>
        </div>
        <div className="obs-card obs-metric">
          <div className="obs-metric__head">
            <span className="obs-mono">Failed Jobs</span>
            <i className="fa-solid fa-triangle-exclamation obs-metric__icon" aria-hidden="true" />
          </div>
          <span className="obs-metric__value">
            {(stats?.failed ?? 0).toLocaleString()}
            <Delta pct={deltaPct(fullSeries, 'failed')} goodWhenUp={false} />
          </span>
          <span className="obs-metric__sub">total failures</span>
        </div>
        <div className="obs-card obs-metric">
          <div className="obs-metric__head">
            <span className="obs-mono">Avg Latency</span>
            <i className="fa-solid fa-stopwatch obs-metric__icon" aria-hidden="true" />
          </div>
          <span className="obs-metric__value">{stats ? formatDuration(stats.latency) : '—'}</span>
          <span className="obs-metric__sub">head-of-line</span>
        </div>
        <div className="obs-card obs-metric">
          <div className="obs-metric__head">
            <span className="obs-mono">Active Workers</span>
            <i className="fa-solid fa-gears obs-metric__icon" aria-hidden="true" />
          </div>
          <span className="obs-metric__value">{(stats?.processes ?? 0).toLocaleString()}</span>
          <span className="obs-metric__sub">{(stats?.processes ?? 0) > 0 ? 'Stable' : 'No workers'}</span>
        </div>
      </div>

      <div className="obs-card obs-panel">
        <div className="obs-panel__head">
          <div>
            <h2 className="obs-panel__title">Throughput &amp; Failures</h2>
            <p className="obs-panel__sub">Jobs processed per bucket over the last {range.key}</p>
          </div>
          <div className="obs-legend">
            <span><i className="dot dot--processed" /> Processed</span>
            <span><i className="dot dot--failed" /> Failed</span>
          </div>
        </div>
        <div className="obs-chartbox">
          {historyPending ? (
            <ChartLoader height={300} />
          ) : hasThroughput ? (
            <ResponsiveContainer width="100%" height={300}>
              <AreaChart data={series} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
                <defs>
                  <linearGradient id="mProcessed" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#fafafa" stopOpacity={0.22} />
                    <stop offset="95%" stopColor="#fafafa" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="rgba(255,255,255,0.06)" />
                <XAxis dataKey="label" tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} axisLine={false} tickLine={false} minTickGap={56} interval="preserveStartEnd" />
                <YAxis tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} axisLine={false} tickLine={false} width={36} allowDecimals={false} />
                <Tooltip contentStyle={tooltipStyle} labelStyle={{ color: '#a1a1aa' }} cursor={{ stroke: 'rgba(255,255,255,0.25)', strokeWidth: 1 }} />
                <Area type="monotone" dataKey="processed" name="Processed" stroke="#fafafa" strokeWidth={2} fill="url(#mProcessed)" dot={false} activeDot={{ r: 4, fill: '#fafafa', stroke: '#09090b', strokeWidth: 2 }} animationDuration={1100} animationEasing="ease-out" />
                <Area type="monotone" dataKey="failed" name="Failed" stroke="#a1a1aa" strokeWidth={1.5} strokeDasharray="5 4" fill="transparent" dot={false} animationDuration={1100} animationBegin={250} animationEasing="ease-out" />
              </AreaChart>
            </ResponsiveContainer>
          ) : (
            <div className="empty-state" style={{ height: 300, display: 'grid', placeItems: 'center' }}>
              No history yet — the chart fills in as jobs run.
            </div>
          )}
        </div>
      </div>

      <div className="obs-grid2">
        <div className="obs-card obs-panel">
          <div className="obs-panel__head">
            <h2 className="obs-panel__title" style={{ fontSize: 18 }}>Queue Depth</h2>
            <span className="obs-mono">{maxDepth > 0 ? `peak ${maxDepth.toLocaleString()}` : ''}</span>
          </div>
          <div className="obs-chartbox">
            {queuePending ? (
              <ChartLoader height={240} />
            ) : depthRows.length > 0 ? (
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={depthRows} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="rgba(255,255,255,0.06)" />
                  <XAxis dataKey="label" tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} axisLine={false} tickLine={false} minTickGap={40} interval="preserveStartEnd" />
                  <YAxis tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} axisLine={false} tickLine={false} width={36} allowDecimals={false} />
                  <Tooltip contentStyle={tooltipStyle} labelStyle={{ color: '#a1a1aa' }} cursor={{ fill: 'rgba(255,255,255,0.04)' }} />
                  <Bar dataKey="depth" name="Depth" radius={[3, 3, 0, 0]} animationDuration={900} animationEasing="ease-out">
                    {depthRows.map((r, i) => (
                      <Cell key={i} fill={r.depth === maxDepth && maxDepth > 0 ? '#fafafa' : '#3f3f46'} />
                    ))}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            ) : (
              <div className="empty-state" style={{ height: 240, display: 'grid', placeItems: 'center' }}>
                No queue history yet.
              </div>
            )}
          </div>
        </div>

        <div className="obs-card obs-table">
          <div className="obs-table__head">
            <h2 className="obs-table__title" style={{ fontSize: 18 }}>Top Job Types (Volume)</h2>
          </div>
          {metricsPending ? (
            <ChartLoader height={240} />
          ) : jobs.length === 0 ? (
            <div className="obs-empty">{t('common.empty')}</div>
          ) : (
            <div className="obs-tablescroll">
              <table>
                <thead>
                  <tr>
                    <th>Job Class</th>
                    <th style={{ textAlign: 'end' }}>Count</th>
                    <th style={{ textAlign: 'end' }}>% Total</th>
                  </tr>
                </thead>
                <tbody>
                  {jobs.map((j, i) => (
                    <tr key={j.klass}>
                      <td style={{ color: 'var(--obs-text)' }} title={j.klass}>
                        <span className="obs-jobdot" style={{ background: JOB_DOTS[i % JOB_DOTS.length] }} />
                        {truncate(j.klass.split('::').pop() ?? j.klass, 36)}
                      </td>
                      <td style={{ textAlign: 'end', fontVariantNumeric: 'tabular-nums' }}>{j.count.toLocaleString()}</td>
                      <td className="obs-pct" style={{ textAlign: 'end' }}>
                        {jobsTotal > 0 ? Math.round((j.count / jobsTotal) * 100) : 0}%
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      <QueueLatencyHistory range={range} />
      <HistoricalSnapshots />
    </div>
  );
}

// Per-queue head-of-line latency over the selected window (Ent Historical tab,
// §5.2) — kept below the mock layout so the feature isn't lost.
function QueueLatencyHistory({ range }: { range: (typeof RANGES)[number] }) {
  const { data } = useQuery<QueueHistoryResponse>({
    queryKey: ['queue-history-lat', range.bucket, range.window],
    queryFn: async () => {
      const r = await fetch(`/wurk/api/queue-history/${range.bucket}?window=${range.window}`);
      if (!r.ok) throw new Error(`queue-history failed (${r.status})`);
      return r.json() as Promise<QueueHistoryResponse>;
    },
    refetchInterval: 30000,
  });

  const queues = data?.queues ?? [];
  // Recharts 3.x interprets dots in `dataKey` as nested-object accessors, so
  // a Sidekiq-compatible queue name like `emails.critical` would silently
  // fail to render. Pivot through synthetic `queue_<i>` keys and pass the
  // real queue name via Recharts' `name` prop (legend + tooltip label).
  const queueKeys = queues.map((q, i) => ({ key: `queue_${i}`, name: q.name }));
  const ats = queues[0]?.points.map((p) => p.at) ?? [];
  const rows = ats.map((at, i) => {
    const row: Record<string, number | string> = { label: fmtBucket(at, range.bucket) };
    queues.forEach((q, qi) => { row[queueKeys[qi].key] = q.points[i]?.latency ?? 0; });
    return row;
  });
  const hasData = queues.some((q) => q.points.some((p) => p.latency > 0));
  if (!hasData) return null;

  return (
    <div className="obs-card obs-panel">
      <div className="obs-panel__head">
        <h2 className="obs-panel__title" style={{ fontSize: 18 }}>Queue Latency (seconds)</h2>
      </div>
      <div className="obs-chartbox">
        <ResponsiveContainer width="100%" height={240}>
          <LineChart data={rows} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="rgba(255,255,255,0.06)" />
            <XAxis dataKey="label" tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} axisLine={false} tickLine={false} minTickGap={48} interval="preserveStartEnd" />
            <YAxis tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} axisLine={false} tickLine={false} width={40} />
            <Tooltip contentStyle={tooltipStyle} labelStyle={{ color: '#a1a1aa' }} />
            <Legend wrapperStyle={{ fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} />
            {queueKeys.map((q, i) => (
              <Line key={q.key} type="monotone" dataKey={q.key} name={q.name} stroke={queueColor(i)} strokeWidth={2} dot={false} />
            ))}
          </LineChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}

interface Snapshot {
  at: number;
  [field: string]: number;
}
const CUMULATIVE_FIELDS = new Set(['processed', 'failures']);

function HistoricalSnapshots() {
  const { data } = useQuery<{ snapshots: Snapshot[] }>({
    queryKey: ['history-snapshots'],
    queryFn: async () => {
      const r = await fetch('/wurk/api/history/snapshots?limit=1000');
      if (!r.ok) throw new Error(`history snapshots request failed (${r.status})`);
      return r.json() as Promise<{ snapshots: Snapshot[] }>;
    },
    refetchInterval: 30000,
  });

  const snapshots = data?.snapshots ?? [];
  const fields = Array.from(
    new Set(
      snapshots.flatMap((s) =>
        Object.keys(s).filter((k) => k !== 'at' && !CUMULATIVE_FIELDS.has(k) && typeof s[k] === 'number')
      )
    )
  );
  const rows = snapshots.map((s) => {
    const d = new Date(s.at * 1000);
    return { ...s, label: `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}` };
  });
  if (snapshots.length === 0 || fields.length === 0) return null;

  return (
    <div className="obs-card obs-panel">
      <div className="obs-panel__head">
        <h2 className="obs-panel__title" style={{ fontSize: 18 }}>Historical Snapshots</h2>
      </div>
      <div className="obs-chartbox">
        <ResponsiveContainer width="100%" height={240}>
          <LineChart data={rows} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="rgba(255,255,255,0.06)" />
            <XAxis dataKey="label" tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} axisLine={false} tickLine={false} minTickGap={48} interval="preserveStartEnd" />
            <YAxis tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} axisLine={false} tickLine={false} width={40} allowDecimals={false} />
            <Tooltip contentStyle={tooltipStyle} labelStyle={{ color: '#a1a1aa' }} />
            <Legend wrapperStyle={{ fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }} />
            {fields.map((f, i) => (
              <Line key={f} type="monotone" dataKey={f} stroke={queueColor(i)} strokeWidth={2} dot={false} />
            ))}
          </LineChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}

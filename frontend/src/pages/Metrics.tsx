import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import {
  BarChart,
  Bar,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { truncate } from '../utils';

// Matches Wurk::Api::Serializers.metric_row — processed (successes), failed,
// and total runtime ms across both. Avg latency is derived client-side; there
// is no per-job percentile histogram, so no p99 here.
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

// Matches Wurk::Api::Serializers.queue_history_series — one entry per queue,
// each with a size/latency gauge sampled into the same time buckets as the
// throughput chart (see Metrics::QueueRollup).
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

// Distinct line colors per queue; the first reuses the accent so a
// single-queue cluster matches the throughput chart's palette.
const QUEUE_COLORS = [
  'var(--accent)',
  '#e0b341',
  '#46b3a8',
  '#d4737e',
  '#8a7fd1',
  '#5fa8d3',
  '#c08457',
  '#7bb274',
] as const;

const queueColor = (i: number) => QUEUE_COLORS[i % QUEUE_COLORS.length];

// Hourly buckets span days, so show a date; sub-hour buckets show the clock.
function bucketLabel(at: number, bucket: string): string {
  const d = new Date(at * 1000);
  const hh = String(d.getHours()).padStart(2, '0');
  return bucket === '1h'
    ? `${d.getMonth() + 1}/${d.getDate()} ${hh}:00`
    : `${hh}:${String(d.getMinutes()).padStart(2, '0')}`;
}

const MINUTE_OPTIONS = [15, 30, 60, 120, 480] as const;

// Each maps to a rollup bucket + its retention window (see Metrics::Rollup).
const HISTORY_RANGES = [
  { label: '24h · 1m', bucket: '1m', window: '24h' },
  { label: '7d · 5m', bucket: '5m', window: '7d' },
  { label: '30d · 1h', bucket: '1h', window: '30d' },
] as const;

const tooltipStyle = {
  background: 'var(--surface)',
  border: '1px solid var(--border)',
  color: 'var(--text)',
  borderRadius: 6,
  fontSize: 12,
};

function HistoryCharts() {
  const [range, setRange] = useState(0);
  const { bucket, window } = HISTORY_RANGES[range];

  const { data, isLoading, isError } = useQuery<HistoryResponse>({
    queryKey: ['history', bucket, window],
    queryFn: () =>
      fetch(`/wurk/api/history/${bucket}?window=${window}`).then(
        (r) => r.json() as Promise<HistoryResponse>
      ),
    refetchInterval: 30000,
  });

  // Hourly buckets span days, so show a date; sub-hour buckets show the clock.
  const fmt = (at: number) => {
    const d = new Date(at * 1000);
    return bucket === '1h'
      ? `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:00`
      : `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  };
  const series = (data?.series ?? []).map((p) => ({ ...p, label: fmt(p.at) }));
  const hasData = series.some((p) => p.processed > 0 || p.failed > 0);

  return (
    <div className="card" style={{ marginBottom: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1rem' }}>
        <div className="section-title">Throughput &amp; Failures</div>
        <select
          className="select"
          style={{ marginInlineStart: 'auto' }}
          value={range}
          onChange={(e) => setRange(Number(e.target.value))}
        >
          {HISTORY_RANGES.map((r, i) => (
            <option key={r.label} value={i}>{r.label}</option>
          ))}
        </select>
      </div>

      {isLoading && <div className="empty-state"><span className="spinner" /></div>}
      {isError && <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>}
      {data && !hasData && <div className="empty-state">No history yet — charts fill in as jobs run.</div>}

      {data && hasData && (
        <ResponsiveContainer width="100%" height={260}>
          <LineChart data={series} margin={{ top: 4, right: 16, left: 0, bottom: 4 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
            <XAxis dataKey="label" tick={{ fill: 'var(--text-muted)', fontSize: 11 }} minTickGap={48} />
            <YAxis tick={{ fill: 'var(--text-muted)', fontSize: 11 }} allowDecimals={false} />
            <Tooltip contentStyle={tooltipStyle} />
            <Line type="monotone" dataKey="processed" stroke="var(--accent)" strokeWidth={2} dot={false} name="Processed" />
            <Line type="monotone" dataKey="failed" stroke="var(--danger)" strokeWidth={2} dot={false} name="Failed" />
          </LineChart>
        </ResponsiveContainer>
      )}
    </div>
  );
}

// Per-queue size + head-of-line latency gauges over the selected window
// (Sidekiq Ent Historical tab, §5.2). One line per queue in each of the two
// charts; the range selector mirrors the throughput chart's buckets.
function QueueGaugeCharts() {
  const [range, setRange] = useState(0);
  const { bucket, window } = HISTORY_RANGES[range];

  const { data, isLoading, isError } = useQuery<QueueHistoryResponse>({
    queryKey: ['queue-history', bucket, window],
    // Throw on a non-OK response so react-query's `isError` fires instead of an
    // error payload (which has no `queues`) falling through to the empty state.
    queryFn: async () => {
      const r = await fetch(`/wurk/api/queue-history/${bucket}?window=${window}`);
      if (!r.ok) {
        const err = (await r.json().catch(() => null)) as { error?: string } | null;
        throw new Error(err?.error ?? `queue-history request failed (${r.status})`);
      }
      return r.json() as Promise<QueueHistoryResponse>;
    },
    refetchInterval: 30000,
  });

  const queues = data?.queues ?? [];
  // Every queue shares the same gap-filled bucket timestamps, so pivot to wide
  // rows keyed by timestamp with one column per queue for Recharts.
  const ats = queues[0]?.points.map((p) => p.at) ?? [];
  const rowsFor = (field: 'size' | 'latency') =>
    ats.map((at, i) => {
      const row: Record<string, number | string> = { label: bucketLabel(at, bucket) };
      queues.forEach((q) => {
        row[q.name] = q.points[i]?.[field] ?? 0;
      });
      return row;
    });
  const hasData = queues.some((q) => q.points.some((p) => p.size > 0 || p.latency > 0));

  const chart = (rows: ReturnType<typeof rowsFor>, decimals: boolean) => (
    <ResponsiveContainer width="100%" height={240}>
      <LineChart data={rows} margin={{ top: 4, right: 16, left: 0, bottom: 4 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
        <XAxis dataKey="label" tick={{ fill: 'var(--text-muted)', fontSize: 11 }} minTickGap={48} />
        <YAxis tick={{ fill: 'var(--text-muted)', fontSize: 11 }} allowDecimals={decimals} />
        <Tooltip contentStyle={tooltipStyle} />
        <Legend wrapperStyle={{ fontSize: 12 }} />
        {queues.map((q, i) => (
          <Line
            key={q.name}
            type="monotone"
            dataKey={q.name}
            stroke={queueColor(i)}
            strokeWidth={2}
            dot={false}
          />
        ))}
      </LineChart>
    </ResponsiveContainer>
  );

  return (
    <div className="card" style={{ marginBottom: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1rem' }}>
        <div className="section-title">Queue Size &amp; Latency</div>
        <select
          className="select"
          style={{ marginInlineStart: 'auto' }}
          value={range}
          onChange={(e) => setRange(Number(e.target.value))}
          aria-label="Queue history range"
        >
          {HISTORY_RANGES.map((r, i) => (
            <option key={r.label} value={i}>{r.label}</option>
          ))}
        </select>
      </div>

      {isLoading && <div className="empty-state"><span className="spinner" /></div>}
      {isError && <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>}
      {data && !hasData && <div className="empty-state">No queue history yet — charts fill in as queues build up.</div>}

      {data && hasData && (
        <>
          <div className="section-subtitle" style={{ fontSize: 12, color: 'var(--text-muted)', marginBottom: 4 }}>
            Depth (jobs)
          </div>
          {chart(rowsFor('size'), false)}
          <div className="section-subtitle" style={{ fontSize: 12, color: 'var(--text-muted)', margin: '1rem 0 4px' }}>
            Latency (seconds)
          </div>
          {chart(rowsFor('latency'), true)}
        </>
      )}
    </div>
  );
}

export default function Metrics() {
  const [minutes, setMinutes] = useState(60);

  useEffect(() => {
    document.title = `${t('nav.metrics')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<MetricsResponse>({
    queryKey: ['metrics', minutes],
    queryFn: () =>
      fetch(`/wurk/api/metrics?minutes=${minutes}`).then(
        (r) => r.json() as Promise<MetricsResponse>
      ),
    refetchInterval: 30000,
  });

  const chartData = (data?.top_jobs ?? []).slice(0, 10).map((j) => ({
    name: j.klass.split('::').pop() ?? j.klass,
    fullName: j.klass,
    total: j.processed + j.failed,
    failed: j.failed,
  }));

  return (
    <div>
      <PageHeader icon="fa-chart-line" title={t('nav.metrics')} summary={t('summaries.metrics')}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
          <span style={{ fontSize: 13, color: 'var(--text-muted)' }}>Last</span>
          <select
            className="select"
            value={minutes}
            onChange={(e) => setMinutes(Number(e.target.value))}
          >
            {MINUTE_OPTIONS.map((m) => (
              <option key={m} value={m}>
                {m >= 60 ? `${m / 60}h` : `${m}m`}
              </option>
            ))}
          </select>
        </div>
      </PageHeader>

      <HistoryCharts />

      <QueueGaugeCharts />

      {isLoading && (
        <div className="empty-state"><span className="spinner" /></div>
      )}

      {isError && (
        <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      )}

      {data && data.top_jobs.length === 0 && (
        <div className="empty-state">{t('common.empty')}</div>
      )}

      {data && data.top_jobs.length > 0 && (
        <>
          <div className="card" style={{ marginBottom: '1.5rem' }}>
            <div className="section-title" style={{ marginBottom: '1rem' }}>Top Jobs by Count</div>
            <ResponsiveContainer width="100%" height={280}>
              <BarChart data={chartData} margin={{ top: 4, right: 16, left: 0, bottom: 40 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis
                  dataKey="name"
                  tick={{ fill: 'var(--text-muted)', fontSize: 11 }}
                  angle={-35}
                  textAnchor="end"
                  interval={0}
                />
                <YAxis tick={{ fill: 'var(--text-muted)', fontSize: 11 }} />
                <Tooltip
                  contentStyle={{
                    background: 'var(--surface)',
                    border: '1px solid var(--border)',
                    color: 'var(--text)',
                    borderRadius: 6,
                    fontSize: 12,
                  }}
                  labelFormatter={(_: unknown, payload: readonly unknown[]) => {
                    const item = payload?.[0] as { payload?: { fullName?: string } } | undefined;
                    return item?.payload?.fullName ?? '';
                  }}
                />
                <Bar dataKey="total" fill="var(--accent)" radius={[3, 3, 0, 0]} name="Total" />
                <Bar dataKey="failed" fill="var(--danger)" radius={[3, 3, 0, 0]} name="Failed" />
              </BarChart>
            </ResponsiveContainer>
          </div>

          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>{t('table.class')}</th>
                  <th>{t('table.total')}</th>
                  <th>Failed</th>
                  <th>Error Rate</th>
                  <th>Avg {t('common.ms')}</th>
                </tr>
              </thead>
              <tbody>
                {data.top_jobs.map((job) => {
                  const total = job.processed + job.failed;
                  const errorRate = total > 0 ? (job.failed / total) * 100 : 0;
                  const avgMs = total > 0 ? job.runtime_ms / total : 0;
                  return (
                    <tr key={job.klass}>
                      <td title={job.klass} style={{ fontWeight: 500 }}>
                        {truncate(job.klass, 50)}
                      </td>
                      <td style={{ fontVariantNumeric: 'tabular-nums' }}>{total.toLocaleString()}</td>
                      <td style={{ color: job.failed > 0 ? 'var(--danger)' : undefined, fontVariantNumeric: 'tabular-nums' }}>
                        {job.failed.toLocaleString()}
                      </td>
                      <td style={{ color: errorRate > 5 ? 'var(--danger)' : errorRate > 1 ? 'var(--warning)' : 'var(--success)' }}>
                        {errorRate.toFixed(1)}%
                      </td>
                      <td style={{ fontVariantNumeric: 'tabular-nums' }}>{avgMs.toFixed(1)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}

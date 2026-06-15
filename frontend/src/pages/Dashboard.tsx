import { useQuery } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  AreaChart,
  Area,
  XAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts';
import { AnimatedNumber } from '../components/AnimatedNumber';
import { t } from '../i18n';
import type { StatsSnapshot } from '../hooks/useSSE';
import { formatDuration } from '../utils';

interface StatsData {
  processed: number;
  failed: number;
  expired: number;
  busy: number;
  enqueued: number;
  retries: number;
  scheduled: number;
  dead: number;
  processes: number;
  latency: number;
  queues: Array<{ name: string; size: number; latency: number; paused: boolean }>;
}

interface HistoryPoint {
  at: number;
  processed: number;
  failed: number;
}

interface HistoryResponse {
  bucket: string;
  window: number;
  series: HistoryPoint[];
}

interface DashboardProps {
  sse: { stats: StatsSnapshot | null; connected: boolean };
}

// Throughput change over the trailing hour vs the hour before it, derived from
// the same buckets the chart plots — no extra request, no fabricated number.
function hourlyDeltaPct(series: HistoryPoint[], key: 'processed' | 'failed'): number | null {
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

// Range buttons → rollup bucket + retention window, matching the Metrics page.
// "1h" reuses the 1m/24h rollup and slices client-side; the rest map 1:1 to a
// stored window. `desc` feeds the panel subtitle.
const RANGES = [
  { key: '1h', bucket: '1m', window: '24h', slice: 60, desc: 'the last hour' },
  { key: '24h', bucket: '1m', window: '24h', desc: 'the last 24 hours' },
  { key: '7d', bucket: '5m', window: '7d', desc: 'the last 7 days' },
  { key: '30d', bucket: '1h', window: '30d', desc: 'the last 30 days' },
] as const;

const fmtBucket = (at: number, bucket: string) => {
  const d = new Date(at * 1000);
  const hh = String(d.getHours()).padStart(2, '0');
  return bucket === '1h'
    ? `${d.getMonth() + 1}/${d.getDate()} ${hh}:00`
    : `${hh}:${String(d.getMinutes()).padStart(2, '0')}`;
};

function DeltaSub({ pct, goodWhenUp }: { pct: number | null; goodWhenUp: boolean }) {
  if (pct === null) return <span className="obs-metric__sub">vs last hour</span>;
  const up = pct >= 0;
  const good = up === goodWhenUp;
  return (
    <span className="obs-metric__sub">
      <span className={good ? 'up' : 'down'}>
        {up ? '▲' : '▼'} {up ? '+' : ''}{pct}%
      </span>{' '}
      vs last hour
    </span>
  );
}

export default function Dashboard({ sse }: DashboardProps) {
  const [rangeIdx, setRangeIdx] = useState(0); // default 1h
  const range = RANGES[rangeIdx];

  useEffect(() => {
    document.title = `${t('nav.dashboard')} — Wurk`;
  }, []);

  const { data: fetched, isLoading, isError } = useQuery<StatsData>({
    queryKey: ['stats'],
    queryFn: () => fetch('/wurk/api/stats').then((r) => r.json() as Promise<StatsData>),
    enabled: !sse.connected,
    refetchInterval: sse.connected ? false : 5000,
  });

  // Throughput for the Performance Insight chart over the selected range (same
  // source as Metrics).
  const { data: history, isPending: historyPending } = useQuery<HistoryResponse>({
    queryKey: ['history', range.bucket, range.window],
    queryFn: () =>
      fetch(`/wurk/api/history/${range.bucket}?window=${range.window}`).then((r) => r.json() as Promise<HistoryResponse>),
    refetchInterval: 30000,
  });

  const stats: StatsData | null = sse.stats ?? fetched ?? null;
  let series = (history?.series ?? []).map((p) => ({ ...p, label: fmtBucket(p.at, range.bucket) }));
  const sliceN = 'slice' in range ? range.slice : undefined;
  if (sliceN) series = series.slice(-sliceN);
  const hasHistory = series.some((p) => p.processed > 0 || p.failed > 0);

  if (isLoading && !stats) {
    return (
      <div className="empty-state">
        <span className="spinner" />
        <p style={{ marginTop: '1rem' }}>{t('common.loading')}</p>
      </div>
    );
  }
  if (isError && !stats) {
    return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;
  }
  if (!stats) {
    return <div className="empty-state">{t('common.empty')}</div>;
  }

  const metrics = [
    {
      key: 'processed',
      label: t('dashboard.processed'),
      value: stats.processed,
      icon: 'fa-circle-check',
      to: '/metrics',
      sub: <DeltaSub pct={hourlyDeltaPct(series, 'processed')} goodWhenUp />,
    },
    {
      key: 'failed',
      label: t('dashboard.failed'),
      value: stats.failed,
      icon: 'fa-triangle-exclamation',
      to: '/retries',
      sub: <DeltaSub pct={hourlyDeltaPct(series, 'failed')} goodWhenUp={false} />,
    },
    {
      key: 'expired',
      label: t('dashboard.expired'),
      value: stats.expired,
      icon: 'fa-ban',
      to: '/dead',
      sub: <span className="obs-metric__sub">{stats.expired === 0 ? 'Stable threshold' : 'Above threshold'}</span>,
    },
    {
      key: 'busy',
      label: t('dashboard.busy'),
      value: stats.busy,
      icon: 'fa-spinner',
      to: '/busy',
      sub: <span className="obs-metric__sub">{stats.busy === 0 ? 'System idle' : 'Processing'}</span>,
    },
  ];

  const secondary = [
    { key: 'enqueued', label: t('dashboard.enqueued'), value: stats.enqueued, to: '/queues' },
    { key: 'retries', label: t('dashboard.retries'), value: stats.retries, to: '/retries' },
    { key: 'scheduled', label: t('dashboard.scheduled'), value: stats.scheduled, to: '/scheduled' },
    { key: 'dead', label: t('dashboard.dead'), value: stats.dead, to: '/dead' },
  ];

  return (
    <div className="obs">
      <div className="obs-metrics">
        {metrics.map((m) => (
          <Link key={m.key} className="obs-card obs-metric obs-card--link" to={m.to}>
            <div className="obs-metric__head">
              <span className="obs-mono">{m.label}</span>
              <i className={`fa-solid ${m.icon} obs-metric__icon`} aria-hidden="true" />
            </div>
            <span className="obs-metric__value">
              <AnimatedNumber value={m.value} />
            </span>
            {m.sub}
            <i className="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
          </Link>
        ))}
      </div>

      <div className="obs-card obs-panel">
        <div className="obs-panel__head">
          <div>
            <h2 className="obs-panel__title">Performance Insight</h2>
            <p className="obs-panel__sub">Jobs Processed vs Failed over {range.desc}</p>
          </div>
          <div className="obs-panel__controls">
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
            <div className="obs-legend">
              <span><i className="dot dot--processed" /> {t('dashboard.processed')}</span>
              <span><i className="dot dot--failed" /> {t('dashboard.failed')}</span>
            </div>
          </div>
        </div>
        <div className="obs-chartbox">
          {historyPending ? (
            <div style={{ height: 320, display: 'grid', placeItems: 'center' }}>
              <span className="spinner" role="status" aria-label={t('common.loading')} />
            </div>
          ) : hasHistory ? (
            <ResponsiveContainer width="100%" height={320}>
              <AreaChart data={series} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
                <defs>
                  <linearGradient id="obsProcessed" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#fafafa" stopOpacity={0.22} />
                    <stop offset="95%" stopColor="#fafafa" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="rgba(255,255,255,0.06)" />
                <XAxis
                  dataKey="label"
                  tick={{ fill: '#71717a', fontSize: 11, fontFamily: 'JetBrains Mono, monospace' }}
                  axisLine={false}
                  tickLine={false}
                  minTickGap={64}
                  interval="preserveStartEnd"
                />
                <Tooltip
                  contentStyle={{
                    background: '#161618',
                    border: '1px solid #272729',
                    borderRadius: 6,
                    fontSize: 12,
                    fontFamily: 'JetBrains Mono, monospace',
                  }}
                  labelStyle={{ color: '#a1a1aa' }}
                  cursor={{ stroke: 'rgba(255,255,255,0.25)', strokeWidth: 1 }}
                />
                <Area
                  type="monotone"
                  dataKey="processed"
                  name={t('dashboard.processed')}
                  stroke="#fafafa"
                  strokeWidth={2}
                  fill="url(#obsProcessed)"
                  dot={false}
                  activeDot={{ r: 4, fill: '#fafafa', stroke: '#09090b', strokeWidth: 2 }}
                  animationDuration={1100}
                  animationEasing="ease-out"
                />
                <Area
                  type="monotone"
                  dataKey="failed"
                  name={t('dashboard.failed')}
                  stroke="#a1a1aa"
                  strokeWidth={1.5}
                  strokeDasharray="5 4"
                  fill="transparent"
                  dot={false}
                  activeDot={{ r: 3, fill: '#a1a1aa', stroke: '#09090b', strokeWidth: 2 }}
                  animationDuration={1100}
                  animationBegin={250}
                  animationEasing="ease-out"
                />
              </AreaChart>
            </ResponsiveContainer>
          ) : (
            <div className="empty-state" style={{ height: 320, display: 'grid', placeItems: 'center' }}>
              No history yet — the chart fills in as jobs run.
            </div>
          )}
        </div>
      </div>

      <div className="obs-stats">
        {secondary.map((s) => (
          <Link key={s.key} className="obs-card obs-stat obs-card--link" to={s.to}>
            <span className="obs-mono">{s.label}</span>
            <span className="obs-stat__value">
              <AnimatedNumber value={s.value} />
            </span>
            <i className="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
          </Link>
        ))}
      </div>

      <div className="obs-card obs-table">
        <div className="obs-table__head">
          <h2 className="obs-table__title">{t('table.queues')}</h2>
          <Link className="obs-table__link" to="/queues">
            View All <i className="fa-solid fa-arrow-right" aria-hidden="true" />
          </Link>
        </div>
        {stats.queues.length === 0 ? (
          <div className="empty-state">{t('common.empty')}</div>
        ) : (
          <div className="obs-tablescroll">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>{t('table.size')}</th>
                <th>{t('table.latency')}</th>
                <th>{t('table.status')}</th>
              </tr>
            </thead>
            <tbody>
              {stats.queues.map((q) => (
                <tr key={q.name}>
                  <td style={{ fontWeight: 500, color: 'var(--obs-text)' }}>{q.name}</td>
                  <td><AnimatedNumber value={q.size} /></td>
                  <td title={`${q.latency.toFixed(3)}s`}>{formatDuration(q.latency)}</td>
                  <td>
                    {q.paused ? (
                      <span className="obs-chip obs-chip--paused">{t('dashboard.paused')}</span>
                    ) : (
                      <span className="obs-chip obs-chip--active">Active</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
        )}
      </div>

      <div className="obs-card obs-cta">
        <span className="obs-cta__icon"><i className="fa-solid fa-bolt" aria-hidden="true" /></span>
        <h2 className="obs-cta__title">{t('dashboard.strapline')}</h2>
        <p className="obs-cta__text">{t('dashboard.tagline')}</p>
        <div className="obs-cta__actions">
          <a className="obs-btn obs-btn--primary" href="https://developerz-ai.github.io/wurk/" target="_blank" rel="noreferrer">
            <i className="fa-solid fa-download" aria-hidden="true" /> {t('dashboard.install')}
          </a>
          <a className="obs-btn obs-btn--ghost" href="https://github.com/developerz-ai/wurk/wiki" target="_blank" rel="noreferrer">
            <i className="fa-solid fa-book" aria-hidden="true" /> {t('dashboard.docs')}
          </a>
        </div>
      </div>
    </div>
  );
}

import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { StatCard } from '../components/StatCard';
import { AnimatedNumber } from '../components/AnimatedNumber';
import { t } from '../i18n';
import type { StatsSnapshot } from '../hooks/useSSE';
import { relativeTime } from '../utils';

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

interface DashboardProps {
  sse: { stats: StatsSnapshot | null; connected: boolean };
}

export default function Dashboard({ sse }: DashboardProps) {
  useEffect(() => {
    document.title = `${t('nav.dashboard')} — Wurk`;
  }, []);

  const { data: fetched, isLoading, isError } = useQuery<StatsData>({
    queryKey: ['stats'],
    queryFn: () => fetch('/wurk/api/stats').then((r) => r.json() as Promise<StatsData>),
    enabled: !sse.connected,
    refetchInterval: sse.connected ? false : 5000,
  });

  const stats: StatsData | null = sse.stats ?? fetched ?? null;

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

  const cards = [
    { key: 'processed', label: t('dashboard.processed'), value: stats.processed, color: 'var(--success)' },
    { key: 'failed', label: t('dashboard.failed'), value: stats.failed, color: 'var(--danger)' },
    { key: 'expired', label: t('dashboard.expired'), value: stats.expired, color: 'var(--text-muted)' },
    { key: 'busy', label: t('dashboard.busy'), value: stats.busy, color: 'var(--warning)' },
    { key: 'enqueued', label: t('dashboard.enqueued'), value: stats.enqueued },
    { key: 'retries', label: t('dashboard.retries'), value: stats.retries, color: 'var(--warning)' },
    { key: 'scheduled', label: t('dashboard.scheduled'), value: stats.scheduled },
    { key: 'dead', label: t('dashboard.dead'), value: stats.dead, color: 'var(--danger)' },
    { key: 'processes', label: t('dashboard.processes'), value: stats.processes },
    { key: 'latency', label: t('dashboard.latency'), value: `${stats.latency.toFixed(2)}s` },
  ];

  return (
    <div>
      <div className="dash-hero">
        <div className="dash-hero__body">
          <h1 className="dash-hero__title">Wurk ⚡</h1>
          <p className="dash-hero__strapline">{t('dashboard.strapline')}</p>
          <p className="dash-hero__tagline">{t('dashboard.tagline')}</p>
          <div className="dash-hero__actions">
            <a className="btn btn-accent" href="https://developerz-ai.github.io/wurk/" target="_blank" rel="noreferrer">
              <i className="fa-solid fa-download" /> {t('dashboard.install')}
            </a>
            <a className="btn" href="https://github.com/developerz-ai/wurk/wiki" target="_blank" rel="noreferrer">
              <i className="fa-solid fa-book" /> {t('dashboard.docs')}
            </a>
          </div>
        </div>
        <div className="dash-hero__status">
          {sse.connected && (
            <span className="dash-hero__live">
              <span className="live-dot" />
              {t('dashboard.live')}
            </span>
          )}
          {sse.stats?.at && (
            <span style={{ fontSize: 12, color: 'var(--text-muted)' }}>{relativeTime(sse.stats.at)}</span>
          )}
        </div>
      </div>

      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(160px, 1fr))',
          gap: '0.75rem',
          marginBottom: '2rem',
        }}
      >
        {cards.map((c) => (
          <StatCard key={c.key} label={c.label} value={c.value} color={c.color} />
        ))}
      </div>

      <h2 className="section-title" style={{ marginBottom: '0.75rem' }}>{t('table.queues')}</h2>
      {stats.queues.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <div className="table-wrapper">
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
                  <td style={{ fontWeight: 500 }}>{q.name}</td>
                  <td><AnimatedNumber value={q.size} /></td>
                  <td>{q.latency.toFixed(3)}s</td>
                  <td>
                    {q.paused ? (
                      <span className="badge badge-warning">{t('dashboard.paused')}</span>
                    ) : (
                      <span className="badge badge-success">Active</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

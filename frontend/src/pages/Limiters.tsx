import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { t } from '../i18n';

interface Limiter {
  name: string;
  current: number;
  limit: number;
  window_seconds: number;
}

export default function Limiters() {
  useEffect(() => {
    document.title = `${t('nav.limiters')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<Limiter[]>({
    queryKey: ['limiters'],
    queryFn: () => fetch('/wurk/api/limiters').then((r) => r.json() as Promise<Limiter[]>),
    refetchInterval: 5000,
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <div className="section-header">
        <h1 className="page-title" style={{ margin: 0 }}>{t('nav.limiters')}</h1>
        <span className="badge badge-muted" style={{ marginLeft: 'auto' }}>{data.length}</span>
      </div>

      {data.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <div className="table-wrapper">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Current</th>
                <th>Limit</th>
                <th>Window</th>
                <th>Usage</th>
              </tr>
            </thead>
            <tbody>
              {data.map((limiter) => {
                const pct = limiter.limit > 0 ? (limiter.current / limiter.limit) * 100 : 0;
                const color =
                  pct > 90 ? 'var(--danger)' : pct > 70 ? 'var(--warning)' : 'var(--success)';
                return (
                  <tr key={limiter.name}>
                    <td style={{ fontWeight: 500 }}>{limiter.name}</td>
                    <td style={{ fontVariantNumeric: 'tabular-nums' }}>{limiter.current.toLocaleString()}</td>
                    <td style={{ fontVariantNumeric: 'tabular-nums' }}>{limiter.limit.toLocaleString()}</td>
                    <td style={{ color: 'var(--text-muted)' }}>{limiter.window_seconds}s</td>
                    <td style={{ width: 200 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                        <div className="progress-bar-track" style={{ flex: 1 }}>
                          <div
                            className="progress-bar-fill"
                            style={{ width: `${pct}%`, background: color }}
                          />
                        </div>
                        <span style={{ fontSize: 12, color: 'var(--text-muted)', minWidth: 36 }}>
                          {Math.round(pct)}%
                        </span>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

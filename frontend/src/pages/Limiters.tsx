import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { useMeta } from '../hooks/useMeta';

// Uniform live status every limiter type reports (Wurk::Limiter#status).
// `concurrent` additionally merges its metric counters (held/immediate/…),
// which we surface in the row title; `limit: null` means unlimited.
interface LimiterStatus {
  used: number;
  limit: number | null;
  reset_at: number | null;
  'available?': boolean;
  [metric: string]: number | boolean | null;
}

interface Limiter {
  name: string;
  type: string;
  fingerprint: string;
  options: Record<string, unknown>;
  status: LimiterStatus | null;
}

interface LimitersResponse {
  total: number;
  page: number;
  count: number;
  limiters: Limiter[];
}

const PAGE_SIZE = 25;

export default function Limiters() {
  const qc = useQueryClient();
  const { data: meta } = useMeta();
  const readOnly = meta?.read_only ?? false;
  const [page, setPage] = useState(1);

  useEffect(() => {
    document.title = `${t('nav.limiters')} — Wurk`;
  }, []);

  // UI is 1-indexed for humans; the API is 0-indexed, so send page - 1.
  const { data, isLoading, isError } = useQuery<LimitersResponse>({
    queryKey: ['limiters', page],
    queryFn: () =>
      fetch(`/wurk/api/limiters?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<LimitersResponse>
      ),
    refetchInterval: 5000,
  });

  // Drops the limiter's stats/state keys (counters → 0); skips CSRF, see
  // ApiController#skip_forgery_protection.
  const reset = useMutation({
    mutationFn: (name: string) =>
      fetch(`/wurk/api/limiters/${encodeURIComponent(name)}/reset`, { method: 'POST' }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['limiters'] }),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <PageHeader icon="fa-gauge" title={t('nav.limiters')} summary={t('summaries.limiters')}>
        <span className="badge badge-muted">{data.total.toLocaleString()}</span>
      </PageHeader>

      {data.limiters.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Type</th>
                  <th>Used</th>
                  <th>Limit</th>
                  <th>Usage</th>
                  <th>Status</th>
                  {!readOnly && <th />}
                </tr>
              </thead>
              <tbody>
                {data.limiters.map((limiter) => {
                  const s = limiter.status;
                  const used = s?.used ?? 0;
                  const limit = s?.limit ?? null;
                  const pct = limit && limit > 0 ? Math.min((used / limit) * 100, 100) : 0;
                  const color = pct > 90 ? 'var(--danger)' : pct > 70 ? 'var(--warning)' : 'var(--success)';
                  const available = s?.['available?'] ?? true;
                  // Concurrent rows carry extra metric counters — show them on hover.
                  const metricTitle = s
                    ? Object.entries(s)
                        .filter(([k]) => !['used', 'limit', 'reset_at', 'available?'].includes(k))
                        .map(([k, v]) => `${k}=${v}`)
                        .join('  ')
                    : '';
                  return (
                    <tr key={limiter.name}>
                      <td style={{ fontWeight: 500 }} title={limiter.name}>{limiter.name}</td>
                      <td><span className="badge badge-accent">{limiter.type}</span></td>
                      <td style={{ fontVariantNumeric: 'tabular-nums' }} title={metricTitle}>
                        {used.toLocaleString()}
                      </td>
                      <td style={{ fontVariantNumeric: 'tabular-nums' }}>
                        {limit == null ? '∞' : limit.toLocaleString()}
                      </td>
                      <td style={{ width: 160 }}>
                        {limit == null ? (
                          <span style={{ color: 'var(--text-muted)' }}>—</span>
                        ) : (
                          <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                            <div className="progress-bar-track" style={{ flex: 1 }}>
                              <div className="progress-bar-fill" style={{ width: `${pct}%`, background: color }} />
                            </div>
                            <span style={{ fontSize: 12, color: 'var(--text-muted)', minWidth: 36 }}>
                              {Math.round(pct)}%
                            </span>
                          </div>
                        )}
                      </td>
                      <td>
                        {available ? (
                          <span className="badge badge-success">available</span>
                        ) : (
                          <span className="badge badge-danger">exhausted</span>
                        )}
                      </td>
                      {!readOnly && (
                        <td>
                          <button
                            className="btn btn-sm"
                            disabled={reset.isPending}
                            onClick={() => reset.mutate(limiter.name)}
                          >
                            Reset
                          </button>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <Pagination page={page} total={data.total} count={PAGE_SIZE} onChange={setPage} />
        </>
      )}
    </div>
  );
}

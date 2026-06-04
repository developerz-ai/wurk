import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { Pagination } from '../components/Pagination';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate } from '../utils';

interface Batch {
  bid: string;
  description: string | null;
  total: number;
  pending: number;
  failures: number;
  complete: boolean;
  created_at: number | null;
  complete_at: number | null;
}

interface BatchesResponse {
  total: number;
  page: number;
  count: number;
  batches: Batch[];
}

const PAGE_SIZE = 25;

export default function Batches() {
  const [page, setPage] = useState(1);

  useEffect(() => {
    document.title = `${t('nav.batches')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<BatchesResponse>({
    queryKey: ['batches', page],
    queryFn: () =>
      fetch(`/wurk/api/batches?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<BatchesResponse>
      ),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <PageHeader icon="fa-table-cells-large" title={t('nav.batches')} summary={t('summaries.batches')}>
        <span className="badge badge-accent">{data.total.toLocaleString()}</span>
      </PageHeader>

      {data.batches.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>BID</th>
                  <th>Description</th>
                  <th>{t('table.total')}</th>
                  <th>{t('table.pending')}</th>
                  <th>Failures</th>
                  <th>Progress</th>
                  <th>Created</th>
                </tr>
              </thead>
              <tbody>
                {data.batches.map((batch) => {
                  const done = batch.total - batch.pending;
                  const pct = batch.total > 0 ? (done / batch.total) * 100 : 0;
                  return (
                    <tr key={batch.bid}>
                      <td style={{ fontFamily: 'monospace', fontSize: 12 }}>
                        <Link to={`/batches/${batch.bid}`} title={batch.bid}>
                          {truncate(batch.bid, 14)}
                        </Link>
                      </td>
                      <td title={batch.description ?? ''}>{truncate(batch.description ?? '—', 40)}</td>
                      <td>{batch.total.toLocaleString()}</td>
                      <td style={{ color: batch.pending > 0 ? 'var(--warning)' : 'var(--success)' }}>
                        {batch.pending.toLocaleString()}
                      </td>
                      <td style={{ color: batch.failures > 0 ? 'var(--danger)' : undefined }}>
                        {batch.failures.toLocaleString()}
                      </td>
                      <td style={{ width: 100 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                          <div className="progress-bar-track" style={{ flex: 1 }}>
                            <div
                              className="progress-bar-fill"
                              style={{
                                width: `${pct}%`,
                                background: batch.failures > 0 ? 'var(--danger)' : 'var(--success)',
                              }}
                            />
                          </div>
                          <span style={{ fontSize: 11, color: 'var(--text-muted)', minWidth: 32 }}>
                            {Math.round(pct)}%
                          </span>
                        </div>
                      </td>
                      <td>{batch.created_at ? relativeTime(batch.created_at) : '—'}</td>
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

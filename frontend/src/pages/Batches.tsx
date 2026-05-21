import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { t } from '../i18n';
import { relativeTime, truncate } from '../utils';

interface Batch {
  bid: string;
  description: string;
  total: number;
  pending: number;
  failed: number;
  created_at: number;
  expires_at: number;
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
      fetch(`/wurk/api/batches?page=${page}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<BatchesResponse>
      ),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <div className="section-header">
        <h1 className="page-title" style={{ margin: 0 }}>{t('nav.batches')}</h1>
        <span className="badge badge-accent" style={{ marginLeft: 'auto' }}>{data.total.toLocaleString()}</span>
      </div>

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
                  <th>Failed</th>
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
                      <td
                        title={batch.bid}
                        style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text-muted)' }}
                      >
                        {truncate(batch.bid, 14)}
                      </td>
                      <td title={batch.description}>{truncate(batch.description, 40)}</td>
                      <td>{batch.total.toLocaleString()}</td>
                      <td style={{ color: batch.pending > 0 ? 'var(--warning)' : 'var(--success)' }}>
                        {batch.pending.toLocaleString()}
                      </td>
                      <td style={{ color: batch.failed > 0 ? 'var(--danger)' : undefined }}>
                        {batch.failed.toLocaleString()}
                      </td>
                      <td style={{ width: 100 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                          <div className="progress-bar-track" style={{ flex: 1 }}>
                            <div
                              className="progress-bar-fill"
                              style={{
                                width: `${pct}%`,
                                background: batch.failed > 0 ? 'var(--danger)' : 'var(--success)',
                              }}
                            />
                          </div>
                          <span style={{ fontSize: 11, color: 'var(--text-muted)', minWidth: 32 }}>
                            {Math.round(pct)}%
                          </span>
                        </div>
                      </td>
                      <td>{relativeTime(batch.created_at)}</td>
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

import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { t } from '../i18n';
import { relativeTime, truncate, formatArgs } from '../utils';

interface RetryEntry {
  jid: string;
  class: string;
  args: unknown;
  error_class: string;
  error_message: string;
  failed_at: number;
  retry_at: number;
  retried_at: number | null;
  retry_count: number;
  score: number;
}

interface RetriesResponse {
  total: number;
  page: number;
  count: number;
  entries: RetryEntry[];
}

const PAGE_SIZE = 25;

export default function Retries() {
  const [page, setPage] = useState(1);

  useEffect(() => {
    document.title = `${t('nav.retries')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<RetriesResponse>({
    queryKey: ['retries', page],
    queryFn: () =>
      fetch(`/wurk/api/retries?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<RetriesResponse>
      ),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <div className="section-header">
        <h1 className="page-title" style={{ margin: 0 }}>{t('nav.retries')}</h1>
        <span className="badge badge-warning" style={{ marginLeft: 'auto' }}>{data.total.toLocaleString()}</span>
      </div>

      {data.entries.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>{t('table.class')}</th>
                  <th>{t('table.args')}</th>
                  <th>{t('table.error')}</th>
                  <th>Message</th>
                  <th>Count</th>
                  <th>{t('table.retry_at')}</th>
                </tr>
              </thead>
              <tbody>
                {data.entries.map((entry) => {
                  const argsStr = formatArgs(entry.args);
                  return (
                    <tr key={entry.jid}>
                      <td style={{ fontWeight: 500 }}>{entry.class}</td>
                      <td title={argsStr}>{truncate(argsStr, 40)}</td>
                      <td title={entry.error_class} style={{ color: 'var(--danger)' }}>
                        {truncate(entry.error_class, 30)}
                      </td>
                      <td title={entry.error_message}>{truncate(entry.error_message, 50)}</td>
                      <td style={{ color: 'var(--warning)' }}>{entry.retry_count}</td>
                      <td title={new Date(entry.retry_at * 1000).toISOString()}>
                        {relativeTime(entry.retry_at)}
                      </td>
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

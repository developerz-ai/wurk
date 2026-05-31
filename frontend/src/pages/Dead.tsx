import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { t } from '../i18n';
import { relativeTime, truncate, formatArgs } from '../utils';

interface DeadEntry {
  jid: string;
  class: string;
  args: unknown;
  error_class: string;
  error_message: string;
  failed_at: number;
  score: number;
}

interface DeadResponse {
  total: number;
  page: number;
  count: number;
  entries: DeadEntry[];
}

const PAGE_SIZE = 25;

export default function Dead() {
  const [page, setPage] = useState(1);

  useEffect(() => {
    document.title = `${t('nav.dead')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<DeadResponse>({
    queryKey: ['dead', page],
    queryFn: () =>
      fetch(`/wurk/api/dead?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<DeadResponse>
      ),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <div className="section-header">
        <h1 className="page-title" style={{ margin: 0 }}>{t('nav.dead')}</h1>
        <span className="badge badge-danger" style={{ marginLeft: 'auto' }}>{data.total.toLocaleString()}</span>
      </div>

      {data.entries.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>{t('table.jid')}</th>
                  <th>{t('table.class')}</th>
                  <th>{t('table.args')}</th>
                  <th>{t('table.error')}</th>
                  <th>Message</th>
                  <th>{t('table.failed_at')}</th>
                </tr>
              </thead>
              <tbody>
                {data.entries.map((entry) => {
                  const argsStr = formatArgs(entry.args);
                  return (
                    <tr key={entry.jid}>
                      <td
                        title={entry.jid}
                        style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text-muted)' }}
                      >
                        {truncate(entry.jid, 12)}
                      </td>
                      <td style={{ fontWeight: 500 }}>{entry.class}</td>
                      <td title={argsStr}>{truncate(argsStr, 40)}</td>
                      <td title={entry.error_class} style={{ color: 'var(--danger)' }}>
                        {truncate(entry.error_class, 25)}
                      </td>
                      <td title={entry.error_message}>{truncate(entry.error_message, 40)}</td>
                      <td title={new Date(entry.failed_at * 1000).toISOString()}>
                        {relativeTime(entry.failed_at)}
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

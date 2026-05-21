import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { t } from '../i18n';
import { relativeTime, truncate, formatArgs } from '../utils';

interface ScheduledEntry {
  jid: string;
  class: string;
  args: unknown;
  score: number;
  at: number;
}

interface ScheduledResponse {
  total: number;
  page: number;
  count: number;
  entries: ScheduledEntry[];
}

const PAGE_SIZE = 25;

export default function Scheduled() {
  const [page, setPage] = useState(1);

  useEffect(() => {
    document.title = `${t('nav.scheduled')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<ScheduledResponse>({
    queryKey: ['scheduled', page],
    queryFn: () =>
      fetch(`/wurk/api/scheduled?page=${page}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<ScheduledResponse>
      ),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <div className="section-header">
        <h1 className="page-title" style={{ margin: 0 }}>{t('nav.scheduled')}</h1>
        <span className="badge badge-accent" style={{ marginLeft: 'auto' }}>{data.total.toLocaleString()}</span>
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
                  <th>{t('table.scheduled_at')}</th>
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
                      <td title={argsStr}>{truncate(argsStr, 60)}</td>
                      <td title={new Date(entry.at * 1000).toISOString()}>
                        {relativeTime(entry.at)}
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

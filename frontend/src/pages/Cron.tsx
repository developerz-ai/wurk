import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { t } from '../i18n';
import { relativeTime, truncate } from '../utils';

interface CronEntry {
  name: string;
  cron: string;
  class: string;
  args: unknown;
  last_run: number | null;
  next_run: number | null;
  status: string;
}

function statusBadge(status: string) {
  switch (status.toLowerCase()) {
    case 'active':
    case 'ok':
      return <span className="badge badge-success">{status}</span>;
    case 'error':
    case 'failed':
      return <span className="badge badge-danger">{status}</span>;
    case 'disabled':
      return <span className="badge badge-muted">{status}</span>;
    default:
      return <span className="badge badge-accent">{status}</span>;
  }
}

export default function Cron() {
  useEffect(() => {
    document.title = `${t('nav.cron')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<CronEntry[]>({
    queryKey: ['cron'],
    queryFn: () => fetch('/wurk/api/cron').then((r) => r.json() as Promise<CronEntry[]>),
    refetchInterval: 15000,
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <div className="section-header">
        <h1 className="page-title" style={{ margin: 0 }}>{t('nav.cron')}</h1>
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
                <th>Schedule</th>
                <th>{t('table.class')}</th>
                <th>{t('table.last_run')}</th>
                <th>{t('table.next_run')}</th>
                <th>{t('table.status')}</th>
              </tr>
            </thead>
            <tbody>
              {data.map((entry) => (
                <tr key={entry.name}>
                  <td style={{ fontWeight: 500 }} title={entry.name}>{truncate(entry.name, 30)}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{entry.cron}</td>
                  <td title={entry.class}>{truncate(entry.class, 35)}</td>
                  <td style={{ color: 'var(--text-muted)' }}>
                    {entry.last_run ? relativeTime(entry.last_run) : '—'}
                  </td>
                  <td style={{ color: 'var(--accent)' }}>
                    {entry.next_run ? relativeTime(entry.next_run) : '—'}
                  </td>
                  <td>{statusBadge(entry.status)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

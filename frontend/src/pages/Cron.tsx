import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect } from 'react';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate } from '../utils';
import { useMeta } from '../hooks/useMeta';

interface CronLoop {
  lid: string;
  schedule: string;
  klass: string;
  queue: string;
  tz: string | null;
  paused: boolean;
  args: unknown[];
  last_fire_at: number | null;
  next_fire_at: number | null;
}

export default function Cron() {
  const qc = useQueryClient();
  const { data: meta } = useMeta();
  const readOnly = meta?.read_only ?? false;

  useEffect(() => {
    document.title = `${t('nav.cron')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<CronLoop[]>({
    queryKey: ['cron'],
    queryFn: () => fetch('/wurk/api/cron').then((r) => r.json() as Promise<CronLoop[]>),
    refetchInterval: 15000,
  });

  // pause/unpause/enqueue skip CSRF (see ApiController#skip_forgery_protection).
  const post = (lid: string, action: string) =>
    fetch(`/wurk/api/cron/${lid}/${action}`, { method: 'POST' });

  const setPaused = useMutation({
    mutationFn: ({ lid, paused }: { lid: string; paused: boolean }) =>
      post(lid, paused ? 'unpause' : 'pause'),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['cron'] }),
  });

  const enqueueNow = useMutation({
    mutationFn: (lid: string) => post(lid, 'enqueue'),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['cron'] }),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <PageHeader icon="fa-stopwatch" title={t('nav.cron')} summary={t('summaries.cron')}>
        <span className="badge badge-muted">{data.length}</span>
      </PageHeader>

      {data.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <div className="table-wrapper">
          <table>
            <thead>
              <tr>
                <th>Schedule</th>
                <th>{t('table.class')}</th>
                <th>{t('table.queue')}</th>
                <th>Last fire</th>
                <th>Next fire</th>
                <th>{t('table.status')}</th>
                {!readOnly && <th />}
              </tr>
            </thead>
            <tbody>
              {data.map((loop) => (
                <tr key={loop.lid}>
                  <td style={{ fontFamily: 'monospace', fontSize: 12 }} title={loop.tz ?? undefined}>
                    {loop.schedule}
                  </td>
                  <td title={loop.klass}>{truncate(loop.klass, 32)}</td>
                  <td>{loop.queue}</td>
                  <td style={{ color: 'var(--text-muted)' }}>
                    {loop.last_fire_at ? relativeTime(loop.last_fire_at) : '—'}
                  </td>
                  <td style={{ color: loop.paused ? 'var(--text-muted)' : 'var(--accent)' }}>
                    {loop.paused ? '—' : loop.next_fire_at ? relativeTime(loop.next_fire_at) : '—'}
                  </td>
                  <td>
                    {loop.paused ? (
                      <span className="badge badge-muted">paused</span>
                    ) : (
                      <span className="badge badge-success">active</span>
                    )}
                  </td>
                  {!readOnly && (
                    <td>
                      <div style={{ display: 'flex', gap: '0.4rem' }}>
                        <button
                          className="btn btn-sm"
                          disabled={setPaused.isPending}
                          onClick={() => setPaused.mutate({ lid: loop.lid, paused: loop.paused })}
                        >
                          {loop.paused ? 'Resume' : 'Pause'}
                        </button>
                        <button
                          className="btn btn-sm"
                          disabled={enqueueNow.isPending}
                          onClick={() => enqueueNow.mutate(loop.lid)}
                        >
                          Enqueue
                        </button>
                      </div>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

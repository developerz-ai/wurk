import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect } from 'react';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime } from '../utils';
import { useMeta } from '../hooks/useMeta';

interface Process {
  identity: string;
  pid: number;
  hostname: string;
  queues: string[];
  concurrency: number;
  busy: number;
  quiet: boolean;
  beat_at: number;
  embedded?: boolean;
}

type Signal = 'quiet' | 'stop';

export default function Busy() {
  const { data: meta } = useMeta();
  const readOnly = meta?.read_only ?? false;
  const qc = useQueryClient();

  useEffect(() => {
    document.title = `${t('nav.busy')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<Process[]>({
    queryKey: ['processes'],
    queryFn: () => fetch('/wurk/api/processes').then((r) => r.json() as Promise<Process[]>),
    refetchInterval: 5000,
  });

  // Quiet (SIGTSTP) / stop (SIGTERM) one process by identity, or all when
  // identity is omitted. Both are async — the process reacts on its next
  // heartbeat — so we just refetch rather than optimistically updating.
  const control = useMutation({
    mutationFn: async ({ signal, identity }: { signal: Signal; identity?: string }) => {
      const res = await fetch(`/wurk/api/busy/${signal}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ identity: identity ?? 'all' }),
      });
      if (!res.ok) throw new Error(`${signal} failed (${res.status})`);
      return res;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['processes'] }),
  });

  const confirmStop = (scope: string) =>
    window.confirm(t('actions.confirm', { action: t('actions.stop'), scope }));

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  const controllable = data.some((p) => !p.embedded);

  return (
    <div>
      <PageHeader icon="fa-gears" title={t('nav.busy')} summary={t('summaries.busy')}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem' }}>
          <span className="badge badge-muted">
            {data.length} {t('dashboard.processes').toLowerCase()}
          </span>
          {!readOnly && controllable && (
            <>
              <button
                className="btn btn-sm btn-ghost"
                disabled={control.isPending}
                onClick={() => control.mutate({ signal: 'quiet' })}
              >
                {`${t('actions.quiet')} ${t('actions.all_suffix')}`}
              </button>
              <button
                className="btn btn-sm btn-ghost btn-danger"
                disabled={control.isPending}
                onClick={() => confirmStop(t('actions.scope_all_processes')) && control.mutate({ signal: 'stop' })}
              >
                {`${t('actions.stop')} ${t('actions.all_suffix')}`}
              </button>
            </>
          )}
        </div>
      </PageHeader>

      {data.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(min(100%, 320px), 1fr))',
            gap: '1rem',
          }}
        >
          {data.map((proc) => {
            const utilization = proc.concurrency > 0 ? (proc.busy / proc.concurrency) * 100 : 0;
            const isRecent = Date.now() / 1000 - proc.beat_at < 30;

            return (
              <div key={proc.identity ?? `${proc.hostname}-${proc.pid}`} className="card">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '0.75rem' }}>
                  <div>
                    <div style={{ fontWeight: 600, fontSize: 15 }}>{proc.hostname}</div>
                    <div style={{ color: 'var(--text-muted)', fontSize: 12 }}>PID {proc.pid}</div>
                  </div>
                  <div style={{ display: 'flex', gap: '0.375rem' }}>
                    {isRecent && <span className="live-dot" title="Heartbeat OK" />}
                    {proc.quiet && <span className="badge badge-warning">Quiet</span>}
                  </div>
                </div>

                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0.5rem', marginBottom: '0.75rem' }}>
                  <div>
                    <div style={{ fontSize: 11, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                      {t('table.busy')} / {t('table.concurrency')}
                    </div>
                    <div style={{ fontWeight: 600, fontSize: 18, fontVariantNumeric: 'tabular-nums' }}>
                      {proc.busy} / {proc.concurrency}
                    </div>
                  </div>
                  <div>
                    <div style={{ fontSize: 11, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                      Heartbeat
                    </div>
                    <div style={{ fontSize: 13, color: isRecent ? 'var(--success)' : 'var(--danger)' }}>
                      {relativeTime(proc.beat_at)}
                    </div>
                  </div>
                </div>

                <div className="progress-bar-track" style={{ marginBottom: '0.75rem' }}>
                  <div
                    className="progress-bar-fill"
                    style={{
                      width: `${utilization}%`,
                      background:
                        utilization > 90
                          ? 'var(--danger)'
                          : utilization > 70
                          ? 'var(--warning)'
                          : 'var(--accent)',
                    }}
                  />
                </div>

                <div>
                  <div style={{ fontSize: 11, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.04em', marginBottom: '0.25rem' }}>
                    {t('table.queues')}
                  </div>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.25rem' }}>
                    {proc.queues.map((q) => (
                      <span key={q} className="badge badge-muted">{q}</span>
                    ))}
                  </div>
                </div>

                {!readOnly && !proc.embedded && (
                  <div style={{ display: 'flex', gap: '0.4rem', marginTop: '0.85rem' }}>
                    <button
                      className="btn btn-sm"
                      disabled={control.isPending}
                      onClick={() => control.mutate({ signal: 'quiet', identity: proc.identity })}
                    >
                      {t('actions.quiet')}
                    </button>
                    <button
                      className="btn btn-sm btn-danger"
                      disabled={control.isPending}
                      onClick={() => confirmStop(t('actions.scope_this_process')) && control.mutate({ signal: 'stop', identity: proc.identity })}
                    >
                      {t('actions.stop')}
                    </button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

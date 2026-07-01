import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState, type ReactNode } from 'react';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import Modal from '../components/Modal';
import { ArgsValue } from '../components/ArgsValue';
import { relativeTime, isoTime, formatKb, formatDuration, formatArgs, truncate } from '../utils';
import { useMeta } from '../hooks/useMeta';
import { SkeletonCards } from '../components/Skeleton';

interface Process {
  identity: string;
  pid: number;
  hostname: string;
  tag?: string;
  queues: string[];
  labels: string[];
  concurrency: number;
  busy: number;
  quiet: boolean;
  beat: number;
  rss?: number;
  rtt_us?: number;
  started_at?: number;
  cpu_model?: string | null;
  cores?: number;
  memory_total_kb?: number;
  version?: string;
  embedded?: boolean;
}

interface WorkRow {
  process_id: string;
  thread_id: string;
  queue: string;
  klass: string;
  args: unknown;
  jid: string;
  run_at: number;
}

type Signal = 'quiet' | 'stop';
// Discriminated so "all" is only ever sent for an explicit all-processes click —
// a missing/empty `proc.identity` can never silently fall back to signalling
// every process.
type ControlTarget =
  | { signal: Signal; scope: 'all' }
  | { signal: Signal; scope: 'one'; identity: string };

interface HostGroup {
  hostname: string;
  processes: Process[];
  busy: number;
  concurrency: number;
  rssKb: number;
  // Static per machine, so any process on the host can report them.
  cpuModel?: string | null;
  cores?: number;
  memoryTotalKb?: number;
}

// Processes carrying the same `hostname` run on one machine — fold them into
// a single host section so a multi-process swarm reads as one box.
function groupByHost(processes: Process[]): HostGroup[] {
  const groups = new Map<string, HostGroup>();
  for (const proc of processes) {
    let g = groups.get(proc.hostname);
    if (!g) {
      g = { hostname: proc.hostname, processes: [], busy: 0, concurrency: 0, rssKb: 0 };
      groups.set(proc.hostname, g);
    }
    g.processes.push(proc);
    g.busy += proc.busy;
    g.concurrency += proc.concurrency;
    g.rssKb += proc.rss ?? 0;
    g.cpuModel ??= proc.cpu_model ?? undefined;
    g.cores ??= proc.cores;
    g.memoryTotalKb ??= proc.memory_total_kb;
  }
  return [...groups.values()].sort((a, b) => a.hostname.localeCompare(b.hostname));
}

function utilizationColor(pct: number): string {
  return pct > 90 ? 'var(--danger)' : pct > 70 ? 'var(--warning)' : 'var(--accent)';
}

const statLabelStyle = {
  fontSize: 11,
  color: 'var(--text-muted)',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
} as const;

function ProcessDetail({ proc }: { proc: Process }) {
  const { data: work } = useQuery<WorkRow[]>({
    queryKey: ['workers'],
    queryFn: () => fetch('/wurk/api/workers').then((r) => r.json() as Promise<WorkRow[]>),
    refetchInterval: 5000,
  });
  const rows = (work ?? []).filter((w) => w.process_id === proc.identity);

  const facts: Array<[string, ReactNode]> = [
    [t('busy.identity'), <code style={{ fontSize: 12 }}>{proc.identity}</code>],
    ['PID', proc.pid],
    [t('busy.started'), proc.started_at ? <span title={isoTime(proc.started_at)}>{relativeTime(proc.started_at)}</span> : '—'],
    [t('busy.heartbeat'), <span title={isoTime(proc.beat)}>{relativeTime(proc.beat)}</span>],
    [`${t('table.busy')} / ${t('table.concurrency')}`, `${proc.busy} / ${proc.concurrency}`],
    [t('busy.rss'), formatKb(proc.rss ?? 0)],
    [t('busy.rtt'), proc.rtt_us ? `${(proc.rtt_us / 1000).toFixed(1)} ${t('common.ms')}` : '—'],
    [t('busy.version'), proc.version ?? '—'],
    [t('busy.tag'), proc.tag || '—'],
    [t('busy.labels'), proc.labels?.length ? proc.labels.join(', ') : '—'],
  ];

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))', gap: '0.75rem', marginBottom: '1rem' }}>
        {facts.map(([label, value]) => (
          <div key={String(label)}>
            <div style={statLabelStyle}>{label}</div>
            <div style={{ fontSize: 14 }}>{value}</div>
          </div>
        ))}
      </div>

      <div style={{ ...statLabelStyle, marginBottom: '0.25rem' }}>{t('table.queues')}</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.25rem', marginBottom: '1rem' }}>
        {proc.queues.map((q) => (
          <span key={q} className="badge badge-muted">{q}</span>
        ))}
      </div>

      <h3 className="section-title" style={{ marginBottom: '0.5rem' }}>
        {t('busy.running_jobs')} <span className="badge badge-muted">{rows.length}</span>
      </h3>
      {rows.length === 0 ? (
        <div className="empty-state" style={{ padding: '1rem' }}>{t('busy.no_running')}</div>
      ) : (
        <div className="table-wrapper">
          <table>
            <thead>
              <tr>
                <th>{t('table.jid')}</th>
                <th>{t('table.class')}</th>
                <th>{t('table.queue')}</th>
                <th>{t('table.args')}</th>
                <th>{t('busy.running_since')}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((w) => (
                <tr key={`${w.thread_id}-${w.jid}`}>
                  <td title={w.jid} style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text-muted)' }}>
                    {truncate(w.jid, 12)}
                  </td>
                  <td style={{ fontWeight: 500 }}>{w.klass}</td>
                  <td><span className="badge badge-muted">{w.queue}</span></td>
                  <td><ArgsValue str={formatArgs(w.args)} max={40} /></td>
                  <td title={isoTime(w.run_at)}>{relativeTime(w.run_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function HostHeader({ group }: { group: HostGroup }) {
  const ramPct = group.memoryTotalKb ? Math.min(100, (group.rssKb / group.memoryTotalKb) * 100) : null;

  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: '0.75rem', marginBottom: '0.75rem' }}>
      <span style={{ fontWeight: 600, fontSize: 15 }}>
        <i className="fa-solid fa-server" style={{ color: 'var(--text-muted)', marginRight: '0.5rem' }} />
        {group.hostname}
      </span>
      <span className="badge badge-muted">
        {group.processes.length} {t('dashboard.processes').toLowerCase()}
      </span>
      {group.cpuModel && (
        <span className="badge badge-muted" title={group.cpuModel}>
          <i className="fa-solid fa-microchip" style={{ marginRight: '0.35rem' }} />
          {truncate(group.cpuModel, 40)}
        </span>
      )}
      {group.cores != null && group.cores > 0 && (
        <span className="badge badge-muted">{t('busy.cores', { n: group.cores })}</span>
      )}
      {group.rssKb > 0 && (
        <span
          className="badge badge-muted"
          title={ramPct != null ? `${ramPct.toFixed(1)}% ${t('busy.of_total_ram')}` : undefined}
        >
          <i className="fa-solid fa-memory" style={{ marginRight: '0.35rem' }} />
          {formatKb(group.rssKb)}
          {group.memoryTotalKb ? ` / ${formatKb(group.memoryTotalKb)}` : ''}
        </span>
      )}
      <span className="badge badge-muted" style={{ fontVariantNumeric: 'tabular-nums' }}>
        {t('table.busy')} {group.busy} / {group.concurrency}
      </span>
    </div>
  );
}

export default function Busy() {
  const { data: meta } = useMeta();
  const readOnly = meta?.read_only ?? false;
  const qc = useQueryClient();
  const [selected, setSelected] = useState<string | null>(null);

  useEffect(() => {
    document.title = `${t('nav.busy')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<Process[]>({
    queryKey: ['processes'],
    queryFn: () => fetch('/wurk/api/processes').then((r) => r.json() as Promise<Process[]>),
    refetchInterval: 5000,
  });

  // Quiet (SIGTSTP) / stop (SIGTERM) one process by identity, or all when
  // scope is 'all'. Both are async — the process reacts on its next
  // heartbeat — so we just refetch rather than optimistically updating.
  const control = useMutation({
    mutationFn: async (target: ControlTarget) => {
      const { signal } = target;
      const identity = target.scope === 'all' ? 'all' : target.identity;
      const res = await fetch(`/wurk/api/busy/${signal}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ identity }),
      });
      if (!res.ok) throw new Error(`${signal} failed (${res.status})`);
      return res;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['processes'] }),
  });

  const confirmStop = (scope: string) =>
    window.confirm(t('actions.confirm', { action: t('actions.stop'), scope }));

  if (isLoading)
    return (
      <div>
        <PageHeader icon="fa-gears" title={t('nav.busy')} summary={t('summaries.busy')} />
        <SkeletonCards count={6} />
      </div>
    );
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  const controllable = data.some((p) => !p.embedded);
  const hosts = groupByHost(data);
  const selectedProc = data.find((p) => p.identity === selected) ?? null;

  return (
    <div>
      <PageHeader icon="fa-gears" title={t('nav.busy')} summary={t('summaries.busy')}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem' }}>
          <span className="badge badge-muted">
            {data.length} {t('dashboard.processes').toLowerCase()}
          </span>
          {hosts.length > 1 && (
            <span className="badge badge-muted">{t('busy.hosts', { n: hosts.length })}</span>
          )}
          {!readOnly && controllable && (
            <>
              <button
                className="btn btn-sm btn-ghost"
                disabled={control.isPending}
                onClick={() => control.mutate({ signal: 'quiet', scope: 'all' })}
              >
                {`${t('actions.quiet')} ${t('actions.all_suffix')}`}
              </button>
              <button
                className="btn btn-sm btn-ghost btn-danger"
                disabled={control.isPending}
                onClick={() => confirmStop(t('actions.scope_all_processes')) && control.mutate({ signal: 'stop', scope: 'all' })}
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
        hosts.map((group) => (
          <section key={group.hostname} style={{ marginBottom: '1.5rem' }}>
            <HostHeader group={group} />
            <div
              style={{
                display: 'grid',
                gridTemplateColumns: 'repeat(auto-fill, minmax(min(100%, 320px), 1fr))',
                gap: '1rem',
              }}
            >
              {group.processes.map((proc) => {
                const utilization = proc.concurrency > 0 ? (proc.busy / proc.concurrency) * 100 : 0;
                const isRecent = Date.now() / 1000 - proc.beat < 30;

                return (
                  <div
                    key={proc.identity ?? `${proc.hostname}-${proc.pid}`}
                    className="card row-clickable"
                    onClick={() => proc.identity && setSelected(proc.identity)}
                  >
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '0.75rem' }}>
                      <div>
                        <div style={{ fontWeight: 600, fontSize: 15 }}>PID {proc.pid}</div>
                        <div style={{ color: 'var(--text-muted)', fontSize: 12 }}>
                          {proc.tag || proc.hostname}
                          {proc.started_at ? ` · ${t('busy.up_for')} ${formatDuration(Date.now() / 1000 - proc.started_at)}` : ''}
                        </div>
                      </div>
                      <div style={{ display: 'flex', gap: '0.375rem' }}>
                        {isRecent && <span className="live-dot" title="Heartbeat OK" />}
                        {proc.quiet && <span className="badge badge-warning">Quiet</span>}
                        {proc.embedded && <span className="badge badge-muted">embedded</span>}
                      </div>
                    </div>

                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '0.5rem', marginBottom: '0.75rem' }}>
                      <div>
                        <div style={statLabelStyle}>
                          {t('table.busy')} / {t('table.concurrency')}
                        </div>
                        <div style={{ fontWeight: 600, fontSize: 18, fontVariantNumeric: 'tabular-nums' }}>
                          {proc.busy} / {proc.concurrency}
                        </div>
                      </div>
                      <div>
                        <div style={statLabelStyle}>{t('busy.heartbeat')}</div>
                        <div style={{ fontSize: 13, color: isRecent ? 'var(--success)' : 'var(--danger)' }}>
                          {relativeTime(proc.beat)}
                        </div>
                      </div>
                      <div>
                        <div style={statLabelStyle}>{t('busy.rss')}</div>
                        <div style={{ fontSize: 13 }}>{formatKb(proc.rss ?? 0)}</div>
                      </div>
                    </div>

                    <div className="progress-bar-track" style={{ marginBottom: '0.75rem' }}>
                      <div
                        className="progress-bar-fill"
                        style={{ width: `${utilization}%`, background: utilizationColor(utilization) }}
                      />
                    </div>

                    <div>
                      <div style={{ ...statLabelStyle, marginBottom: '0.25rem' }}>
                        {t('table.queues')}
                      </div>
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.25rem' }}>
                        {proc.queues.map((q) => (
                          <span key={q} className="badge badge-muted">{q}</span>
                        ))}
                      </div>
                    </div>

                    {!readOnly && !proc.embedded && (
                      <div style={{ display: 'flex', gap: '0.4rem', marginTop: '0.85rem' }} onClick={(e) => e.stopPropagation()}>
                        <button
                          className="btn btn-sm"
                          disabled={control.isPending}
                          onClick={() => control.mutate({ signal: 'quiet', scope: 'one', identity: proc.identity })}
                        >
                          {t('actions.quiet')}
                        </button>
                        <button
                          className="btn btn-sm btn-danger"
                          disabled={control.isPending}
                          onClick={() => confirmStop(t('actions.scope_this_process')) && control.mutate({ signal: 'stop', scope: 'one', identity: proc.identity })}
                        >
                          {t('actions.stop')}
                        </button>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </section>
        ))
      )}

      <Modal
        open={selectedProc !== null}
        onClose={() => setSelected(null)}
        title={selectedProc ? `${selectedProc.hostname} · PID ${selectedProc.pid}` : ''}
        width={780}
      >
        {selectedProc && <ProcessDetail proc={selectedProc} />}
      </Modal>
    </div>
  );
}

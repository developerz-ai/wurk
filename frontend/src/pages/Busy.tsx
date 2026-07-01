import { useQuery, useMutation, useQueryClient } from '@tanstack/solid-query';
import { createSignal, onMount, For, Show, Switch, Match, type JSX } from 'solid-js';
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
  'font-size': '11px',
  color: 'var(--text-muted)',
  'text-transform': 'uppercase',
  'letter-spacing': '0.04em',
} as const;

function ProcessDetail(props: { proc: Process }) {
  const work = useQuery<WorkRow[]>(() => ({
    queryKey: ['workers'],
    queryFn: () => fetch('/wurk/api/workers').then((r) => r.json() as Promise<WorkRow[]>),
    refetchInterval: 5000,
  }));
  const rows = () => (work.data ?? []).filter((w) => w.process_id === props.proc.identity);

  const facts = (): Array<[string, JSX.Element]> => [
    [t('busy.identity'), <code style={{ 'font-size': '12px' }}>{props.proc.identity}</code>],
    ['PID', props.proc.pid],
    [t('busy.started'), props.proc.started_at ? <span title={isoTime(props.proc.started_at)}>{relativeTime(props.proc.started_at)}</span> : '—'],
    [t('busy.heartbeat'), <span title={isoTime(props.proc.beat)}>{relativeTime(props.proc.beat)}</span>],
    [`${t('table.busy')} / ${t('table.concurrency')}`, `${props.proc.busy} / ${props.proc.concurrency}`],
    [t('busy.rss'), formatKb(props.proc.rss ?? 0)],
    [t('busy.rtt'), props.proc.rtt_us ? `${(props.proc.rtt_us / 1000).toFixed(1)} ${t('common.ms')}` : '—'],
    [t('busy.version'), props.proc.version ?? '—'],
    [t('busy.tag'), props.proc.tag || '—'],
    [t('busy.labels'), props.proc.labels?.length ? props.proc.labels.join(', ') : '—'],
  ];

  return (
    <div>
      <div style={{ display: 'grid', 'grid-template-columns': 'repeat(auto-fill, minmax(200px, 1fr))', gap: '0.75rem', 'margin-bottom': '1rem' }}>
        <For each={facts()}>
          {([label, value]) => (
            <div>
              <div style={statLabelStyle}>{label}</div>
              <div style={{ 'font-size': '14px' }}>{value}</div>
            </div>
          )}
        </For>
      </div>

      <div style={{ ...statLabelStyle, 'margin-bottom': '0.25rem' }}>{t('table.queues')}</div>
      <div style={{ display: 'flex', 'flex-wrap': 'wrap', gap: '0.25rem', 'margin-bottom': '1rem' }}>
        <For each={props.proc.queues}>
          {(q) => <span class="badge badge-muted">{q}</span>}
        </For>
      </div>

      <h3 class="section-title" style={{ 'margin-bottom': '0.5rem' }}>
        {t('busy.running_jobs')} <span class="badge badge-muted">{rows().length}</span>
      </h3>
      <Show when={rows().length > 0} fallback={<div class="empty-state" style={{ padding: '1rem' }}>{t('busy.no_running')}</div>}>
        <div class="table-wrapper">
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
              <For each={rows()}>
                {(w) => (
                  <tr>
                    <td title={w.jid} style={{ 'font-family': 'monospace', 'font-size': '12px', color: 'var(--text-muted)' }}>
                      {truncate(w.jid, 12)}
                    </td>
                    <td style={{ 'font-weight': 500 }}>{w.klass}</td>
                    <td><span class="badge badge-muted">{w.queue}</span></td>
                    <td><ArgsValue str={formatArgs(w.args)} max={40} /></td>
                    <td title={isoTime(w.run_at)}>{relativeTime(w.run_at)}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </Show>
    </div>
  );
}

function HostHeader(props: { group: HostGroup }) {
  const ramPct = () => props.group.memoryTotalKb ? Math.min(100, (props.group.rssKb / props.group.memoryTotalKb) * 100) : null;

  return (
    <div style={{ display: 'flex', 'flex-wrap': 'wrap', 'align-items': 'center', gap: '0.75rem', 'margin-bottom': '0.75rem' }}>
      <span style={{ 'font-weight': 600, 'font-size': '15px' }}>
        <i class="fa-solid fa-server" style={{ color: 'var(--text-muted)', 'margin-right': '0.5rem' }} />
        {props.group.hostname}
      </span>
      <span class="badge badge-muted">
        {props.group.processes.length} {t('dashboard.processes').toLowerCase()}
      </span>
      <Show when={props.group.cpuModel}>
        <span class="badge badge-muted" title={props.group.cpuModel ?? undefined}>
          <i class="fa-solid fa-microchip" style={{ 'margin-right': '0.35rem' }} />
          {truncate(props.group.cpuModel, 40)}
        </span>
      </Show>
      <Show when={props.group.cores != null && props.group.cores > 0}>
        <span class="badge badge-muted">{t('busy.cores', { n: props.group.cores! })}</span>
      </Show>
      <Show when={props.group.rssKb > 0}>
        <span
          class="badge badge-muted"
          title={ramPct() != null ? `${ramPct()!.toFixed(1)}% ${t('busy.of_total_ram')}` : undefined}
        >
          <i class="fa-solid fa-memory" style={{ 'margin-right': '0.35rem' }} />
          {formatKb(props.group.rssKb)}
          {props.group.memoryTotalKb ? ` / ${formatKb(props.group.memoryTotalKb)}` : ''}
        </span>
      </Show>
      <span class="badge badge-muted" style={{ 'font-variant-numeric': 'tabular-nums' }}>
        {t('table.busy')} {props.group.busy} / {props.group.concurrency}
      </span>
    </div>
  );
}

export default function Busy() {
  const meta = useMeta();
  const readOnly = () => meta.data?.read_only ?? false;
  const qc = useQueryClient();
  const [selected, setSelected] = createSignal<string | null>(null);

  onMount(() => {
    document.title = `${t('nav.busy')} — Wurk`;
  });

  const query = useQuery<Process[]>(() => ({
    queryKey: ['processes'],
    queryFn: () => fetch('/wurk/api/processes').then((r) => r.json() as Promise<Process[]>),
    refetchInterval: 5000,
  }));

  // Quiet (SIGTSTP) / stop (SIGTERM) one process by identity, or all when
  // scope is 'all'. Both are async — the process reacts on its next
  // heartbeat — so we just refetch rather than optimistically updating.
  const control = useMutation(() => ({
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
  }));

  const confirmStop = (scope: string) =>
    window.confirm(t('actions.confirm', { action: t('actions.stop'), scope }));

  const controllable = () => (query.data ?? []).some((p) => !p.embedded);
  const hosts = () => groupByHost(query.data ?? []);
  const selectedProc = () => (query.data ?? []).find((p) => p.identity === selected()) ?? null;

  return (
    <Switch>
      <Match when={query.isPending}>
        <div>
          <PageHeader icon="fa-gears" title={t('nav.busy')} summary={t('summaries.busy')} />
          <SkeletonCards count={6} />
        </div>
      </Match>
      <Match when={query.isError || !query.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={query.data}>
        {(data) => (
          <div>
            <PageHeader icon="fa-gears" title={t('nav.busy')} summary={t('summaries.busy')}>
              <div style={{ display: 'flex', 'align-items': 'center', gap: '0.6rem' }}>
                <span class="badge badge-muted">
                  {data().length} {t('dashboard.processes').toLowerCase()}
                </span>
                <Show when={hosts().length > 1}>
                  <span class="badge badge-muted">{t('busy.hosts', { n: hosts().length })}</span>
                </Show>
                <Show when={!readOnly() && controllable()}>
                  <>
                    <button
                      class="btn btn-sm btn-ghost"
                      disabled={control.isPending}
                      onClick={() => control.mutate({ signal: 'quiet', scope: 'all' })}
                    >
                      {`${t('actions.quiet')} ${t('actions.all_suffix')}`}
                    </button>
                    <button
                      class="btn btn-sm btn-ghost btn-danger"
                      disabled={control.isPending}
                      onClick={() => confirmStop(t('actions.scope_all_processes')) && control.mutate({ signal: 'stop', scope: 'all' })}
                    >
                      {`${t('actions.stop')} ${t('actions.all_suffix')}`}
                    </button>
                  </>
                </Show>
              </div>
            </PageHeader>

            <Show when={data().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <For each={hosts()}>
                {(group) => (
                  <section style={{ 'margin-bottom': '1.5rem' }}>
                    <HostHeader group={group} />
                    <div
                      style={{
                        display: 'grid',
                        'grid-template-columns': 'repeat(auto-fill, minmax(min(100%, 320px), 1fr))',
                        gap: '1rem',
                      }}
                    >
                      <For each={group.processes}>
                        {(proc) => {
                          const utilization = proc.concurrency > 0 ? (proc.busy / proc.concurrency) * 100 : 0;
                          const isRecent = Date.now() / 1000 - proc.beat < 30;

                          return (
                            <div
                              class="card row-clickable"
                              onClick={() => proc.identity && setSelected(proc.identity)}
                            >
                              <div style={{ display: 'flex', 'justify-content': 'space-between', 'align-items': 'flex-start', 'margin-bottom': '0.75rem' }}>
                                <div>
                                  <div style={{ 'font-weight': 600, 'font-size': '15px' }}>PID {proc.pid}</div>
                                  <div style={{ color: 'var(--text-muted)', 'font-size': '12px' }}>
                                    {proc.tag || proc.hostname}
                                    {proc.started_at ? ` · ${t('busy.up_for')} ${formatDuration(Date.now() / 1000 - proc.started_at)}` : ''}
                                  </div>
                                </div>
                                <div style={{ display: 'flex', gap: '0.375rem' }}>
                                  <Show when={isRecent}><span class="live-dot" title="Heartbeat OK" /></Show>
                                  <Show when={proc.quiet}><span class="badge badge-warning">Quiet</span></Show>
                                  <Show when={proc.embedded}><span class="badge badge-muted">embedded</span></Show>
                                </div>
                              </div>

                              <div style={{ display: 'grid', 'grid-template-columns': '1fr 1fr 1fr', gap: '0.5rem', 'margin-bottom': '0.75rem' }}>
                                <div>
                                  <div style={statLabelStyle}>
                                    {t('table.busy')} / {t('table.concurrency')}
                                  </div>
                                  <div style={{ 'font-weight': 600, 'font-size': '18px', 'font-variant-numeric': 'tabular-nums' }}>
                                    {proc.busy} / {proc.concurrency}
                                  </div>
                                </div>
                                <div>
                                  <div style={statLabelStyle}>{t('busy.heartbeat')}</div>
                                  <div style={{ 'font-size': '13px', color: isRecent ? 'var(--success)' : 'var(--danger)' }}>
                                    {relativeTime(proc.beat)}
                                  </div>
                                </div>
                                <div>
                                  <div style={statLabelStyle}>{t('busy.rss')}</div>
                                  <div style={{ 'font-size': '13px' }}>{formatKb(proc.rss ?? 0)}</div>
                                </div>
                              </div>

                              <div class="progress-bar-track" style={{ 'margin-bottom': '0.75rem' }}>
                                <div
                                  class="progress-bar-fill"
                                  style={{ width: `${utilization}%`, background: utilizationColor(utilization) }}
                                />
                              </div>

                              <div>
                                <div style={{ ...statLabelStyle, 'margin-bottom': '0.25rem' }}>
                                  {t('table.queues')}
                                </div>
                                <div style={{ display: 'flex', 'flex-wrap': 'wrap', gap: '0.25rem' }}>
                                  <For each={proc.queues}>
                                    {(q) => <span class="badge badge-muted">{q}</span>}
                                  </For>
                                </div>
                              </div>

                              <Show when={!readOnly() && !proc.embedded}>
                                <div style={{ display: 'flex', gap: '0.4rem', 'margin-top': '0.85rem' }} onClick={(e) => e.stopPropagation()}>
                                  <button
                                    class="btn btn-sm"
                                    disabled={control.isPending}
                                    onClick={() => control.mutate({ signal: 'quiet', scope: 'one', identity: proc.identity })}
                                  >
                                    {t('actions.quiet')}
                                  </button>
                                  <button
                                    class="btn btn-sm btn-danger"
                                    disabled={control.isPending}
                                    onClick={() => confirmStop(t('actions.scope_this_process')) && control.mutate({ signal: 'stop', scope: 'one', identity: proc.identity })}
                                  >
                                    {t('actions.stop')}
                                  </button>
                                </div>
                              </Show>
                            </div>
                          );
                        }}
                      </For>
                    </div>
                  </section>
                )}
              </For>
            </Show>

            <Modal
              open={selectedProc() !== null}
              onClose={() => setSelected(null)}
              title={selectedProc() ? `${selectedProc()!.hostname} · PID ${selectedProc()!.pid}` : ''}
              width={780}
            >
              <Show when={selectedProc()}>{(proc) => <ProcessDetail proc={proc()} />}</Show>
            </Modal>
          </div>
        )}
      </Match>
    </Switch>
  );
}

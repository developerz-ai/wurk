import { useMutation, useQueryClient } from '@tanstack/solid-query';
import { prefetch, useQuery } from '../query';
import { processesQuery } from '../routeQueries';
import { optimistic, type OptimisticContext } from '../optimistic';
import { createMemo, createSignal, onMount, For, Show, Switch, Match, type JSX } from 'solid-js';
import { RefreshError } from '../components/RefreshError';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import Modal from '../components/Modal';
import { activatable } from '../components/activatable';
import { ArgsValue } from '../components/ArgsValue';
import { relativeTime, hoverTime, formatKb, formatDuration, formatArgs, nowSeconds, truncate } from '../utils';
import { liveTick } from '../tick';
import { useMeta } from '../hooks/useMeta';
import { SkeletonCards, SkeletonTable } from '../components/Skeleton';
import { basePath } from '../basePath';
import { getJSON, post } from '../http';
import { notifyError } from '../toast';
import Icon from '../components/Icon';

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
  cpu_limit?: number | null;
  memory_limit_kb?: number | null;
  // The Kubernetes node a pod runs on (WURK_NODE_NAME from the downward API),
  // and its zone; absent on a bare host, whose hostname already is the machine.
  node?: string | null;
  node_zone?: string | null;
  version?: string;
  embedded?: boolean;
  leader?: boolean;
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
  key: string;
  hostname: string;
  processes: Process[];
  busy: number;
  concurrency: number;
  rssKb: number;
  // Static per machine, so any process on the host can report them.
  cpuModel?: string | null;
  cores?: number;
  memoryTotalKb?: number;
  // The cgroup's caps (a pod's limits), absent on a machine nothing caps.
  cpuLimit?: number;
  memoryLimitKb?: number;
  node?: string;
  nodeZone?: string;
}

// Processes carrying the same `hostname` (and node, when they report one: two
// namespaces can each run a pod of one name) run on one machine — fold them
// into a single host section so a multi-process swarm reads as one box.
export const hostKey = (p: { hostname: string; node?: string | null }) => (p.node ? `${p.hostname}@${p.node}` : p.hostname);

function groupByHost(processes: Process[]): HostGroup[] {
  const groups = new Map<string, HostGroup>();
  for (const proc of processes) {
    const key = hostKey(proc);
    let g = groups.get(key);
    if (!g) {
      g = { key, hostname: proc.hostname, processes: [], busy: 0, concurrency: 0, rssKb: 0 };
      groups.set(key, g);
    }
    g.processes.push(proc);
    g.busy += proc.busy;
    g.concurrency += proc.concurrency;
    g.rssKb += proc.rss ?? 0;
    g.cpuModel ??= proc.cpu_model ?? undefined;
    g.cores ??= proc.cores;
    g.memoryTotalKb ??= proc.memory_total_kb;
    g.cpuLimit ??= proc.cpu_limit ?? undefined;
    g.memoryLimitKb ??= proc.memory_limit_kb ?? undefined;
    g.node ??= proc.node ?? undefined;
    g.nodeZone ??= proc.node_zone ?? undefined;
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

const WORKERS_KEY = ['workers'];
const fetchWorkers = () => getJSON<WorkRow[]>(`${basePath()}/api/workers`);

function ProcessDetail(props: { proc: Process }) {
  const work = useQuery<WorkRow[]>(() => ({
    queryKey: WORKERS_KEY,
    queryFn: fetchWorkers,
    refetchInterval: 5000,
  }));
  const rows = () => (work.data ?? []).filter((w) => w.process_id === props.proc.identity);

  const facts = (): Array<[string, JSX.Element]> => [
    [t('busy.identity'), <code style={{ 'font-size': '12px' }}>{props.proc.identity}</code>],
    [t('busy.leader'), props.proc.leader ? <span class="badge badge-accent">{t('busy.leader')}</span> : '—'],
    ['PID', props.proc.pid],
    [t('busy.started'), props.proc.started_at ? <span title={hoverTime(props.proc.started_at)}>{relativeTime(props.proc.started_at)}</span> : '—'],
    [t('busy.heartbeat'), <span title={hoverTime(props.proc.beat)}>{relativeTime(props.proc.beat)}</span>],
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
        {t('busy.running_jobs')} <span class="badge badge-muted">{work.isPending ? props.proc.busy : rows().length}</span>
      </h3>
      {/* The heartbeat already says how many jobs run, so the placeholder has
          their row count and the table lands without moving the modal. */}
      <Show when={!work.isPending} fallback={<SkeletonTable rows={Math.max(1, Math.min(props.proc.busy, 8))} cols={5} />}>
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
                      <td title={hoverTime(w.run_at)}>{relativeTime(w.run_at)}</td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </div>
        </Show>
      </Show>
    </div>
  );
}

const QUEUE_PREVIEW = 6;

// A worker can listen on dozens of queues; past a handful they collapse
// behind a toggle so one card does not outgrow its row. The open state lives
// on the page, keyed by process, so a poll never folds a list back up.
function QueueChips(props: { queues: string[]; open: boolean; onToggle: () => void }) {
  const open = () => props.open;
  const hidden = () => Math.max(0, props.queues.length - QUEUE_PREVIEW);
  const shown = () => (open() || hidden() === 0 ? props.queues : props.queues.slice(0, QUEUE_PREVIEW));

  return (
    <div class="busy-queues" aria-label={t('table.queues')}>
      <For each={shown()}>{(q) => <span class="badge badge-muted">{q}</span>}</For>
      <Show when={hidden() > 0}>
        <button
          type="button"
          class="busy-queues__toggle"
          aria-expanded={open()}
          onClick={(e) => {
            e.stopPropagation();
            props.onToggle();
          }}
          onKeyDown={(e) => e.stopPropagation()}
        >
          {open() ? t('busy.fewer_queues') : t('busy.more_queues', { n: hidden() })}
        </button>
      </Show>
    </div>
  );
}

// Up to three decimals: 10.5 stays 10.5, and a 1 ms/1 s quota reads 0.001
// rather than rounding to nothing.
function formatCpus(n: number): string {
  return String(Number(n.toFixed(3)));
}

// CPU and memory for one machine. Inside a pod the cgroup's limits are what
// the processes can use, so they are the figures shown; the node's own cores
// and RAM move to the tooltip.
function cpuFact(g: HostGroup): { text: string; title?: string } | null {
  if (g.cpuLimit) {
    return { text: t('busy.cpu_limit', { n: formatCpus(g.cpuLimit) }), title: g.cores ? t('busy.host_cores', { n: g.cores }) : undefined };
  }
  return g.cores != null && g.cores > 0 ? { text: t('busy.cores', { n: g.cores }) } : null;
}

function memFact(g: HostGroup): { text: string; title?: string } | null {
  if (g.rssKb <= 0) return null;
  const cap = g.memoryLimitKb ?? g.memoryTotalKb;
  const title: string[] = [];
  if (cap) title.push(`${Math.min(100, (g.rssKb / cap) * 100).toFixed(1)}% ${g.memoryLimitKb ? t('busy.of_limit') : t('busy.of_total_ram')}`);
  if (g.memoryLimitKb && g.memoryTotalKb) title.push(t('busy.host_ram', { total: formatKb(g.memoryTotalKb) }));
  const text = `${formatKb(g.rssKb)}${cap ? ` / ${formatKb(cap)}` : ''}${g.memoryLimitKb ? ` ${t('busy.limit_suffix')}` : ''}`;
  return { text, title: title.join(' · ') || undefined };
}

function HostFacts(props: { group: HostGroup }) {
  const g = () => props.group;
  return (
    <>
      <Show when={g().cpuModel}>
        <span class="badge badge-muted" title={g().cpuModel ?? undefined}>
          <Icon name="microchip" style={{ 'margin-right': '0.35rem' }} />
          {truncate(g().cpuModel, 40)}
        </span>
      </Show>
      <Show when={cpuFact(g())}>
        {(cpu) => <span class="badge badge-muted" title={cpu().title}>{cpu().text}</span>}
      </Show>
      <Show when={memFact(g())}>
        {(mem) => (
          <span class="badge badge-muted" title={mem().title}>
            <Icon name="memory" style={{ 'margin-right': '0.35rem' }} />
            {mem().text}
          </span>
        )}
      </Show>
    </>
  );
}

// "on <node>" for a host that runs on a Kubernetes node; nothing elsewhere.
function NodeLabel(props: { group: HostGroup }) {
  return (
    <Show when={props.group.node}>
      {(node) => (
        <span class="busy-node" title={props.group.nodeZone ? `${node()} · ${props.group.nodeZone}` : node()}>
          <Icon name="server" /> {t('busy.on_node', { node: node() })}
          <Show when={props.group.nodeZone}>
            <span class="busy-node__zone"> · {props.group.nodeZone}</span>
          </Show>
        </span>
      )}
    </Show>
  );
}

// The same facts as one muted line, for a card that stands for its host.
function CardFacts(props: { group: HostGroup }) {
  const cpu = () => cpuFact(props.group);
  const mem = () => memFact(props.group);
  return (
    <Show when={cpu() || mem() || props.group.node}>
      <div class="busy-card__facts" title={props.group.cpuModel ?? undefined}>
        <NodeLabel group={props.group} />
        <Show when={cpu()}>{(c) => <span title={c().title}><Icon name="microchip" /> {c().text}</span>}</Show>
        <Show when={mem()}>{(m) => <span title={m().title}><Icon name="memory" /> {m().text}</span>}</Show>
      </div>
    </Show>
  );
}

function HostHeader(props: { group: HostGroup }) {
  return (
    <div class="busy-host__head">
      <span class="busy-host__name">
        <Icon name="server" style={{ color: 'var(--text-muted)', 'margin-right': '0.5rem' }} />
        {props.group.hostname}
      </span>
      <span class="badge badge-muted">
        {props.group.processes.length} {t('dashboard.processes').toLowerCase()}
      </span>
      <NodeLabel group={props.group} />
      <HostFacts group={props.group} />
      <span class="badge badge-muted" style={{ 'font-variant-numeric': 'tabular-nums' }}>
        {t('table.busy')} {props.group.busy} / {props.group.concurrency}
      </span>
    </div>
  );
}

interface CardProps {
  proc: Process;
  // Set when the card stands for its whole host (a pod): the card then
  // carries the hostname and the host's facts, with no section header.
  host?: HostGroup;
  readOnly: boolean;
  busy: boolean;
  queuesOpen: boolean;
  onToggleQueues: (identity: string) => void;
  onOpen: (identity: string) => void;
  onPrefetch: () => void;
  onSignal: (signal: Signal, identity: string) => void;
}

function ProcessCard(props: CardProps) {
  const proc = () => props.proc;
  const utilization = () => (proc().concurrency > 0 ? (proc().busy / proc().concurrency) * 100 : 0);
  // Re-judged on the shared tick: a process that stops beating keeps its
  // last `beat`, so the poll hands back an unchanged row and nothing else
  // would re-run this.
  const isRecent = () => {
    liveTick();
    return nowSeconds() - proc().beat < 30;
  };
  const sub = () => {
    const parts: string[] = [];
    if (props.host) parts.push(`PID ${proc().pid}`);
    if (proc().tag && proc().tag !== proc().hostname) parts.push(proc().tag!);
    else if (!props.host) parts.push(proc().hostname);
    if (proc().started_at) parts.push(`${t('busy.up_for')} ${formatDuration(nowSeconds() - proc().started_at!)}`);
    return parts.join(' · ');
  };

  return (
    <div
      class="card busy-card row-clickable"
      {...activatable(() => proc().identity && props.onOpen(proc().identity))}
      onPointerEnter={props.onPrefetch}
      onFocus={props.onPrefetch}
    >
      <div class="busy-card__head">
        <div style={{ 'min-width': 0 }}>
          <div class="busy-card__title" title={props.host ? proc().hostname : undefined}>
            {props.host ? proc().hostname : `PID ${proc().pid}`}
          </div>
          <div class="busy-card__sub">{sub()}</div>
        </div>
        <div class="busy-card__flags">
          <Show when={isRecent()}><span class="live-dot" title={t('busy.heartbeat_ok')} /></Show>
          <Show when={proc().leader}>
            <span class="badge badge-accent" title={t('busy.leader_title')}>
              <Icon name="crown" style={{ 'margin-right': '0.3rem' }} />
              {t('busy.leader')}
            </span>
          </Show>
          <Show when={proc().quiet}><span class="badge badge-warning">{t('busy.quiet')}</span></Show>
          <Show when={proc().embedded}><span class="badge badge-muted">{t('busy.embedded')}</span></Show>
        </div>
      </div>

      <div class="busy-card__stats">
        <div>
          <div class="busy-card__label">{t('table.busy')}</div>
          <div class="busy-card__value busy-card__busy">{proc().busy} / {proc().concurrency}</div>
        </div>
        <div>
          <div class="busy-card__label">{t('busy.heartbeat')}</div>
          <div class="busy-card__value" style={{ color: isRecent() ? 'var(--success)' : 'var(--danger)' }}>
            {relativeTime(proc().beat)}
          </div>
        </div>
        <div>
          <div class="busy-card__label">{t('busy.rss')}</div>
          <div class="busy-card__value">{formatKb(proc().rss ?? 0)}</div>
        </div>
      </div>

      <div class="progress-bar-track">
        <div class="progress-bar-fill" style={{ width: `${utilization()}%`, background: utilizationColor(utilization()) }} />
      </div>

      <Show when={props.host}>{(host) => <CardFacts group={host()} />}</Show>

      <QueueChips queues={proc().queues} open={props.queuesOpen} onToggle={() => props.onToggleQueues(proc().identity)} />

      <Show when={!props.readOnly && !proc().embedded}>
        <div class="busy-card__actions" onClick={(e) => e.stopPropagation()}>
          <button class="btn btn-sm" disabled={props.busy} onClick={() => props.onSignal('quiet', proc().identity)}>
            {t('actions.quiet')}
          </button>
          <button
            class="btn btn-sm btn-danger"
            disabled={props.busy}
            onClick={() => props.onSignal('stop', proc().identity)}
          >
            {t('actions.stop')}
          </button>
        </div>
      </Show>
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
    ...(processesQuery() as { queryKey: unknown[]; queryFn: () => Promise<Process[]> }),
    refetchInterval: 5000,
  }));

  // Quiet (SIGTSTP) / stop (SIGTERM) one process by identity, or all when
  // scope is 'all'. The process reacts on its next heartbeat; until then the
  // card shows it quiet (a stopping process stops fetching first), and the
  // refetch after the call replaces the guess.
  const control = useMutation(() => {
    const o = optimistic(
      qc,
      (target: ControlTarget) => [
        {
          queryKey: ['processes'],
          update: (old: Process[]) =>
            old.map((p) => (target.scope === 'all' ? !p.embedded : p.identity === target.identity) ? { ...p, quiet: true } : p),
        },
      ],
      [['processes']],
    );
    return {
      mutationFn: (target: ControlTarget) =>
        post(`${basePath()}/api/busy/${target.signal}`, {
          identity: target.scope === 'all' ? 'all' : target.identity,
        }),
      onMutate: o.onMutate,
      onError: (err: unknown, _t: ControlTarget, ctx: OptimisticContext | undefined) => {
        o.rollback(ctx);
        notifyError(err);
      },
      onSettled: o.onSettled,
    };
  });

  const confirmStop = (scope: string) =>
    window.confirm(t('actions.confirm', { action: t('actions.stop'), scope }));

  const controllable = () => (query.data ?? []).some((p) => !p.embedded);
  // Memos: every card reads these by key, so one rebuild per poll serves all.
  const hosts = createMemo(() => groupByHost(query.data ?? []));
  // A host running several processes (a swarm) gets a section; hosts of one
  // process (a pod each, on Kubernetes) share a single grid of cards.
  // Nodes the heartbeats report, with how many processes run on each. A
  // filter keeps one node's cards; grouping puts each node's cards under its
  // own heading. Both hide away when no process reports a node.
  const [pickedNode, setNodeFilter] = createSignal<string | null>(null);
  const [groupPicked, setByNode] = createSignal(false);
  const nodeCounts = createMemo(() => {
    const counts = new Map<string, number>();
    for (const g of hosts()) if (g.node) counts.set(g.node, (counts.get(g.node) ?? 0) + g.processes.length);
    return counts;
  });
  const nodes = createMemo(() => [...nodeCounts().keys()].sort((a, b) => a.localeCompare(b)), undefined, {
    equals: (a, b) => a.length === b.length && a.every((n, i) => n === b[i]),
  });
  // A filter or grouping outlives the node it named only as long as that node
  // reports: once it is gone (its last pod stopped), every card shows again.
  const nodeFilter = () => {
    const n = pickedNode();
    return n !== null && nodeCounts().has(n) ? n : null;
  };
  const byNode = () => groupPicked() && nodes().length > 0;
  // One pass per poll: each section's swarm hosts and single-process hosts.
  const layout = createMemo(() => {
    const only = nodeFilter();
    const grouped = byNode();
    const out = new Map<string, { swarm: HostGroup[]; solo: HostGroup[] }>();
    for (const g of hosts()) {
      if (only !== null && g.node !== only) continue;
      const section = grouped ? (g.node ?? '') : '';
      let bucket = out.get(section);
      if (!bucket) out.set(section, (bucket = { swarm: [], solo: [] }));
      (g.processes.length > 1 ? bucket.swarm : bucket.solo).push(g);
    }
    return out;
  });
  const sections = createMemo(() =>
    [...layout().keys()].sort((a, b) => (a === '' ? 1 : b === '' ? -1 : a.localeCompare(b))),
  );
  const signal = (sig: Signal, identity: string) => {
    if (sig === 'stop' && !confirmStop(t('actions.scope_this_process'))) return;
    control.mutate({ signal: sig, scope: 'one', identity });
  };
  const procById = createMemo(() => new Map((query.data ?? []).map((p) => [p.identity, p])));
  const hostByName = createMemo(() => new Map(hosts().map((g) => [g.key, g])));
  // A row a poll just dropped can be read once more before its card is
  // disposed; it keeps its last value for that read.
  const latest = <T,>(read: () => T | undefined) => createMemo<T>((prev) => read() ?? prev, read() as T);
  const card = (identity: string, hostname?: string) => {
    const proc = latest(() => procById().get(identity));
    const host = hostname ? latest(() => hostByName().get(hostname)) : undefined;
    return (
      <ProcessCard
        proc={proc()}
        host={host?.()}
        readOnly={readOnly()}
        busy={control.isPending}
        queuesOpen={openQueues().has(identity)}
        onToggleQueues={toggleQueues}
        onOpen={setSelected}
        onPrefetch={prefetchWorkers}
        onSignal={signal}
      />
    );
  };
  const prefetchWorkers = () => prefetch(qc, WORKERS_KEY, fetchWorkers, 5000);
  const [openQueues, setOpenQueues] = createSignal<ReadonlySet<string>>(new Set());
  const toggleQueues = (identity: string) => {
    const next = new Set(openQueues());
    if (!next.delete(identity)) next.add(identity);
    setOpenQueues(next);
  };
  const selectedProc = () => (query.data ?? []).find((p) => p.identity === selected()) ?? null;

  return (
    <Switch>
      <Match when={query.isPending}>
        <div>
          <PageHeader icon="gears" title={t('nav.busy')} summary={t('summaries.busy')} />
          <SkeletonCards count={6} />
        </div>
      </Match>
      {/* Gate on the payload, not isError: a failed background poll flips isError
          while the last good payload is still cached. RefreshError says so inline. */}
      <Match when={!query.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={query.data}>
        {(data) => (
          <div>
            <PageHeader icon="gears" title={t('nav.busy')} summary={t('summaries.busy')}>
              <div style={{ display: 'flex', 'flex-wrap': 'wrap', 'align-items': 'center', gap: '0.6rem' }}>
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
            <RefreshError when={query.isError} />

            <Show when={data().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              {/* Keyed by hostname and identity (strings): every poll rebuilds
                  the row objects, and keying on those would remount each card,
                  folding open queue lists and dropping focus; keying on position
                  would move a focused Stop button onto another worker. */}
              <Show when={nodes().length > 0}>
                <div class="busy-nodes" role="group" aria-label={t('busy.nodes')}>
                  <button
                    type="button"
                    class="chip"
                    aria-pressed={nodeFilter() === null}
                    onClick={() => setNodeFilter(null)}
                  >
                    {t('busy.all_nodes')}
                  </button>
                  <For each={nodes()}>
                    {(node) => (
                      <button
                        type="button"
                        class="chip"
                        aria-pressed={nodeFilter() === node}
                        onClick={() => setNodeFilter(nodeFilter() === node ? null : node)}
                      >
                        <Icon name="server" /> {node} <span class="busy-nodes__count">{nodeCounts().get(node)}</span>
                      </button>
                    )}
                  </For>
                  <label class="busy-nodes__group">
                    <input type="checkbox" checked={byNode()} onChange={(e) => setByNode(e.currentTarget.checked)} />
                    {t('busy.group_by_node')}
                  </label>
                </div>
              </Show>
              <For each={sections()}>
                {(section) => (
                  <section class={byNode() ? 'busy-node-section' : undefined}>
                    <Show when={byNode()}>
                      <h2 class="busy-node-section__title">
                        <Icon name="server" /> {section === '' ? t('busy.no_node') : section}
                      </h2>
                    </Show>
                  <For each={layout().get(section)?.swarm.map((g) => g.key) ?? []}>
                    {(name) => {
                      const group = latest(() => hostByName().get(name));
                      return (
                        <section class="busy-host">
                          <HostHeader group={group()} />
                          <div class="busy-grid">
                            <For each={group().processes.map((p) => p.identity)}>{(id) => card(id)}</For>
                          </div>
                        </section>
                      );
                    }}
                  </For>
                  <Show when={(layout().get(section)?.solo.length ?? 0) > 0}>
                    <div class="busy-grid">
                      <For each={layout().get(section)!.solo.map((g) => g.processes[0].identity)}>
                        {(id) => card(id, hostKey(procById().get(id)!))}
                      </For>
                    </div>
                  </Show>
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

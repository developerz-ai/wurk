import { useQuery, useMutation, useQueryClient } from '@tanstack/solid-query';
import { onMount, For, Show, Switch, Match, type JSX } from 'solid-js';
import { A, useParams } from '@solidjs/router';
import { t } from '../i18n';
import { formatNumber, relativeTime, truncate } from '../utils';
import { SkeletonCards } from '../components/Skeleton';
import { basePath } from '../basePath';
import { getJSON, post } from '../http';
import { notifyError } from '../toast';
import { useMeta } from '../hooks/useMeta';
import { FlowStateBadge, flowStateColor, flowStateLabel, type NodeState } from '../components/FlowState';
import type { FlowRow } from './Flows';

interface FlowNodeData {
  index: number;
  name: string | null;
  klass: string;
  queue: string;
  jid: string;
  bid: string;
  state: NodeState;
  depends_on: number[];
  dependents: number[];
  remaining: number;
  piped: boolean;
  error: string | null;
}

interface FlowDetailData extends FlowRow {
  dead_nodes: number[];
  nodes: FlowNodeData[];
}

// Graph geometry, in SVG user units. Fixed rather than measured: a laid-out DAG
// needs every box's position before the first edge can be drawn, and measuring
// rendered text to get there would mean a second paint on every poll.
const NODE_W = 176;
const NODE_H = 54;
const COL_GAP = 60;
const ROW_GAP = 14;
const PAD = 10;

interface Placed {
  node: FlowNodeData;
  x: number;
  y: number;
}

interface Graph {
  placed: Placed[];
  at: Map<number, Placed>;
  width: number;
  height: number;
}

/**
 * Column per dependency level, row per node within it.
 *
 * Levels come from a Kahn walk rather than declaration order, because
 * `depends_on:` accepts a forward reference — a node may be declared before the
 * ones it waits for. A node the walk never reaches keeps level 0 and is still
 * drawn: the builder refuses a cycle long before anything is persisted, so that
 * can only happen to a payload that is already wrong, and losing a node from
 * the picture is a worse way to say so than misplacing one.
 */
export function layoutFlow(nodes: FlowNodeData[]): Graph {
  const byIndex = new Map(nodes.map((n) => [n.index, n]));
  const level = new Map(nodes.map((n) => [n.index, 0]));
  const indegree = new Map(nodes.map((n) => [n.index, n.depends_on.filter((d) => byIndex.has(d)).length]));

  const ready = nodes.filter((n) => indegree.get(n.index) === 0).map((n) => n.index);
  for (let head = 0; head < ready.length; head++) {
    const from = ready[head];
    for (const to of byIndex.get(from)!.dependents) {
      if (!byIndex.has(to)) continue;
      level.set(to, Math.max(level.get(to)!, level.get(from)! + 1));
      const left = indegree.get(to)! - 1;
      indegree.set(to, left);
      if (left === 0) ready.push(to);
    }
  }

  const rows = new Map<number, number>();
  const placed = nodes.map((node) => {
    const col = level.get(node.index)!;
    const row = rows.get(col) ?? 0;
    rows.set(col, row + 1);
    return { node, x: PAD + col * (NODE_W + COL_GAP), y: PAD + row * (NODE_H + ROW_GAP) };
  });

  const cols = rows.size;
  const tallest = Math.max(0, ...rows.values());
  return {
    placed,
    at: new Map(placed.map((p) => [p.node.index, p])),
    width: cols === 0 ? 0 : PAD * 2 + cols * NODE_W + (cols - 1) * COL_GAP,
    height: tallest === 0 ? 0 : PAD * 2 + tallest * NODE_H + (tallest - 1) * ROW_GAP,
  };
}

// Horizontal cubic between the right edge of a dependency and the left edge of
// its dependent. The control offset is half the gap, floored so that neighbours
// in adjacent columns still curve instead of kinking.
function edgePath(from: Placed, to: Placed): string {
  const x1 = from.x + NODE_W;
  const y1 = from.y + NODE_H / 2;
  const x2 = to.x;
  const y2 = to.y + NODE_H / 2;
  const bend = Math.max(20, (x2 - x1) / 2);
  return `M${x1},${y1} C${x1 + bend},${y1} ${x2 - bend},${y2} ${x2},${y2}`;
}

function nodeLabel(node: FlowNodeData): string {
  return node.name ? `${node.name} · #${node.index}` : `#${node.index}`;
}

function Field(props: { label: string; children: JSX.Element }) {
  return (
    <div style={{ display: 'flex', 'flex-direction': 'column', gap: '2px' }}>
      <span style={{ 'font-size': '11px', color: 'var(--text-muted)', 'text-transform': 'uppercase', 'letter-spacing': '0.04em' }}>
        {props.label}
      </span>
      <span style={{ 'font-variant-numeric': 'tabular-nums' }}>{props.children}</span>
    </div>
  );
}

function FlowGraph(props: { nodes: FlowNodeData[] }) {
  const graph = () => layoutFlow(props.nodes);
  return (
    <div class="table-wrapper" style={{ 'overflow-x': 'auto', padding: '0.5rem' }}>
      <svg
        width={graph().width}
        height={graph().height}
        viewBox={`0 0 ${graph().width} ${graph().height}`}
        role="img"
        aria-label={t('flows.graph')}
        style={{ display: 'block' }}
      >
        <For each={graph().placed}>
          {(to) => (
            <For each={to.node.depends_on}>
              {(from) => (
                <Show when={graph().at.get(from)}>
                  {(source) => (
                    <path
                      d={edgePath(source(), to)}
                      fill="none"
                      stroke="var(--border)"
                      stroke-width="1.5"
                    />
                  )}
                </Show>
              )}
            </For>
          )}
        </For>
        <For each={graph().placed}>
          {(p) => (
            <g>
              <title>{`${p.node.klass} — ${flowStateLabel(p.node.state)} — ${p.node.jid}`}</title>
              <rect
                x={p.x}
                y={p.y}
                width={NODE_W}
                height={NODE_H}
                rx="8"
                fill="var(--surface)"
                stroke={flowStateColor(p.node.state)}
                stroke-width="1.5"
              />
              <circle cx={p.x + 15} cy={p.y + NODE_H / 2} r="4" fill={flowStateColor(p.node.state)} />
              <text x={p.x + 28} y={p.y + 23} fill="var(--text)" font-size="12">
                {truncate(p.node.klass, 18)}
              </text>
              <text x={p.x + 28} y={p.y + 39} fill="var(--text-muted)" font-size="10.5" font-family="var(--font-mono)">
                {p.node.piped ? `${nodeLabel(p.node)} · ${t('flows.piped')}` : nodeLabel(p.node)}
              </text>
            </g>
          )}
        </For>
      </svg>
    </div>
  );
}

function NodeTable(props: { nodes: FlowNodeData[] }) {
  return (
    <div class="table-wrapper">
      <table>
        <thead>
          <tr>
            <th>#</th>
            <th>{t('table.class')}</th>
            <th>{t('table.status')}</th>
            <th>{t('flows.depends_on')}</th>
            <th>{t('table.queue')}</th>
            <th>{t('table.jid')}</th>
            <th>{t('table.error')}</th>
          </tr>
        </thead>
        <tbody>
          <For each={props.nodes}>
            {(node) => (
              <tr>
                <td style={{ 'font-family': 'monospace', 'font-size': '12px' }}>{nodeLabel(node)}</td>
                <td title={node.klass}>{truncate(node.klass, 34)}</td>
                <td><FlowStateBadge state={node.state} /></td>
                <td style={{ 'font-variant-numeric': 'tabular-nums' }}>
                  {node.depends_on.length > 0 ? node.depends_on.map((d) => `#${d}`).join(', ') : '—'}
                </td>
                <td>{node.queue}</td>
                <td style={{ 'font-family': 'monospace', 'font-size': '12px' }}>
                  {/* The node's batch is what carries its completion, and the
                      batch page is where its jobs already render. */}
                  <A href={`/batches/${node.bid}`} title={node.jid}>{truncate(node.jid, 12)}</A>
                </td>
                <td style={{ color: node.error ? 'var(--danger)' : undefined }} title={node.error ?? ''}>
                  {node.error ? truncate(node.error, 48) : '—'}
                </td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </div>
  );
}

export default function FlowDetail() {
  const params = useParams();
  const fid = () => params.fid ?? '';
  const qc = useQueryClient();
  const meta = useMeta();

  onMount(() => {
    document.title = `${t('nav.flows')} — Wurk`;
  });

  const q = useQuery<FlowDetailData>(() => ({
    queryKey: ['flow', fid()],
    queryFn: () => getJSON<FlowDetailData>(`${basePath()}/api/flows/${encodeURIComponent(fid())}`),
    refetchInterval: 5000,
  }));

  // The kill switch. Only a flow that is still supposed to move can be
  // abandoned — a succeeded or already-abandoned one is not stuck — which is
  // the same claim the Lua script makes, so the button is hidden exactly when
  // the call would be a no-op.
  const abandon = useMutation(() => ({
    mutationFn: () => post(`${basePath()}/api/flows/${encodeURIComponent(fid())}/abandon`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['flow', fid()] }),
    onError: notifyError,
  }));

  const confirmAbandon = () =>
    window.confirm(t('actions.confirm', { action: t('flows.abandon'), scope: fid() })) && abandon.mutate();

  return (
    <Switch>
      <Match when={q.isPending}>
        <div>
          <div class="section-header" style={{ gap: '0.75rem' }}>
            <A href="/flows" class="btn btn-sm">← {t('nav.flows')}</A>
          </div>
          <div style={{ 'margin-top': '1rem' }}>
            <SkeletonCards count={8} />
          </div>
        </div>
      </Match>
      <Match when={q.isError || !q.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={q.data}>
        {(data) => {
          const killable = () =>
            !(meta.data?.read_only ?? false) && (data().state === 'running' || data().state === 'failed');
          return (
            <div>
              <div class="section-header" style={{ gap: '0.75rem' }}>
                <A href="/flows" class="btn btn-sm">← {t('nav.flows')}</A>
                <h1 class="page-title" style={{ margin: 0, 'font-family': 'monospace', 'font-size': '16px' }}>
                  {data().fid}
                </h1>
                <FlowStateBadge state={data().state} />
                <Show when={killable()}>
                  <button
                    class="btn btn-sm btn-danger"
                    title={t('flows.abandon_hint')}
                    disabled={abandon.isPending}
                    onClick={confirmAbandon}
                  >
                    {t('flows.abandon')}
                  </button>
                </Show>
              </div>

              <div
                style={{
                  display: 'grid',
                  'grid-template-columns': 'repeat(auto-fill, minmax(140px, 1fr))',
                  gap: '1rem',
                  'margin-top': '1rem',
                }}
              >
                <Field label={t('flows.nodes')}>{formatNumber(data().total)}</Field>
                <Field label={t('flows.succeeded')}>{formatNumber(data().succeeded)}</Field>
                <Field label={t('table.pending')}>{formatNumber(data().pending)}</Field>
                <Field label={t('flows.depth')}>{formatNumber(data().depth)}</Field>
                <Field label={t('flows.width')}>{formatNumber(data().width)}</Field>
                <Field label={t('table.created')}>{data().created_at ? relativeTime(data().created_at!) : '—'}</Field>
                <Show when={data().finished_at}>
                  <Field label={t('flows.finished')}>{relativeTime(data().finished_at!)}</Field>
                </Show>
                <Show when={data().failed_at}>
                  <Field label={t('table.failed_at')}>{relativeTime(data().failed_at!)}</Field>
                </Show>
                <Show when={data().abandoned_at}>
                  <Field label={t('flows.state.abandoned')}>{relativeTime(data().abandoned_at!)}</Field>
                </Show>
                <Show when={data().dead_nodes.length > 0}>
                  <Field label={t('flows.blocked')}>{data().dead_nodes.map((i) => `#${i}`).join(', ')}</Field>
                </Show>
              </div>

              {/* Abandonment releases the node records along with the batches
                  they point at, so an abandoned flow has a header and nothing
                  else. Saying so beats an empty table that reads like a bug. */}
              <Show
                when={data().nodes.length > 0}
                fallback={<div class="empty-state" style={{ 'margin-top': '1.5rem' }}>{t('flows.released')}</div>}
              >
                <h2 style={{ 'font-size': '14px', margin: '1.5rem 0 0.5rem' }}>{t('flows.graph')}</h2>
                <FlowGraph nodes={data().nodes} />
                <h2 style={{ 'font-size': '14px', margin: '1.5rem 0 0.5rem' }}>{t('flows.nodes')}</h2>
                <NodeTable nodes={data().nodes} />
              </Show>
            </div>
          );
        }}
      </Match>
    </Switch>
  );
}

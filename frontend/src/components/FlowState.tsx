import { t } from '../i18n';

// A flow's four states and a node's five, in one place because the two pages
// render both and the graph paints a node the same colour the badge gives it.
// `succeeded` is deliberately the same word at both levels: a flow succeeds
// when every node has.
export type FlowState = 'running' | 'succeeded' | 'failed' | 'abandoned';
export type NodeState = 'waiting' | 'enqueued' | 'succeeded' | 'dead' | 'broken';
export type AnyFlowState = FlowState | NodeState;

const VARIANT: Record<AnyFlowState, string> = {
  running: 'badge-warning',
  succeeded: 'badge-success',
  // A failed flow is recoverable — retrying the dead job out of the morgue
  // resumes it — but it is not moving on its own, which is what danger says.
  failed: 'badge-danger',
  abandoned: 'badge-muted',
  waiting: 'badge-muted',
  enqueued: 'badge-accent',
  dead: 'badge-danger',
  broken: 'badge-danger',
};

// Token references, never literals: the graph is SVG, and SVG presentation
// attributes resolve `var()` exactly as CSS declarations do, so a theme flip
// repaints it with no JS.
const COLOR: Record<AnyFlowState, string> = {
  running: 'var(--warning)',
  succeeded: 'var(--success)',
  failed: 'var(--danger)',
  abandoned: 'var(--mono-4)',
  waiting: 'var(--mono-4)',
  enqueued: 'var(--accent)',
  dead: 'var(--danger)',
  broken: 'var(--danger)',
};

export function flowStateColor(state: AnyFlowState): string {
  return COLOR[state];
}

export function flowStateLabel(state: AnyFlowState): string {
  return t(`flows.state.${state}`);
}

export function FlowStateBadge(props: { state: AnyFlowState }) {
  return <span class={`badge ${VARIANT[props.state]}`}>{flowStateLabel(props.state)}</span>;
}

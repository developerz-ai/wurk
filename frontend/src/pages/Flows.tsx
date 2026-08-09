import { useQuery } from '@tanstack/solid-query';
import { onMount, For, Switch, Match, Show } from 'solid-js';
import { A } from '@solidjs/router';
import { Pagination } from '../components/Pagination';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { usePageParam } from '../hooks/usePageParam';
import { useResetPageOnEmpty } from '../hooks/useResetPageOnEmpty';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { formatNumber, relativeTime, truncate } from '../utils';
import { SkeletonTable } from '../components/Skeleton';
import { basePath } from '../basePath';
import { getJSON } from '../http';
import { FlowStateBadge, type FlowState } from '../components/FlowState';

export interface FlowRow {
  fid: string;
  state: FlowState;
  total: number;
  pending: number;
  succeeded: number;
  depth: number;
  width: number;
  created_at: number | null;
  finished_at: number | null;
  failed_at: number | null;
  abandoned_at: number | null;
}

interface FlowsResponse {
  total: number;
  page: number;
  count: number;
  flows: FlowRow[];
}

const PAGE_SIZE = 25;

const SORT: Accessors<FlowRow> = {
  fid: (f) => f.fid,
  state: (f) => f.state,
  nodes: (f) => f.total,
  pending: (f) => f.pending,
  progress: (f) => (f.total > 0 ? f.succeeded / f.total : 0),
  depth: (f) => f.depth,
  created: (f) => f.created_at ?? null,
};

export default function Flows() {
  const [page, setPage] = usePageParam();

  onMount(() => {
    document.title = `${t('nav.flows')} — Wurk`;
  });

  const q = useQuery<FlowsResponse>(() => ({
    queryKey: ['flows', page()],
    queryFn: () => getJSON<FlowsResponse>(`${basePath()}/api/flows?page=${page() - 1}&count=${PAGE_SIZE}`),
    refetchInterval: 5000,
  }));

  useResetPageOnEmpty(page, setPage, () => !q.isPending && !!q.data, () => (q.data?.flows.length ?? 0) === 0);

  const { sorted, sort, toggle } = useSort(() => q.data?.flows ?? [], SORT);

  return (
    <Switch>
      <Match when={q.isPending}>
        <div>
          <PageHeader icon="fa-diagram-project" title={t('nav.flows')} summary={t('summaries.flows')} />
          <SkeletonTable rows={8} cols={7} />
        </div>
      </Match>
      <Match when={q.isError || !q.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={q.data}>
        {(data) => (
          <div>
            <PageHeader icon="fa-diagram-project" title={t('nav.flows')} summary={t('summaries.flows')}>
              <span class="badge badge-accent">{formatNumber(data().total)}</span>
            </PageHeader>

            <Show when={sorted().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <div class="table-wrapper">
                <table>
                  <thead>
                    <tr>
                      <SortableTh label={t('table.fid')} sortKey="fid" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.status')} sortKey="state" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('flows.nodes')} sortKey="nodes" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.pending')} sortKey="pending" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.progress')} sortKey="progress" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('flows.depth')} sortKey="depth" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.created')} sortKey="created" sort={sort()} onSort={toggle} />
                    </tr>
                  </thead>
                  <tbody>
                    <For each={sorted()}>
                      {(flow) => {
                        const pct = flow.total > 0 ? (flow.succeeded / flow.total) * 100 : 0;
                        // A failed flow's bar is the honest count of what did
                        // succeed — the failure is already stated in the badge
                        // beside it, and zeroing the bar would hide how far a
                        // recoverable flow actually got.
                        const failing = flow.state === 'failed' || flow.state === 'abandoned';
                        return (
                          <tr>
                            <td style={{ 'font-family': 'monospace', 'font-size': '12px' }}>
                              <A href={`/flows/${flow.fid}`} title={flow.fid}>
                                {truncate(flow.fid, 14)}
                              </A>
                            </td>
                            <td><FlowStateBadge state={flow.state} /></td>
                            <td>{formatNumber(flow.total)}</td>
                            <td style={{ color: flow.pending > 0 ? 'var(--warning)' : 'var(--success)' }}>
                              {formatNumber(flow.pending)}
                            </td>
                            <td style={{ width: '100px' }}>
                              <div style={{ display: 'flex', 'align-items': 'center', gap: '0.5rem' }}>
                                <div class="progress-bar-track" style={{ flex: 1 }}>
                                  <div
                                    class="progress-bar-fill"
                                    style={{
                                      width: `${pct}%`,
                                      background: failing ? 'var(--danger)' : 'var(--success)',
                                    }}
                                  />
                                </div>
                                <span style={{ 'font-size': '11px', color: 'var(--text-muted)', 'min-width': '32px' }}>
                                  {Math.round(pct)}%
                                </span>
                              </div>
                            </td>
                            <td>{formatNumber(flow.depth)}</td>
                            <td>{flow.created_at ? relativeTime(flow.created_at) : '—'}</td>
                          </tr>
                        );
                      }}
                    </For>
                  </tbody>
                </table>
              </div>
              <Pagination page={page()} total={data().total} count={PAGE_SIZE} onChange={setPage} />
            </Show>
          </div>
        )}
      </Match>
    </Switch>
  );
}

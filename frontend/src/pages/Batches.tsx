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
import { relativeTime, truncate } from '../utils';
import { SkeletonTable } from '../components/Skeleton';
import { basePath } from '../basePath';
import { getJSON } from '../http';

interface Batch {
  bid: string;
  description: string | null;
  total: number;
  pending: number;
  failures: number;
  complete: boolean;
  created_at: number | null;
  complete_at: number | null;
}

interface BatchesResponse {
  total: number;
  page: number;
  count: number;
  batches: Batch[];
}

const PAGE_SIZE = 25;

const SORT: Accessors<Batch> = {
  bid: (b) => b.bid,
  description: (b) => b.description ?? '',
  total: (b) => b.total,
  pending: (b) => b.pending,
  failures: (b) => b.failures,
  progress: (b) => (b.total > 0 ? (b.total - b.pending) / b.total : 0),
  created: (b) => b.created_at ?? null,
};

export default function Batches() {
  const [page, setPage] = usePageParam();

  onMount(() => {
    document.title = `${t('nav.batches')} — Wurk`;
  });

  const q = useQuery<BatchesResponse>(() => ({
    queryKey: ['batches', page()],
    queryFn: () =>
      getJSON<BatchesResponse>(`${basePath()}/api/batches?page=${page() - 1}&count=${PAGE_SIZE}`),
  }));

  useResetPageOnEmpty(page, setPage, () => !q.isPending && !!q.data, () => (q.data?.batches.length ?? 0) === 0);

  const { sorted, sort, toggle } = useSort(() => q.data?.batches ?? [], SORT);

  return (
    <Switch>
      <Match when={q.isPending}>
        <div>
          <PageHeader icon="fa-table-cells-large" title={t('nav.batches')} summary={t('summaries.batches')} />
          <SkeletonTable rows={8} cols={7} />
        </div>
      </Match>
      <Match when={q.isError || !q.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={q.data}>
        {(data) => (
          <div>
            <PageHeader icon="fa-table-cells-large" title={t('nav.batches')} summary={t('summaries.batches')}>
              <span class="badge badge-accent">{data().total.toLocaleString()}</span>
            </PageHeader>

            <Show when={sorted().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <div class="table-wrapper">
                <table>
                  <thead>
                    <tr>
                      <SortableTh label={t('table.bid')} sortKey="bid" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.description')} sortKey="description" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.total')} sortKey="total" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.pending')} sortKey="pending" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.failures')} sortKey="failures" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.progress')} sortKey="progress" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.created')} sortKey="created" sort={sort()} onSort={toggle} />
                    </tr>
                  </thead>
                  <tbody>
                    <For each={sorted()}>
                      {(batch) => {
                        const done = batch.total - batch.pending;
                        const pct = batch.total > 0 ? (done / batch.total) * 100 : 0;
                        return (
                          <tr>
                            <td style={{ 'font-family': 'monospace', 'font-size': '12px' }}>
                              <A href={`/batches/${batch.bid}`} title={batch.bid}>
                                {truncate(batch.bid, 14)}
                              </A>
                            </td>
                            <td title={batch.description ?? ''}>{truncate(batch.description ?? '—', 40)}</td>
                            <td>{batch.total.toLocaleString()}</td>
                            <td style={{ color: batch.pending > 0 ? 'var(--warning)' : 'var(--success)' }}>
                              {batch.pending.toLocaleString()}
                            </td>
                            <td style={{ color: batch.failures > 0 ? 'var(--danger)' : undefined }}>
                              {batch.failures.toLocaleString()}
                            </td>
                            <td style={{ width: '100px' }}>
                              <div style={{ display: 'flex', 'align-items': 'center', gap: '0.5rem' }}>
                                <div class="progress-bar-track" style={{ flex: 1 }}>
                                  <div
                                    class="progress-bar-fill"
                                    style={{
                                      width: `${pct}%`,
                                      background: batch.failures > 0 ? 'var(--danger)' : 'var(--success)',
                                    }}
                                  />
                                </div>
                                <span style={{ 'font-size': '11px', color: 'var(--text-muted)', 'min-width': '32px' }}>
                                  {Math.round(pct)}%
                                </span>
                              </div>
                            </td>
                            <td>{batch.created_at ? relativeTime(batch.created_at) : '—'}</td>
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

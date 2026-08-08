import { useQuery } from '@tanstack/solid-query';
import { createSignal, onMount, For, Show, Switch, Match } from 'solid-js';
import { Pagination } from '../components/Pagination';
import { ArgsValue } from '../components/ArgsValue';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs, hoverTime } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';
import JobSetActionBar, { type ActionDef } from '../components/JobSetActionBar';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { usePageParam } from '../hooks/usePageParam';
import { useMeta } from '../hooks/useMeta';
import { useSelection } from '../hooks/useSelection';
import { useJobSetActions, entryKey } from '../hooks/useJobSetActions';
import { useResetPageOnEmpty } from '../hooks/useResetPageOnEmpty';
import { SkeletonTable } from '../components/Skeleton';
import { FilterBox } from '../components/FilterBox';
import { basePath } from '../basePath';
import { getJSON } from '../http';

interface RetryEntry {
  jid: string;
  klass: string;
  args: unknown;
  error_class: string | null;
  error_message: string | null;
  // `at` is the next-retry epoch (the sorted-set score); see api/serializers.rb#sorted_entry.
  at: number;
  retry_count: number;
  score: number;
  queue?: string;
  enqueued_at?: number | null;
  error_backtrace?: string[] | null;
}

interface RetriesResponse {
  total: number;
  page: number;
  count: number;
  entries: RetryEntry[];
}

const PAGE_SIZE = 25;

const SORT: Accessors<RetryEntry> = {
  klass: (e) => e.klass,
  args: (e) => formatArgs(e.args),
  error_class: (e) => e.error_class,
  error_message: (e) => e.error_message,
  retry_count: (e) => e.retry_count,
  at: (e) => e.at,
};

const BULK: ActionDef[] = [
  { cmd: 'retry', label: t('actions.retry') },
  { cmd: 'delete', label: t('actions.delete'), danger: true },
  { cmd: 'kill', label: t('actions.kill'), danger: true },
];
const ALL: ActionDef[] = [
  { cmd: 'retry', label: t('actions.retry') },
  { cmd: 'kill', label: t('actions.kill'), danger: true },
  { cmd: 'delete', label: t('actions.delete'), danger: true },
];

export default function Retries() {
  const [page, setPage] = usePageParam();
  const [filter, setFilter] = createSignal('');
  const [selected, setSelected] = createSignal<JobEntry | null>(null);
  const [selectedKey, setSelectedKey] = createSignal<string | null>(null);
  const meta = useMeta();
  const readOnly = () => meta.data?.read_only ?? false;
  const sel = useSelection();
  const { single, bulk, all } = useJobSetActions('retries');
  const pending = () => single.isPending || bulk.isPending || all.isPending;

  onMount(() => {
    document.title = `${t('nav.retries')} — Wurk`;
  });

  // Filter narrows the server-side substr scan (klass/jid), so a new term can
  // easily leave the current page past the end of the filtered set — reset to
  // page 1 whenever it changes, same as any other query-key-changing filter.
  const onFilterChange = (v: string) => {
    setFilter(v);
    setPage(1);
  };

  const query = useQuery<RetriesResponse>(() => ({
    queryKey: ['retries', page(), filter()],
    queryFn: () =>
      getJSON<RetriesResponse>(
        `${basePath()}/api/retries?page=${page() - 1}&count=${PAGE_SIZE}&substr=${encodeURIComponent(filter())}`,
      ),
  }));

  useResetPageOnEmpty(page, setPage, () => !query.isPending && !!query.data, () => (query.data?.entries.length ?? 0) === 0);

  const { sorted, sort, toggle } = useSort(() => query.data?.entries ?? [], SORT);
  const pageKeys = () => sorted().map(entryKey);
  const allChecked = () => pageKeys().length > 0 && pageKeys().every((k) => sel.selected().has(k));

  return (
    <Switch>
      <Match when={query.isPending}>
        <div>
          <PageHeader icon="fa-rotate-right" title={t('nav.retries')} summary={t('summaries.retries')} />
          <SkeletonTable rows={8} cols={7} />
        </div>
      </Match>
      <Match when={query.isError || !query.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={query.data}>
        {(data) => (
          <div>
            <PageHeader icon="fa-rotate-right" title={t('nav.retries')} summary={t('summaries.retries')}>
              <span class="badge badge-warning">{data().total.toLocaleString()}</span>
            </PageHeader>

            <FilterBox value={filter()} onChange={onFilterChange} placeholder={t('common.filter_placeholder')} />

            <Show when={sorted().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <>
                <Show when={!readOnly()}>
                  <JobSetActionBar
                    bulk={BULK}
                    all={ALL}
                    selectedCount={sel.count()}
                    total={data().total}
                    pending={pending()}
                    onBulk={(cmd) => bulk.mutate({ keys: [...sel.selected()], cmd }, { onSuccess: sel.clear })}
                    onAll={(cmd) => all.mutate(cmd, { onSuccess: sel.clear })}
                  />
                </Show>
                <div class="table-wrapper">
                  <table>
                    <thead>
                      <tr>
                        <Show when={!readOnly()}>
                          <th class="row-action">
                            <input type="checkbox" checked={allChecked()} onChange={() => sel.toggleAll(pageKeys())} aria-label="Select all" />
                          </th>
                        </Show>
                        <SortableTh label={t('table.class')} sortKey="klass" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.args')} sortKey="args" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.error')} sortKey="error_class" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.message')} sortKey="error_message" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.count')} sortKey="retry_count" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.retry_at')} sortKey="at" sort={sort()} onSort={toggle} />
                      </tr>
                    </thead>
                    <tbody>
                      <For each={sorted()}>
                        {(entry) => {
                          const argsStr = formatArgs(entry.args);
                          const key = entryKey(entry);
                          return (
                            <tr class="row-clickable" onClick={() => { setSelected(entry); setSelectedKey(key); }}>
                              <Show when={!readOnly()}>
                                <td class="row-action" onClick={(e) => e.stopPropagation()}>
                                  <input type="checkbox" checked={sel.selected().has(key)} onChange={() => sel.toggle(key)} aria-label="Select job" />
                                </td>
                              </Show>
                              <td style={{ 'font-weight': 500 }}>{entry.klass}</td>
                              <td><ArgsValue str={argsStr} max={40} /></td>
                              <td title={entry.error_class ?? ''} style={{ color: 'var(--danger)' }}>
                                {truncate(entry.error_class, 30)}
                              </td>
                              <td title={entry.error_message ?? ''}>{truncate(entry.error_message, 50)}</td>
                              <td style={{ color: 'var(--warning)' }}>{entry.retry_count}</td>
                              <td title={hoverTime(entry.at)}>
                                {relativeTime(entry.at)}
                              </td>
                            </tr>
                          );
                        }}
                      </For>
                    </tbody>
                  </table>
                </div>
                <Pagination page={page()} total={data().total} count={PAGE_SIZE} onChange={setPage} />
              </>
            </Show>
            <JobDetailModal
              entry={selected()}
              atLabel={t('table.retry_at')}
              actions={readOnly() ? undefined : BULK}
              pending={single.isPending}
              onAction={(cmd) => {
                const k = selectedKey();
                if (k) single.mutate({ key: k, cmd }, { onSuccess: () => { setSelected(null); setSelectedKey(null); } });
              }}
              onClose={() => { setSelected(null); setSelectedKey(null); }}
            />
          </div>
        )}
      </Match>
    </Switch>
  );
}

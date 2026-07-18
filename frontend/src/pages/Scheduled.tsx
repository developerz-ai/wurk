import { useQuery } from '@tanstack/solid-query';
import { createSignal, onMount, For, Show, Switch, Match } from 'solid-js';
import { Pagination } from '../components/Pagination';
import { ArgsValue } from '../components/ArgsValue';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { usePageParam } from '../hooks/usePageParam';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs, isoTime } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';
import JobSetActionBar, { type ActionDef } from '../components/JobSetActionBar';
import { useMeta } from '../hooks/useMeta';
import { useSelection } from '../hooks/useSelection';
import { useJobSetActions, entryKey } from '../hooks/useJobSetActions';
import { useResetPageOnEmpty } from '../hooks/useResetPageOnEmpty';
import { SkeletonTable } from '../components/Skeleton';
import { FilterBox } from '../components/FilterBox';
import { basePath } from '../basePath';

interface ScheduledEntry {
  jid: string;
  klass: string;
  args: unknown;
  score: number;
  at: number;
  queue?: string;
  enqueued_at?: number | null;
}

interface ScheduledResponse {
  total: number;
  page: number;
  count: number;
  entries: ScheduledEntry[];
}

const PAGE_SIZE = 25;

const SORT: Accessors<ScheduledEntry> = {
  jid: (e) => e.jid,
  klass: (e) => e.klass,
  args: (e) => formatArgs(e.args),
  at: (e) => e.at,
};

const ACTIONS: ActionDef[] = [
  { cmd: 'add_to_queue', label: t('actions.add_to_queue') },
  { cmd: 'delete', label: t('actions.delete'), danger: true },
];

export default function Scheduled() {
  const [page, setPage] = usePageParam();
  const [filter, setFilter] = createSignal('');
  const [selected, setSelected] = createSignal<JobEntry | null>(null);
  const [selectedKey, setSelectedKey] = createSignal<string | null>(null);
  const meta = useMeta();
  const readOnly = () => meta.data?.read_only ?? false;
  const sel = useSelection();
  const { single, bulk, all } = useJobSetActions('scheduled');
  const pending = () => single.isPending || bulk.isPending || all.isPending;

  onMount(() => {
    document.title = `${t('nav.scheduled')} — Wurk`;
  });

  const onFilterChange = (v: string) => {
    setFilter(v);
    setPage(1);
  };

  const query = useQuery<ScheduledResponse>(() => ({
    queryKey: ['scheduled', page(), filter()],
    queryFn: () =>
      fetch(`${basePath()}/api/scheduled?page=${page() - 1}&count=${PAGE_SIZE}&substr=${encodeURIComponent(filter())}`).then(
        (r) => r.json() as Promise<ScheduledResponse>
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
          <PageHeader icon="fa-clock" title={t('nav.scheduled')} summary={t('summaries.scheduled')} />
          <SkeletonTable rows={8} cols={5} />
        </div>
      </Match>
      <Match when={query.isError || !query.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={query.data}>
        {(data) => (
          <div>
            <PageHeader icon="fa-clock" title={t('nav.scheduled')} summary={t('summaries.scheduled')}>
              <span class="badge badge-accent">{data().total.toLocaleString()}</span>
            </PageHeader>

            <FilterBox value={filter()} onChange={onFilterChange} placeholder={t('common.filter_placeholder')} />

            <Show when={sorted().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <>
                <Show when={!readOnly()}>
                  <JobSetActionBar
                    bulk={ACTIONS}
                    all={ACTIONS}
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
                        <SortableTh label={t('table.jid')} sortKey="jid" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.class')} sortKey="klass" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.args')} sortKey="args" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.scheduled_at')} sortKey="at" sort={sort()} onSort={toggle} />
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
                              <td
                                title={entry.jid}
                                style={{ 'font-family': 'monospace', 'font-size': '12px', color: 'var(--text-muted)' }}
                              >
                                {truncate(entry.jid, 12)}
                              </td>
                              <td style={{ 'font-weight': 500 }}>{entry.klass}</td>
                              <td><ArgsValue str={argsStr} max={60} /></td>
                              <td title={isoTime(entry.at)}>
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
              atLabel={t('table.scheduled_at')}
              actions={readOnly() ? undefined : ACTIONS}
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

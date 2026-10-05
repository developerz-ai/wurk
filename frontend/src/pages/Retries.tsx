import { createSignal, onMount, For, Show, Switch, Match } from 'solid-js';
import { Pagination } from '../components/Pagination';
import { ArgsValue } from '../components/ArgsValue';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { formatArgs, formatNumber, hoverTime, relativeTime, truncate } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';
import JobSetActionBar, { type ActionDef } from '../components/JobSetActionBar';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { useParams } from '@solidjs/router';
import { useMeta } from '../hooks/useMeta';
import { useSelection } from '../hooks/useSelection';
import { useJobSetActions, entryKey } from '../hooks/useJobSetActions';
import { useJobSetList, jidFromKey, JOB_SET_PAGE_SIZE } from '../hooks/useJobSetList';
import { SkeletonTable } from '../components/Skeleton';
import { FilterBox } from '../components/FilterBox';

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
  const params = useParams();
  const list = useJobSetList<RetryEntry>('retries', jidFromKey(params.key));
  const query = list.query;
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

  const { sorted, sort, toggle } = useSort(() => query.data?.entries ?? [], SORT);
  const pageKeys = () => sorted().map(entryKey);
  const allChecked = () => pageKeys().length > 0 && pageKeys().every((k) => sel.selected().has(k));

  return (
    <div>
      <PageHeader icon="fa-rotate-right" title={t('nav.retries')} summary={t('summaries.retries')}>
        <Show when={query.data}>{(data) => <span class="badge badge-warning">{formatNumber(data().total)}</span>}</Show>
        <Show when={list.filtered() && list.matching() !== undefined}>
          <span class="badge">{t('common.matching', { n: list.matching()! })}</span>
        </Show>
      </PageHeader>

      <FilterBox value={list.filter()} onChange={list.onFilterChange} placeholder={t('common.filter_placeholder')} />

      <Switch>
        <Match when={query.isPending}>
          <SkeletonTable rows={8} cols={7} />
        </Match>
        <Match when={query.isError || !query.data}>
          <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
        </Match>
        <Match when={query.data}>
          {(data) => (
            <div>
              <Show when={sorted().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
                <>
                  <Show when={!readOnly()}>
                    <JobSetActionBar
                      bulk={BULK}
                      all={ALL}
                      selectedCount={sel.count()}
                      total={data().total}
                      filtered={list.filtered()}
                      matching={list.matching()}
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
                              <input type="checkbox" checked={allChecked()} onChange={() => sel.toggleAll(pageKeys())} aria-label={t('table.select_all')} />
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
                                    <input type="checkbox" checked={sel.selected().has(key)} onChange={() => sel.toggle(key)} aria-label={t('table.select_row')} />
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
                  <Pagination page={list.page()} total={list.pagerTotal()} count={JOB_SET_PAGE_SIZE} maxPage={list.maxPage()} onChange={list.setPage} />
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
    </div>
  );
}

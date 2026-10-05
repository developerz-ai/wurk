import { createSignal, onMount, For, Show, Switch, Match } from 'solid-js';
import { Pagination } from '../components/Pagination';
import { ArgsValue } from '../components/ArgsValue';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { useParams } from '@solidjs/router';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { formatArgs, formatNumber, hoverTime, relativeTime, truncate } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';
import JobSetActionBar, { type ActionDef } from '../components/JobSetActionBar';
import { useMeta } from '../hooks/useMeta';
import { useSelection } from '../hooks/useSelection';
import { useJobSetActions, entryKey } from '../hooks/useJobSetActions';
import { useJobSetList, jidFromKey, JOB_SET_PAGE_SIZE } from '../hooks/useJobSetList';
import { SkeletonTable } from '../components/Skeleton';
import { FilterBox } from '../components/FilterBox';

interface ScheduledEntry {
  jid: string;
  klass: string;
  args: unknown;
  score: number;
  at: number;
  queue?: string;
  enqueued_at?: number | null;
}

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
  const params = useParams();
  const list = useJobSetList<ScheduledEntry>('scheduled', jidFromKey(params.key));
  const query = list.query;
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

  const { sorted, sort, toggle } = useSort(() => query.data?.entries ?? [], SORT);
  const pageKeys = () => sorted().map(entryKey);
  const allChecked = () => pageKeys().length > 0 && pageKeys().every((k) => sel.selected().has(k));

  return (
    <div>
      <PageHeader icon="fa-clock" title={t('nav.scheduled')} summary={t('summaries.scheduled')}>
        <Show when={query.data}>{(data) => <span class="badge badge-accent">{formatNumber(data().total)}</span>}</Show>
        <Show when={list.filtered() && list.matching() !== undefined}>
          <span class="badge">{t('common.matching', { n: list.matching()! })}</span>
        </Show>
      </PageHeader>

      <FilterBox value={list.filter()} onChange={list.onFilterChange} placeholder={t('common.filter_placeholder')} />

      <Switch>
        <Match when={query.isPending}>
          <SkeletonTable rows={8} cols={5} />
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
                      bulk={ACTIONS}
                      all={ACTIONS}
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
                                    <input type="checkbox" checked={sel.selected().has(key)} onChange={() => sel.toggle(key)} aria-label={t('table.select_row')} />
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
    </div>
  );
}

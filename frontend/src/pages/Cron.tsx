import { useQuery, useMutation, useQueryClient } from '@tanstack/solid-query';
import { onMount, createSignal, For, Switch, Match, Show } from 'solid-js';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { SkeletonTable } from '../components/Skeleton';
import Modal from '../components/Modal';
import { relativeTime, hoverTime, truncate } from '../utils';
import { useMeta } from '../hooks/useMeta';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { basePath } from '../basePath';
import { post } from '../http';
import { notifyError } from '../toast';

// Newest-first [fired_at, jid] tuples from GET <mount>/api/cron/:lid/history.
type HistoryEntry = [number, string];

interface CronLoop {
  lid: string;
  schedule: string;
  klass: string;
  queue: string;
  tz: string | null;
  paused: boolean;
  args: unknown[];
  last_fire_at: number | null;
  next_fire_at: number | null;
}

const SORT: Accessors<CronLoop> = {
  schedule: (r) => r.schedule,
  klass: (r) => r.klass,
  queue: (r) => r.queue,
  last_fire: (r) => r.last_fire_at,
  next_fire: (r) => r.next_fire_at,
  status: (r) => (r.paused ? 'paused' : 'active'),
};

export default function Cron() {
  const qc = useQueryClient();
  const meta = useMeta();
  const readOnly = () => meta.data?.read_only ?? false;
  const [historyLoop, setHistoryLoop] = createSignal<CronLoop | null>(null);

  onMount(() => {
    document.title = `${t('nav.cron')} — Wurk`;
  });

  const q = useQuery<CronLoop[]>(() => ({
    queryKey: ['cron'],
    queryFn: () => fetch(`${basePath()}/api/cron`).then((r) => r.json() as Promise<CronLoop[]>),
    refetchInterval: 15000,
  }));

  // pause/unpause/enqueue skip CSRF (see ApiController#skip_forgery_protection).
  const call = (lid: string, action: string) => post(`${basePath()}/api/cron/${lid}/${action}`);

  const setPaused = useMutation(() => ({
    mutationFn: ({ lid, paused }: { lid: string; paused: boolean }) =>
      call(lid, paused ? 'unpause' : 'pause'),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['cron'] }),
    onError: notifyError,
  }));

  const enqueueNow = useMutation(() => ({
    mutationFn: (lid: string) => call(lid, 'enqueue'),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['cron'] }),
    onError: notifyError,
  }));

  // Per-loop run history — fetched on demand when a row opens the modal.
  const historyQ = useQuery<HistoryEntry[]>(() => ({
    queryKey: ['cron-history', historyLoop()?.lid],
    queryFn: () =>
      fetch(`${basePath()}/api/cron/${historyLoop()!.lid}/history`)
        .then((r) => r.json() as Promise<{ history: HistoryEntry[] }>)
        .then((d) => d.history),
    enabled: historyLoop() !== null,
  }));

  const { sorted, sort, toggle } = useSort(() => q.data ?? [], SORT);

  return (
    <Switch>
      <Match when={q.isPending}>
        <div>
          <PageHeader icon="fa-stopwatch" title={t('nav.cron')} summary={t('summaries.cron')} />
          <SkeletonTable rows={8} cols={readOnly() ? 6 : 7} />
        </div>
      </Match>
      <Match when={q.isError || !q.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={q.data}>
        {(data) => (
          <div>
            <PageHeader icon="fa-stopwatch" title={t('nav.cron')} summary={t('summaries.cron')}>
              <span class="badge badge-muted">{data().length}</span>
            </PageHeader>

            <Show when={data().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <div class="table-wrapper">
                <table>
                  <thead>
                    <tr>
                      <SortableTh label={t('table.schedule')} sortKey="schedule" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.class')} sortKey="klass" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.queue')} sortKey="queue" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('cron.last_fire')} sortKey="last_fire" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('cron.next_fire')} sortKey="next_fire" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.status')} sortKey="status" sort={sort()} onSort={toggle} />
                      <Show when={!readOnly()}><th /></Show>
                    </tr>
                  </thead>
                  <tbody>
                    <For each={sorted()}>
                      {(loop) => (
                        <tr
                          class="row-clickable"
                          onClick={() => setHistoryLoop(loop)}
                        >
                          <td style={{ 'font-family': 'monospace', 'font-size': '12px' }} title={loop.tz ?? undefined}>
                            {loop.schedule}
                          </td>
                          <td title={loop.klass}>{truncate(loop.klass, 32)}</td>
                          <td>{loop.queue}</td>
                          <td style={{ color: 'var(--text-muted)' }}>
                            {loop.last_fire_at ? relativeTime(loop.last_fire_at) : '—'}
                          </td>
                          <td style={{ color: loop.paused ? 'var(--text-muted)' : 'var(--accent)' }}>
                            {loop.paused ? '—' : loop.next_fire_at ? relativeTime(loop.next_fire_at) : '—'}
                          </td>
                          <td>
                            <Show when={loop.paused} fallback={<span class="badge badge-success">{t('dashboard.active')}</span>}>
                              <span class="badge badge-muted">{t('dashboard.paused')}</span>
                            </Show>
                          </td>
                          <Show when={!readOnly()}>
                            <td onClick={(e) => e.stopPropagation()}>
                              <div style={{ display: 'flex', gap: '0.4rem' }}>
                                <button
                                  class="btn btn-sm"
                                  disabled={setPaused.isPending}
                                  onClick={() => setPaused.mutate({ lid: loop.lid, paused: loop.paused })}
                                >
                                  {loop.paused ? t('actions.unpause') : t('actions.pause')}
                                </button>
                                <button
                                  class="btn btn-sm"
                                  disabled={enqueueNow.isPending}
                                  onClick={() => enqueueNow.mutate(loop.lid)}
                                >
                                  {t('actions.enqueue')}
                                </button>
                              </div>
                            </td>
                          </Show>
                        </tr>
                      )}
                    </For>
                  </tbody>
                </table>
              </div>
            </Show>

            <Modal
              open={historyLoop() !== null}
              onClose={() => setHistoryLoop(null)}
              title={
                historyLoop()
                  ? `${t('cron.history_title')} — ${truncate(historyLoop()!.klass, 40)}`
                  : t('cron.history_title')
              }
            >
              <Switch>
                <Match when={historyQ.isPending}>
                  <SkeletonTable rows={6} cols={2} />
                </Match>
                <Match when={historyQ.isError}>
                  <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
                </Match>
                <Match when={!historyQ.data || historyQ.data.length === 0}>
                  <div class="empty-state">{t('cron.no_history')}</div>
                </Match>
                <Match when={historyQ.data}>
                  {(history) => (
                    <div class="table-wrapper">
                      <table>
                        <thead>
                          <tr>
                            <th>{t('cron.fired')}</th>
                            <th>{t('table.jid')}</th>
                          </tr>
                        </thead>
                        <tbody>
                          <For each={history()}>
                            {([firedAt, jid]) => (
                              <tr>
                                <td style={{ color: 'var(--text-muted)' }} title={hoverTime(firedAt)}>
                                  {relativeTime(firedAt)}
                                </td>
                                <td style={{ 'font-family': 'monospace', 'font-size': '12px' }}>{jid}</td>
                              </tr>
                            )}
                          </For>
                        </tbody>
                      </table>
                    </div>
                  )}
                </Match>
              </Switch>
            </Modal>
          </div>
        )}
      </Match>
    </Switch>
  );
}

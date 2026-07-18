import { useQuery, useMutation, useQueryClient } from '@tanstack/solid-query';
import { createSignal, onMount, For, Show, Switch, Match } from 'solid-js';
import { Pagination } from '../components/Pagination';
import { ArgsValue } from '../components/ArgsValue';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { usePageParam } from '../hooks/usePageParam';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs, formatDuration } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';
import Modal from '../components/Modal';
import { Tooltip } from '../components/Tooltip';
import { useMeta } from '../hooks/useMeta';
import { SkeletonTable } from '../components/Skeleton';
import { basePath } from '../basePath';
import { post } from '../http';
import { notifyError } from '../toast';

interface QueueSummary {
  name: string;
  size: number;
  latency: number;
  paused: boolean;
}

interface QueueJob {
  jid: string;
  class: string;
  args: unknown;
  created_at: number;
  enqueued_at: number;
  score: number;
}

interface QueueDetail {
  name: string;
  size: number;
  latency: number;
  paused: boolean;
  page: number;
  count: number;
  jobs: QueueJob[];
}

const PAGE_SIZE = 25;

const JOB_SORT: Accessors<QueueJob> = {
  jid: (j) => j.jid,
  class: (j) => j.class,
  args: (j) => formatArgs(j.args),
  enqueued: (j) => j.enqueued_at,
};

function QueueJobs(props: { name: string }) {
  const [page, setPage] = usePageParam();
  const [selected, setSelected] = createSignal<JobEntry | null>(null);
  const meta = useMeta();
  const readOnly = () => meta.data?.read_only ?? false;
  const qc = useQueryClient();

  const query = useQuery<QueueDetail>(() => ({
    queryKey: ['queue', props.name, page()],
    queryFn: () =>
      fetch(`${basePath()}/api/queues/${encodeURIComponent(props.name)}?page=${page() - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<QueueDetail>
      ),
  }));

  // Delete one job from the queue by jid (server LREMs the exact payload).
  const deleteJob = useMutation(() => ({
    mutationFn: (jid: string) =>
      post(`${basePath()}/api/queues/${encodeURIComponent(props.name)}/delete`, { jid }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['queue', props.name] });
      qc.invalidateQueries({ queryKey: ['queues'] });
      qc.invalidateQueries({ queryKey: ['stats'] });
    },
    onError: notifyError,
  }));

  const { sorted, sort, toggle } = useSort(() => query.data?.jobs ?? [], JOB_SORT);

  return (
    <Switch>
      <Match when={query.isPending}>
        <SkeletonTable rows={6} cols={5} />
      </Match>
      <Match when={query.isError || !query.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={query.data}>
        {(data) => (
          <div class="qjobs">
            <div style={{ display: 'flex', 'align-items': 'center', gap: '0.75rem', 'margin-bottom': '1rem' }}>
              <span style={{ color: 'var(--text-muted)', 'font-size': '13px' }}>
                {data().size.toLocaleString()} jobs · <span title={`${data().latency.toFixed(3)}s`}>latency {formatDuration(data().latency)}</span>
              </span>
              <Show when={data().paused}>
                <span class="badge badge-warning">{t('dashboard.paused')}</span>
              </Show>
            </div>

            <Show when={sorted().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <>
                <div class="table-wrapper">
                  <table>
                    <thead>
                      <tr>
                        <SortableTh label={t('table.jid')} sortKey="jid" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.class')} sortKey="class" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.args')} sortKey="args" sort={sort()} onSort={toggle} />
                        <SortableTh label={t('table.enqueued_at')} sortKey="enqueued" sort={sort()} onSort={toggle} />
                        <Show when={!readOnly()}>
                          <th class="row-action" />
                        </Show>
                      </tr>
                    </thead>
                    <tbody>
                      <For each={sorted()}>
                        {(job) => {
                          const argsStr = formatArgs(job.args);
                          return (
                            <tr
                              class="row-clickable"
                              onClick={() => setSelected({ jid: job.jid, klass: job.class, args: job.args, queue: props.name, enqueued_at: job.enqueued_at })}
                            >
                              <td title={job.jid} style={{ 'font-family': 'monospace', 'font-size': '12px', color: 'var(--text-muted)' }}>
                                {truncate(job.jid, 12)}
                              </td>
                              <td style={{ 'font-weight': 500 }}>{job.class}</td>
                              <td><ArgsValue str={argsStr} max={60} /></td>
                              <td>{relativeTime(job.enqueued_at)}</td>
                              <Show when={!readOnly()}>
                                <td class="row-action" onClick={(e) => e.stopPropagation()}>
                                  <button
                                    class="btn btn-sm btn-danger"
                                    disabled={deleteJob.isPending}
                                    onClick={() => {
                                      if (window.confirm(t('actions.confirm', { action: t('actions.delete'), scope: t('actions.scope_this_job') }))) {
                                        deleteJob.mutate(job.jid);
                                      }
                                    }}
                                  >
                                    {t('actions.delete')}
                                  </button>
                                </td>
                              </Show>
                            </tr>
                          );
                        }}
                      </For>
                    </tbody>
                  </table>
                </div>
                <Pagination page={page()} total={data().size} count={PAGE_SIZE} onChange={setPage} />
              </>
            </Show>
            <JobDetailModal entry={selected()} onClose={() => setSelected(null)} />
          </div>
        )}
      </Match>
    </Switch>
  );
}

const QUEUE_SORT: Accessors<QueueSummary> = {
  name: (q) => q.name,
  size: (q) => q.size,
  latency: (q) => q.latency,
  status: (q) => (q.paused ? 'paused' : 'active'),
};

export default function Queues() {
  const [selectedQueue, setSelectedQueue] = createSignal<string | null>(null);
  const meta = useMeta();
  const readOnly = () => meta.data?.read_only ?? false;
  const qc = useQueryClient();

  onMount(() => {
    document.title = `${t('nav.queues')} — Wurk`;
  });

  const query = useQuery<QueueSummary[]>(() => ({
    queryKey: ['queues'],
    queryFn: () => fetch(`${basePath()}/api/queues`).then((r) => r.json() as Promise<QueueSummary[]>),
    refetchInterval: 5000,
  }));

  const clearQueue = useMutation(() => ({
    mutationFn: (name: string) => post(`${basePath()}/api/queues/${encodeURIComponent(name)}/clear`),
    onSuccess: (_res, name) => {
      qc.invalidateQueries({ queryKey: ['queues'] });
      qc.invalidateQueries({ queryKey: ['queue', name] });
      qc.invalidateQueries({ queryKey: ['stats'] });
    },
    onError: notifyError,
  }));

  // Toggle the queue's membership of the `paused` SET; fetchers stop pulling
  // from a paused queue. POST skips CSRF (ApiController#skip_forgery_protection).
  const pauseQueue = useMutation(() => ({
    mutationFn: ({ name, paused }: { name: string; paused: boolean }) =>
      post(`${basePath()}/api/queues/${encodeURIComponent(name)}/${paused ? 'unpause' : 'pause'}`),
    onSuccess: (_res, { name }) => {
      qc.invalidateQueries({ queryKey: ['queues'] });
      qc.invalidateQueries({ queryKey: ['queue', name] });
      // /api/stats carries per-queue paused flags the Dashboard renders, so a
      // toggle must refresh it too (mirrors clearQueue).
      qc.invalidateQueries({ queryKey: ['stats'] });
    },
    onError: notifyError,
  }));

  const { sorted, sort, toggle } = useSort(() => query.data ?? [], QUEUE_SORT);

  return (
    <Switch>
      <Match when={query.isPending}>
        <div>
          <PageHeader icon="fa-layer-group" title={t('nav.queues')} summary={t('summaries.queues')} />
          <SkeletonTable rows={8} cols={5} />
        </div>
      </Match>
      <Match when={query.isError || !query.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={query.data}>
        {(_data) => (
          <div>
            <PageHeader icon="fa-layer-group" title={t('nav.queues')} summary={t('summaries.queues')} />

            <Show when={sorted().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <div class="table-wrapper">
                <table>
                  <thead>
                    <tr>
                      <SortableTh label="Name" sortKey="name" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.size')} sortKey="size" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.latency')} sortKey="latency" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.status')} sortKey="status" sort={sort()} onSort={toggle} />
                      <Show when={!readOnly()}>
                        <th class="row-action" />
                      </Show>
                    </tr>
                  </thead>
                  <tbody>
                    <For each={sorted()}>
                      {(q) => (
                        <tr class="row-clickable" onClick={() => setSelectedQueue(q.name)}>
                          <td style={{ 'font-weight': 500 }}>{q.name}</td>
                          <td>{q.size.toLocaleString()}</td>
                          <td title={`${q.latency.toFixed(3)}s`}>{formatDuration(q.latency)}</td>
                          <td>
                            <Show when={q.paused} fallback={<span class="badge badge-success">Active</span>}>
                              <span class="badge badge-warning">{t('dashboard.paused')}</span>
                            </Show>
                          </td>
                          <Show when={!readOnly()}>
                            <td class="row-action" onClick={(e) => e.stopPropagation()}>
                              <div style={{ display: 'flex', gap: '0.4rem', 'justify-content': 'flex-end' }}>
                                <Tooltip tip={q.paused ? t('actions.unpause_hint') : t('actions.pause_hint')}>
                                  <button
                                    class="btn btn-sm"
                                    disabled={pauseQueue.isPending}
                                    onClick={() => pauseQueue.mutate({ name: q.name, paused: q.paused })}
                                  >
                                    {q.paused ? t('actions.unpause') : t('actions.pause')}
                                  </button>
                                </Tooltip>
                                <button
                                  class="btn btn-sm btn-danger"
                                  disabled={clearQueue.isPending}
                                  onClick={() => {
                                    if (window.confirm(t('actions.confirm_clear_queue', { name: q.name }))) clearQueue.mutate(q.name);
                                  }}
                                >
                                  {t('actions.clear')}
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
              open={selectedQueue() !== null}
              onClose={() => setSelectedQueue(null)}
              title={selectedQueue() ?? ''}
              width={780}
            >
              <Show when={selectedQueue()}>{(name) => <QueueJobs name={name()} />}</Show>
            </Modal>
          </div>
        )}
      </Match>
    </Switch>
  );
}

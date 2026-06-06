import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { ArgsValue } from '../components/ArgsValue';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { usePageParam } from '../hooks/usePageParam';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';
import Modal from '../components/Modal';
import { useMeta } from '../hooks/useMeta';

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

function QueueJobs({ name }: { name: string }) {
  const [page, setPage] = usePageParam();
  const [selected, setSelected] = useState<JobEntry | null>(null);
  const { data: meta } = useMeta();
  const readOnly = meta?.read_only ?? false;
  const qc = useQueryClient();

  const { data, isLoading, isError } = useQuery<QueueDetail>({
    queryKey: ['queue', name, page],
    queryFn: () =>
      fetch(`/wurk/api/queues/${encodeURIComponent(name)}?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<QueueDetail>
      ),
  });

  // Delete one job from the queue by jid (server LREMs the exact payload).
  const deleteJob = useMutation({
    mutationFn: async (jid: string) => {
      const res = await fetch(`/wurk/api/queues/${encodeURIComponent(name)}/delete`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jid }),
      });
      if (!res.ok) throw new Error(`Delete failed (${res.status})`);
      return res;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['queue', name] });
      qc.invalidateQueries({ queryKey: ['queues'] });
      qc.invalidateQueries({ queryKey: ['stats'] });
    },
  });

  const { sorted, sort, toggle } = useSort(data?.jobs ?? [], JOB_SORT);

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div className="qjobs">
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', marginBottom: '1rem' }}>
        <span style={{ color: 'var(--text-muted)', fontSize: 13 }}>
          {data.size.toLocaleString()} jobs · latency {data.latency.toFixed(3)}s
        </span>
        {data.paused && <span className="badge badge-warning">{t('dashboard.paused')}</span>}
      </div>

      {sorted.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <SortableTh label={t('table.jid')} sortKey="jid" sort={sort} onSort={toggle} />
                  <SortableTh label={t('table.class')} sortKey="class" sort={sort} onSort={toggle} />
                  <SortableTh label={t('table.args')} sortKey="args" sort={sort} onSort={toggle} />
                  <SortableTh label={t('table.enqueued_at')} sortKey="enqueued" sort={sort} onSort={toggle} />
                  {!readOnly && <th className="row-action" />}
                </tr>
              </thead>
              <tbody>
                {sorted.map((job) => {
                  const argsStr = formatArgs(job.args);
                  return (
                    <tr
                      key={job.jid}
                      className="row-clickable"
                      onClick={() => setSelected({ jid: job.jid, klass: job.class, args: job.args, queue: name, enqueued_at: job.enqueued_at })}
                    >
                      <td title={job.jid} style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text-muted)' }}>
                        {truncate(job.jid, 12)}
                      </td>
                      <td style={{ fontWeight: 500 }}>{job.class}</td>
                      <td><ArgsValue str={argsStr} max={60} /></td>
                      <td>{relativeTime(job.enqueued_at)}</td>
                      {!readOnly && (
                        <td className="row-action" onClick={(e) => e.stopPropagation()}>
                          <button
                            className="btn btn-sm btn-danger"
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
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <Pagination page={page} total={data.size} count={PAGE_SIZE} onChange={setPage} />
        </>
      )}
      <JobDetailModal entry={selected} onClose={() => setSelected(null)} />
    </div>
  );
}

const QUEUE_SORT: Accessors<QueueSummary> = {
  name: (q) => q.name,
  size: (q) => q.size,
  latency: (q) => q.latency,
  status: (q) => (q.paused ? 'paused' : 'active'),
};

export default function Queues() {
  const [selectedQueue, setSelectedQueue] = useState<string | null>(null);
  const { data: meta } = useMeta();
  const readOnly = meta?.read_only ?? false;
  const qc = useQueryClient();

  useEffect(() => {
    document.title = `${t('nav.queues')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<QueueSummary[]>({
    queryKey: ['queues'],
    queryFn: () => fetch('/wurk/api/queues').then((r) => r.json() as Promise<QueueSummary[]>),
    refetchInterval: 10000,
  });

  const clearQueue = useMutation({
    mutationFn: async (name: string) => {
      const res = await fetch(`/wurk/api/queues/${encodeURIComponent(name)}/clear`, { method: 'POST' });
      if (!res.ok) throw new Error(`Clear failed (${res.status})`);
      return res;
    },
    onSuccess: (_res, name) => {
      qc.invalidateQueries({ queryKey: ['queues'] });
      qc.invalidateQueries({ queryKey: ['queue', name] });
      qc.invalidateQueries({ queryKey: ['stats'] });
    },
  });

  const { sorted, sort, toggle } = useSort(data ?? [], QUEUE_SORT);

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <PageHeader icon="fa-layer-group" title={t('nav.queues')} summary={t('summaries.queues')} />

      {sorted.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <div className="table-wrapper">
          <table>
            <thead>
              <tr>
                <SortableTh label="Name" sortKey="name" sort={sort} onSort={toggle} />
                <SortableTh label={t('table.size')} sortKey="size" sort={sort} onSort={toggle} />
                <SortableTh label={t('table.latency')} sortKey="latency" sort={sort} onSort={toggle} />
                <SortableTh label={t('table.status')} sortKey="status" sort={sort} onSort={toggle} />
                {!readOnly && <th className="row-action" />}
              </tr>
            </thead>
            <tbody>
              {sorted.map((q) => (
                <tr key={q.name} className="row-clickable" onClick={() => setSelectedQueue(q.name)}>
                  <td style={{ fontWeight: 500 }}>{q.name}</td>
                  <td>{q.size.toLocaleString()}</td>
                  <td>{q.latency.toFixed(3)}s</td>
                  <td>
                    {q.paused ? (
                      <span className="badge badge-warning">{t('dashboard.paused')}</span>
                    ) : (
                      <span className="badge badge-success">Active</span>
                    )}
                  </td>
                  {!readOnly && (
                    <td className="row-action" onClick={(e) => e.stopPropagation()}>
                      <button
                        className="btn btn-sm btn-danger"
                        disabled={clearQueue.isPending}
                        onClick={() => {
                          if (window.confirm(t('actions.confirm_clear_queue', { name: q.name }))) clearQueue.mutate(q.name);
                        }}
                      >
                        {t('actions.clear')}
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Modal
        open={selectedQueue !== null}
        onClose={() => setSelectedQueue(null)}
        title={selectedQueue ?? ''}
        width={780}
      >
        {selectedQueue && <QueueJobs name={selectedQueue} />}
      </Modal>
    </div>
  );
}

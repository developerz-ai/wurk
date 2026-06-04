import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { t } from '../i18n';
import { relativeTime, truncate, formatArgs } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';

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

function QueueJobs({ name }: { name: string }) {
  const [page, setPage] = useState(1);
  const [selected, setSelected] = useState<JobEntry | null>(null);

  const { data, isLoading, isError } = useQuery<QueueDetail>({
    queryKey: ['queue', name, page],
    queryFn: () =>
      fetch(`/wurk/api/queues/${encodeURIComponent(name)}?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<QueueDetail>
      ),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', marginBottom: '1rem' }}>
        <span style={{ color: 'var(--text-muted)', fontSize: 13 }}>
          {data.size.toLocaleString()} jobs · latency {data.latency.toFixed(3)}s
        </span>
        {data.paused && <span className="badge badge-warning">{t('dashboard.paused')}</span>}
      </div>

      {data.jobs.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>{t('table.jid')}</th>
                  <th>{t('table.class')}</th>
                  <th>{t('table.args')}</th>
                  <th>{t('table.scheduled_at')}</th>
                </tr>
              </thead>
              <tbody>
                {data.jobs.map((job) => {
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
                      <td title={argsStr}>{truncate(argsStr, 60)}</td>
                      <td>{relativeTime(job.enqueued_at)}</td>
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

export default function Queues() {
  const [selectedQueue, setSelectedQueue] = useState<string | null>(null);

  useEffect(() => {
    document.title = `${t('nav.queues')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<QueueSummary[]>({
    queryKey: ['queues'],
    queryFn: () => fetch('/wurk/api/queues').then((r) => r.json() as Promise<QueueSummary[]>),
    refetchInterval: 10000,
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <h1 className="page-title">{t('nav.queues')}</h1>

      <div style={{ display: 'grid', gridTemplateColumns: selectedQueue ? '280px 1fr' : '1fr', gap: '1.5rem' }}>
        <div>
          {data.length === 0 ? (
            <div className="empty-state">{t('common.empty')}</div>
          ) : (
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>{t('table.size')}</th>
                    <th>{t('table.latency')}</th>
                    <th>{t('table.status')}</th>
                  </tr>
                </thead>
                <tbody>
                  {data.map((q) => (
                    <tr
                      key={q.name}
                      onClick={() => setSelectedQueue(q.name === selectedQueue ? null : q.name)}
                      style={{
                        cursor: 'pointer',
                        background: q.name === selectedQueue ? 'rgba(124,106,247,0.08)' : undefined,
                      }}
                    >
                      <td style={{ fontWeight: 500, color: q.name === selectedQueue ? 'var(--accent)' : undefined }}>
                        {q.name}
                      </td>
                      <td>{q.size.toLocaleString()}</td>
                      <td>{q.latency.toFixed(3)}s</td>
                      <td>
                        {q.paused ? (
                          <span className="badge badge-warning">{t('dashboard.paused')}</span>
                        ) : (
                          <span className="badge badge-success">Active</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {selectedQueue && (
          <div>
            <div className="section-header">
              <h2 className="section-title">{selectedQueue}</h2>
              <button className="btn" onClick={() => setSelectedQueue(null)} style={{ marginLeft: 'auto' }}>
                ✕
              </button>
            </div>
            <QueueJobs name={selectedQueue} />
          </div>
        )}
      </div>
    </div>
  );
}

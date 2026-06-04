import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { usePageParam } from '../hooks/usePageParam';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs, isoTime } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';

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

export default function Scheduled() {
  const [page, setPage] = usePageParam();
  const [selected, setSelected] = useState<JobEntry | null>(null);

  useEffect(() => {
    document.title = `${t('nav.scheduled')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<ScheduledResponse>({
    queryKey: ['scheduled', page],
    queryFn: () =>
      fetch(`/wurk/api/scheduled?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<ScheduledResponse>
      ),
  });

  const { sorted, sort, toggle } = useSort(data?.entries ?? [], SORT);

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <PageHeader icon="fa-clock" title={t('nav.scheduled')} summary={t('summaries.scheduled')}>
        <span className="badge badge-accent">{data.total.toLocaleString()}</span>
      </PageHeader>

      {sorted.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <SortableTh label={t('table.jid')} sortKey="jid" sort={sort} onSort={toggle} />
                  <SortableTh label={t('table.class')} sortKey="klass" sort={sort} onSort={toggle} />
                  <SortableTh label={t('table.args')} sortKey="args" sort={sort} onSort={toggle} />
                  <SortableTh label={t('table.scheduled_at')} sortKey="at" sort={sort} onSort={toggle} />
                </tr>
              </thead>
              <tbody>
                {sorted.map((entry) => {
                  const argsStr = formatArgs(entry.args);
                  return (
                    <tr key={entry.jid} className="row-clickable" onClick={() => setSelected(entry)}>
                      <td
                        title={entry.jid}
                        style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text-muted)' }}
                      >
                        {truncate(entry.jid, 12)}
                      </td>
                      <td style={{ fontWeight: 500 }}>{entry.klass}</td>
                      <td title={argsStr}>{truncate(argsStr, 60)}</td>
                      <td title={isoTime(entry.at)}>
                        {relativeTime(entry.at)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <Pagination page={page} total={data.total} count={PAGE_SIZE} onChange={setPage} />
        </>
      )}
      <JobDetailModal entry={selected} atLabel={t('table.scheduled_at')} onClose={() => setSelected(null)} />
    </div>
  );
}

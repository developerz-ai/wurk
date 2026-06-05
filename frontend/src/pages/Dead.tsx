import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { ArgsValue } from '../components/ArgsValue';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { usePageParam } from '../hooks/usePageParam';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs, isoTime } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';

interface DeadEntry {
  jid: string;
  klass: string;
  args: unknown;
  error_class: string;
  error_message: string;
  // `at` is the death epoch (the sorted-set score); see api/serializers.rb#sorted_entry.
  at: number;
  score: number;
  queue?: string;
  enqueued_at?: number | null;
  error_backtrace?: string[] | null;
}

interface DeadResponse {
  total: number;
  page: number;
  count: number;
  entries: DeadEntry[];
}

const PAGE_SIZE = 25;

const SORT: Accessors<DeadEntry> = {
  jid: (e) => e.jid,
  klass: (e) => e.klass,
  args: (e) => formatArgs(e.args),
  error_class: (e) => e.error_class,
  error_message: (e) => e.error_message,
  failed_at: (e) => e.at,
};

export default function Dead() {
  const [page, setPage] = usePageParam();
  const [selected, setSelected] = useState<JobEntry | null>(null);

  useEffect(() => {
    document.title = `${t('nav.dead')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<DeadResponse>({
    queryKey: ['dead', page],
    queryFn: () =>
      fetch(`/wurk/api/dead?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<DeadResponse>
      ),
  });

  const { sorted, sort, toggle } = useSort(data?.entries ?? [], SORT);

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <PageHeader icon="fa-skull" title={t('nav.dead')} summary={t('summaries.dead')}>
        <span className="badge badge-danger">{data.total.toLocaleString()}</span>
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
                  <SortableTh label={t('table.error')} sortKey="error_class" sort={sort} onSort={toggle} />
                  <SortableTh label="Message" sortKey="error_message" sort={sort} onSort={toggle} />
                  <SortableTh label={t('table.failed_at')} sortKey="failed_at" sort={sort} onSort={toggle} />
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
                      <td><ArgsValue str={argsStr} max={40} /></td>
                      <td title={entry.error_class} style={{ color: 'var(--danger)' }}>
                        {truncate(entry.error_class, 25)}
                      </td>
                      <td title={entry.error_message}>{truncate(entry.error_message, 40)}</td>
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
      <JobDetailModal entry={selected} atLabel={t('table.failed_at')} onClose={() => setSelected(null)} />
    </div>
  );
}

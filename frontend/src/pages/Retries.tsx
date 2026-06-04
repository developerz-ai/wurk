import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { Pagination } from '../components/Pagination';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs, isoTime } from '../utils';
import JobDetailModal, { type JobEntry } from '../components/JobDetailModal';

interface RetryEntry {
  jid: string;
  klass: string;
  args: unknown;
  error_class: string;
  error_message: string;
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

export default function Retries() {
  const [page, setPage] = useState(1);
  const [selected, setSelected] = useState<JobEntry | null>(null);

  useEffect(() => {
    document.title = `${t('nav.retries')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<RetriesResponse>({
    queryKey: ['retries', page],
    queryFn: () =>
      fetch(`/wurk/api/retries?page=${page - 1}&count=${PAGE_SIZE}`).then(
        (r) => r.json() as Promise<RetriesResponse>
      ),
  });

  if (isLoading) return <div className="empty-state"><span className="spinner" /></div>;
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  return (
    <div>
      <PageHeader icon="fa-rotate-right" title={t('nav.retries')} summary={t('summaries.retries')}>
        <span className="badge badge-warning">{data.total.toLocaleString()}</span>
      </PageHeader>

      {data.entries.length === 0 ? (
        <div className="empty-state">{t('common.empty')}</div>
      ) : (
        <>
          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>{t('table.class')}</th>
                  <th>{t('table.args')}</th>
                  <th>{t('table.error')}</th>
                  <th>Message</th>
                  <th>Count</th>
                  <th>{t('table.retry_at')}</th>
                </tr>
              </thead>
              <tbody>
                {data.entries.map((entry) => {
                  const argsStr = formatArgs(entry.args);
                  return (
                    <tr key={entry.jid} className="row-clickable" onClick={() => setSelected(entry)}>
                      <td style={{ fontWeight: 500 }}>{entry.klass}</td>
                      <td title={argsStr}>{truncate(argsStr, 40)}</td>
                      <td title={entry.error_class} style={{ color: 'var(--danger)' }}>
                        {truncate(entry.error_class, 30)}
                      </td>
                      <td title={entry.error_message}>{truncate(entry.error_message, 50)}</td>
                      <td style={{ color: 'var(--warning)' }}>{entry.retry_count}</td>
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
      <JobDetailModal entry={selected} atLabel={t('table.retry_at')} onClose={() => setSelected(null)} />
    </div>
  );
}

import { useQuery } from '@tanstack/react-query';
import { useEffect, type ReactNode } from 'react';
import { Link, useParams } from 'react-router-dom';
import { t } from '../i18n';
import { relativeTime } from '../utils';
import { SkeletonCards } from '../components/Skeleton';

interface BatchDetailData {
  bid: string;
  description: string | null;
  total: number;
  pending: number;
  failures: number;
  complete: boolean;
  invalidated: boolean;
  created_at: number | null;
  complete_at: number | null;
  success_at: number | null;
  death_at: number | null;
  parent_bid: string | null;
  tags: string[];
  child_count: number;
  failed_jids: string[];
  dead_jids: string[];
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
      <span style={{ fontSize: 11, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
        {label}
      </span>
      <span style={{ fontVariantNumeric: 'tabular-nums' }}>{children}</span>
    </div>
  );
}

function JidList({ label, jids }: { label: string; jids: string[] }) {
  if (jids.length === 0) return null;
  return (
    <div style={{ marginTop: '1.5rem' }}>
      <h2 style={{ fontSize: 14, margin: '0 0 0.5rem' }}>
        {label} <span className="badge badge-muted">{jids.length}</span>
      </h2>
      <div className="table-wrapper">
        <table>
          <tbody>
            {jids.map((jid) => (
              <tr key={jid}>
                <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{jid}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export default function BatchDetail() {
  const { bid = '' } = useParams();

  useEffect(() => {
    document.title = `${t('nav.batches')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<BatchDetailData>({
    queryKey: ['batch', bid],
    queryFn: () =>
      fetch(`/wurk/api/batches/${encodeURIComponent(bid)}`).then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<BatchDetailData>;
      }),
  });

  if (isLoading)
    return (
      <div>
        <div className="section-header" style={{ gap: '0.75rem' }}>
          <Link to="/batches" className="btn btn-sm">← {t('nav.batches')}</Link>
        </div>
        <div style={{ marginTop: '1rem' }}>
          <SkeletonCards count={8} />
        </div>
      </div>
    );
  if (isError || !data) return <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>;

  const done = data.total - data.pending;
  const pct = data.total > 0 ? Math.round((done / data.total) * 100) : 0;

  return (
    <div>
      <div className="section-header" style={{ gap: '0.75rem' }}>
        <Link to="/batches" className="btn btn-sm">← {t('nav.batches')}</Link>
        <h1 className="page-title" style={{ margin: 0, fontFamily: 'monospace', fontSize: 16 }}>{data.bid}</h1>
        {data.complete ? (
          <span className="badge badge-success">complete</span>
        ) : (
          <span className="badge badge-accent">{pct}%</span>
        )}
        {data.invalidated && <span className="badge badge-danger">invalidated</span>}
      </div>

      {data.description && (
        <p style={{ color: 'var(--text-muted)', marginTop: 0 }}>{data.description}</p>
      )}

      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(140px, 1fr))',
          gap: '1rem',
          marginTop: '1rem',
        }}
      >
        <Field label="Total">{data.total.toLocaleString()}</Field>
        <Field label="Pending">{data.pending.toLocaleString()}</Field>
        <Field label="Failures">{data.failures.toLocaleString()}</Field>
        <Field label="Children">{data.child_count.toLocaleString()}</Field>
        <Field label="Created">{data.created_at ? relativeTime(data.created_at) : '—'}</Field>
        <Field label="Completed">{data.complete_at ? relativeTime(data.complete_at) : '—'}</Field>
        {data.parent_bid && <Field label="Parent">{data.parent_bid}</Field>}
        {data.tags.length > 0 && <Field label="Tags">{data.tags.join(', ')}</Field>}
      </div>

      <JidList label="Failed jobs" jids={data.failed_jids} />
      <JidList label="Dead jobs" jids={data.dead_jids} />
    </div>
  );
}

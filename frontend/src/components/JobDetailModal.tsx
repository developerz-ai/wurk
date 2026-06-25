import { type ReactNode } from 'react';
import Modal from './Modal';
import { t } from '../i18n';
import { formatArgs, isoTime, relativeTime } from '../utils';
import type { ActionDef } from './JobSetActionBar';

// Union of the fields the various list endpoints expose for a job/entry
// (queues · retries · scheduled · dead). All optional beyond jid/klass so one
// component renders every source; missing fields are simply skipped.
export interface JobEntry {
  jid: string;
  klass: string;
  queue?: string;
  args?: unknown;
  enqueued_at?: number | null;
  created_at?: number | null;
  at?: number;
  retry_count?: number;
  error_class?: string | null;
  error_message?: string | null;
  error_backtrace?: string[] | null;
  // [label, value] rows contributed by third-party extensions via
  // Sidekiq::Web.custom_job_info_rows (spec §25.2).
  custom_rows?: [string, string][];
}

function Field({ label, children, mono }: { label: string; children: ReactNode; mono?: boolean }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      <span style={{ fontSize: 11, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
        {label}
      </span>
      <span style={{ fontSize: 13, fontFamily: mono ? 'ui-monospace, monospace' : undefined, wordBreak: 'break-word' }}>
        {children}
      </span>
    </div>
  );
}

interface JobDetailModalProps {
  entry: JobEntry | null;
  /** When the entry came from a failed set (retries/dead), show the at-field as "next retry" vs "scheduled". */
  atLabel?: string;
  /** Single-job actions for the footer (retry/delete/kill/add_to_queue). Omitted in read-only mode. */
  actions?: ActionDef[];
  /** Fired with an action's `cmd` when its footer button is clicked. */
  onAction?: (cmd: string) => void;
  /** Disables footer buttons while a single-job mutation is in flight (prevents duplicate dispatches). */
  pending?: boolean;
  onClose: () => void;
}

export default function JobDetailModal({ entry, atLabel, actions, onAction, pending = false, onClose }: JobDetailModalProps) {
  const footer =
    actions && actions.length > 0 && onAction ? (
      <div style={{ display: 'flex', gap: '0.5rem', justifyContent: 'flex-end', flexWrap: 'wrap' }}>
        {actions.map((a) => (
          <button
            key={a.cmd}
            className={`btn btn-sm${a.danger ? ' btn-danger' : ''}`}
            disabled={pending}
            onClick={() => {
              if (pending) return;
              if (a.danger && !window.confirm(t('actions.confirm', { action: a.label, scope: t('job.detail').toLowerCase() }))) return;
              onAction(a.cmd);
            }}
          >
            {a.label}
          </button>
        ))}
      </div>
    ) : undefined;

  return (
    <Modal open={entry !== null} onClose={onClose} title={entry?.klass ?? t('job.detail')} width={680} footer={footer}>
      {entry && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: '0.9rem' }}>
            <Field label={t('job.class')}>{entry.klass}</Field>
            {entry.queue && <Field label={t('job.queue')}>{entry.queue}</Field>}
            <Field label={t('job.jid')} mono>{entry.jid}</Field>
            {typeof entry.retry_count === 'number' && (
              <Field label={t('job.retries')}>{entry.retry_count}</Field>
            )}
            {entry.enqueued_at != null && (
              <Field label={t('job.enqueued')} mono>{isoTime(entry.enqueued_at)} ({relativeTime(entry.enqueued_at)})</Field>
            )}
            {entry.at != null && (
              <Field label={atLabel ?? t('job.at')} mono>{isoTime(entry.at)} ({relativeTime(entry.at)})</Field>
            )}
          </div>

          <Field label={t('job.args')} mono>
            {formatArgs(entry.args) === '[]' || formatArgs(entry.args) === '' ? (
              <span style={{ color: 'var(--text-muted)' }}>—</span>
            ) : (
              <pre style={{ margin: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>{formatArgs(entry.args)}</pre>
            )}
          </Field>

          {(entry.error_class || entry.error_message) && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
              <span style={{ fontSize: 11, color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                {t('job.error')}
              </span>
              <span style={{ fontSize: 13, color: 'var(--danger)', wordBreak: 'break-word' }}>
                {entry.error_class}{entry.error_message ? `: ${entry.error_message}` : ''}
              </span>
            </div>
          )}

          {entry.error_backtrace && entry.error_backtrace.length > 0 && (
            <Field label={t('job.backtrace')}>
              <pre className="job-backtrace">{entry.error_backtrace.join('\n')}</pre>
            </Field>
          )}

          {entry.custom_rows && entry.custom_rows.length > 0 && (
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: '0.9rem' }}>
              {entry.custom_rows.map(([label, value], idx) => (
                <Field key={`${label}-${idx}`} label={label}>{value}</Field>
              ))}
            </div>
          )}
        </div>
      )}
    </Modal>
  );
}

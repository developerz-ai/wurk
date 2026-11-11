import { For, Show, type JSX } from 'solid-js';
import { useQuery } from '@tanstack/solid-query';
import Modal from './Modal';
import { t } from '../i18n';
import { getJSON } from '../http';
import { absoluteTime, formatArgs, hoverTime, relativeTime } from '../utils';
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
  // Only on a detail read (GET <set>/:key, see `detailUrl`): listing rows
  // leave it out, since inflating it per row costs the server for a field
  // only this modal shows.
  error_backtrace?: string[] | null;
  // [label, value] rows contributed by third-party extensions via
  // Sidekiq::Web.custom_job_info_rows (spec §25.2).
  custom_rows?: [string, string][];
}

function Field(props: { label: string; children: JSX.Element; mono?: boolean }) {
  return (
    <div style={{ display: 'flex', 'flex-direction': 'column', gap: '3px' }}>
      <span style={{ 'font-size': '11px', color: 'var(--text-muted)', 'text-transform': 'uppercase', 'letter-spacing': '0.04em' }}>
        {props.label}
      </span>
      <span style={{ 'font-size': '13px', 'font-family': props.mono ? 'ui-monospace, monospace' : undefined, 'word-break': 'break-word' }}>
        {props.children}
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
  /** The entry's detail endpoint (`<mount>/api/<set>/<key>`), read for the backtrace a listing row leaves out. */
  detailUrl?: string | null;
  onClose: () => void;
}

export default function JobDetailModal(props: JobDetailModalProps) {
  // Only a failed entry has a backtrace worth a request.
  const wantsDetail = () => props.entry !== null && !!props.detailUrl && !!props.entry.error_class && props.entry.error_backtrace == null;
  const detail = useQuery<JobEntry>(() => ({
    queryKey: ['job-detail', props.detailUrl],
    queryFn: () => getJSON<JobEntry>(props.detailUrl!),
    enabled: wantsDetail(),
    staleTime: 30_000,
  }));
  const backtrace = () => props.entry?.error_backtrace ?? (wantsDetail() ? detail.data?.error_backtrace : null);
  const footer =
    props.actions && props.actions.length > 0 && props.onAction ? (
      <div style={{ display: 'flex', gap: '0.5rem', 'justify-content': 'flex-end', 'flex-wrap': 'wrap' }}>
        <For each={props.actions}>
          {(a) => (
            <button
              class={`btn btn-sm${a.danger ? ' btn-danger' : ''}`}
              disabled={props.pending}
              onClick={() => {
                if (props.pending) return;
                if (a.danger && !window.confirm(t('actions.confirm', { action: a.label, scope: t('job.detail').toLowerCase() }))) return;
                props.onAction?.(a.cmd);
              }}
            >
              {a.label}
            </button>
          )}
        </For>
      </div>
    ) : undefined;

  return (
    <Modal open={props.entry !== null} onClose={props.onClose} title={props.entry?.klass ?? t('job.detail')} width={680} footer={footer}>
      <Show when={props.entry}>
        {(entry) => (
          <div style={{ display: 'flex', 'flex-direction': 'column', gap: '1rem' }}>
            <div style={{ display: 'grid', 'grid-template-columns': 'repeat(auto-fit, minmax(160px, 1fr))', gap: '0.9rem' }}>
              <Field label={t('job.class')}>{entry().klass}</Field>
              <Show when={entry().queue}>
                <Field label={t('job.queue')}>{entry().queue}</Field>
              </Show>
              <Field label={t('job.jid')} mono>{entry().jid}</Field>
              <Show when={typeof entry().retry_count === 'number'}>
                <Field label={t('job.retries')}>{entry().retry_count}</Field>
              </Show>
              <Show when={entry().enqueued_at != null}>
                <Field label={t('job.enqueued')} mono>
                  <span title={hoverTime(entry().enqueued_at!)}>
                    {absoluteTime(entry().enqueued_at!)} ({relativeTime(entry().enqueued_at!)})
                  </span>
                </Field>
              </Show>
              <Show when={entry().at != null}>
                <Field label={props.atLabel ?? t('job.at')} mono>
                  <span title={hoverTime(entry().at!)}>
                    {absoluteTime(entry().at!)} ({relativeTime(entry().at!)})
                  </span>
                </Field>
              </Show>
            </div>

            <Field label={t('job.args')} mono>
              <Show
                when={formatArgs(entry().args) === '[]' || formatArgs(entry().args) === ''}
                fallback={<pre style={{ margin: 0, 'white-space': 'pre-wrap', 'word-break': 'break-word' }}>{formatArgs(entry().args)}</pre>}
              >
                <span style={{ color: 'var(--text-muted)' }}>—</span>
              </Show>
            </Field>

            <Show when={entry().error_class || entry().error_message}>
              <div style={{ display: 'flex', 'flex-direction': 'column', gap: '3px' }}>
                <span style={{ 'font-size': '11px', color: 'var(--text-muted)', 'text-transform': 'uppercase', 'letter-spacing': '0.04em' }}>
                  {t('job.error')}
                </span>
                <span style={{ 'font-size': '13px', color: 'var(--danger)', 'word-break': 'break-word' }}>
                  {entry().error_class}{entry().error_message ? `: ${entry().error_message}` : ''}
                </span>
              </div>
            </Show>

            <Show when={backtrace() && backtrace()!.length > 0}>
              <Field label={t('job.backtrace')}>
                <pre class="job-backtrace">{backtrace()!.join('\n')}</pre>
              </Field>
            </Show>
            <Show when={wantsDetail() && detail.isPending}>
              <Field label={t('job.backtrace')}>
                <span style={{ color: 'var(--text-muted)' }}>{t('job.backtrace_loading')}</span>
              </Field>
            </Show>
            <Show when={wantsDetail() && detail.isError}>
              <Field label={t('job.backtrace')}>
                <span style={{ color: 'var(--text-muted)' }}>{t('job.backtrace_unavailable')}</span>
              </Field>
            </Show>

            <Show when={entry().custom_rows && entry().custom_rows!.length > 0}>
              <div style={{ display: 'grid', 'grid-template-columns': 'repeat(auto-fit, minmax(160px, 1fr))', gap: '0.9rem' }}>
                <For each={entry().custom_rows}>
                  {([label, value]) => <Field label={label}>{value}</Field>}
                </For>
              </div>
            </Show>
          </div>
        )}
      </Show>
    </Modal>
  );
}

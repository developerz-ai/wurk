import { useQuery } from '@tanstack/solid-query';
import { onMount, For, Show, Switch, Match, type JSX } from 'solid-js';
import { A, useParams } from '@solidjs/router';
import { t } from '../i18n';
import { relativeTime } from '../utils';
import { SkeletonCards } from '../components/Skeleton';
import { basePath } from '../basePath';

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

function Field(props: { label: string; children: JSX.Element }) {
  return (
    <div style={{ display: 'flex', 'flex-direction': 'column', gap: '2px' }}>
      <span style={{ 'font-size': '11px', color: 'var(--text-muted)', 'text-transform': 'uppercase', 'letter-spacing': '0.04em' }}>
        {props.label}
      </span>
      <span style={{ 'font-variant-numeric': 'tabular-nums' }}>{props.children}</span>
    </div>
  );
}

function JidList(props: { label: string; jids: string[] }) {
  return (
    <Show when={props.jids.length > 0}>
      <div style={{ 'margin-top': '1.5rem' }}>
        <h2 style={{ 'font-size': '14px', margin: '0 0 0.5rem' }}>
          {props.label} <span class="badge badge-muted">{props.jids.length}</span>
        </h2>
        <div class="table-wrapper">
          <table>
            <tbody>
              <For each={props.jids}>
                {(jid) => (
                  <tr>
                    <td style={{ 'font-family': 'monospace', 'font-size': '12px' }}>{jid}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </div>
    </Show>
  );
}

export default function BatchDetail() {
  const params = useParams();
  const bid = () => params.bid ?? '';

  onMount(() => {
    document.title = `${t('nav.batches')} — Wurk`;
  });

  const q = useQuery<BatchDetailData>(() => ({
    queryKey: ['batch', bid()],
    queryFn: () =>
      fetch(`${basePath()}/api/batches/${encodeURIComponent(bid())}`).then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json() as Promise<BatchDetailData>;
      }),
  }));

  return (
    <Switch>
      <Match when={q.isPending}>
        <div>
          <div class="section-header" style={{ gap: '0.75rem' }}>
            <A href="/batches" class="btn btn-sm">← {t('nav.batches')}</A>
          </div>
          <div style={{ 'margin-top': '1rem' }}>
            <SkeletonCards count={8} />
          </div>
        </div>
      </Match>
      <Match when={q.isError || !q.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={q.data}>
        {(data) => {
          const done = () => data().total - data().pending;
          const pct = () => (data().total > 0 ? Math.round((done() / data().total) * 100) : 0);
          return (
            <div>
              <div class="section-header" style={{ gap: '0.75rem' }}>
                <A href="/batches" class="btn btn-sm">← {t('nav.batches')}</A>
                <h1 class="page-title" style={{ margin: 0, 'font-family': 'monospace', 'font-size': '16px' }}>{data().bid}</h1>
                <Show when={data().complete} fallback={<span class="badge badge-accent">{pct()}%</span>}>
                  <span class="badge badge-success">{t('batches.complete')}</span>
                </Show>
                <Show when={data().invalidated}>
                  <span class="badge badge-danger">{t('batches.invalidated')}</span>
                </Show>
              </div>

              <Show when={data().description}>
                <p style={{ color: 'var(--text-muted)', 'margin-top': 0 }}>{data().description}</p>
              </Show>

              <div
                style={{
                  display: 'grid',
                  'grid-template-columns': 'repeat(auto-fill, minmax(140px, 1fr))',
                  gap: '1rem',
                  'margin-top': '1rem',
                }}
              >
                <Field label={t('table.total')}>{data().total.toLocaleString()}</Field>
                <Field label={t('table.pending')}>{data().pending.toLocaleString()}</Field>
                <Field label={t('table.failures')}>{data().failures.toLocaleString()}</Field>
                <Field label={t('batches.children')}>{data().child_count.toLocaleString()}</Field>
                <Field label={t('table.created')}>{data().created_at ? relativeTime(data().created_at!) : '—'}</Field>
                <Field label={t('batches.completed')}>{data().complete_at ? relativeTime(data().complete_at!) : '—'}</Field>
                <Show when={data().parent_bid}>
                  <Field label={t('batches.parent')}>{data().parent_bid}</Field>
                </Show>
                <Show when={data().tags.length > 0}>
                  <Field label={t('batches.tags')}>{data().tags.join(', ')}</Field>
                </Show>
              </div>

              <JidList label={t('batches.failed_jobs')} jids={data().failed_jids} />
              <JidList label={t('batches.dead_jobs')} jids={data().dead_jids} />
            </div>
          );
        }}
      </Match>
    </Switch>
  );
}

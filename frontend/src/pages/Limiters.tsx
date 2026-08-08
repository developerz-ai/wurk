import { useQuery, useMutation, useQueryClient } from '@tanstack/solid-query';
import { onMount, For, Switch, Match, Show } from 'solid-js';
import { Pagination } from '../components/Pagination';
import { SortableTh } from '../components/SortableTh';
import { useSort, type Accessors } from '../hooks/useSort';
import { usePageParam } from '../hooks/usePageParam';
import { useResetPageOnEmpty } from '../hooks/useResetPageOnEmpty';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { SkeletonTable } from '../components/Skeleton';
import { formatNumber } from '../utils';
import { useMeta } from '../hooks/useMeta';
import { basePath } from '../basePath';
import { getJSON, post } from '../http';
import { notifyError } from '../toast';

// Uniform live status every limiter type reports (Wurk::Limiter#status).
// `concurrent` additionally merges its metric counters (held/immediate/…),
// which we surface in the row title; `limit: null` means unlimited.
interface LimiterStatus {
  used: number;
  limit: number | null;
  reset_at: number | null;
  'available?': boolean;
  [metric: string]: number | boolean | null;
}

interface Limiter {
  name: string;
  type: string;
  fingerprint: string;
  options: Record<string, unknown>;
  status: LimiterStatus | null;
}

interface LimitersResponse {
  total: number;
  page: number;
  count: number;
  limiters: Limiter[];
}

const PAGE_SIZE = 25;

const SORT: Accessors<Limiter> = {
  name: (l) => l.name,
  type: (l) => l.type,
  used: (l) => l.status?.used ?? 0,
  limit: (l) => l.status?.limit ?? null,
  usage: (l) => {
    const used = l.status?.used ?? 0;
    const limit = l.status?.limit ?? null;
    return limit && limit > 0 ? used / limit : 0;
  },
  status: (l) => ((l.status?.['available?'] ?? true) ? 'available' : 'exhausted'),
};

export default function Limiters() {
  const qc = useQueryClient();
  const meta = useMeta();
  const readOnly = () => meta.data?.read_only ?? false;
  const [page, setPage] = usePageParam();

  onMount(() => {
    document.title = `${t('nav.limiters')} — Wurk`;
  });

  // UI is 1-indexed for humans; the API is 0-indexed, so send page - 1.
  const q = useQuery<LimitersResponse>(() => ({
    queryKey: ['limiters', page()],
    queryFn: () =>
      getJSON<LimitersResponse>(`${basePath()}/api/limiters?page=${page() - 1}&count=${PAGE_SIZE}`),
    refetchInterval: 5000,
  }));

  // Drops the limiter's stats/state keys (counters → 0); skips CSRF, see
  // ApiController#skip_forgery_protection.
  const reset = useMutation(() => ({
    mutationFn: (name: string) => post(`${basePath()}/api/limiters/${encodeURIComponent(name)}/reset`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['limiters'] }),
    onError: notifyError,
  }));

  useResetPageOnEmpty(page, setPage, () => !q.isPending && !!q.data, () => (q.data?.limiters.length ?? 0) === 0);

  const { sorted, sort, toggle } = useSort(() => q.data?.limiters ?? [], SORT);

  const confirmReset = (name: string) =>
    window.confirm(t('actions.confirm', { action: t('actions.reset'), scope: name })) && reset.mutate(name);

  return (
    <Switch>
      <Match when={q.isPending}>
        <div>
          <PageHeader icon="fa-gauge" title={t('nav.limiters')} summary={t('summaries.limiters')} />
          <SkeletonTable rows={8} cols={readOnly() ? 6 : 7} />
        </div>
      </Match>
      <Match when={q.isError || !q.data}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Match>
      <Match when={q.data}>
        {(data) => (
          <div>
            <PageHeader icon="fa-gauge" title={t('nav.limiters')} summary={t('summaries.limiters')}>
              <span class="badge badge-muted">{formatNumber(data().total)}</span>
            </PageHeader>

            <Show when={sorted().length > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
              <div class="table-wrapper">
                <table>
                  <thead>
                    <tr>
                      <SortableTh label={t('table.name')} sortKey="name" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.type')} sortKey="type" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.used')} sortKey="used" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.limit')} sortKey="limit" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.usage')} sortKey="usage" sort={sort()} onSort={toggle} />
                      <SortableTh label={t('table.status')} sortKey="status" sort={sort()} onSort={toggle} />
                      <Show when={!readOnly()}><th /></Show>
                    </tr>
                  </thead>
                  <tbody>
                    <For each={sorted()}>
                      {(limiter) => {
                        const s = limiter.status;
                        const used = s?.used ?? 0;
                        const limit = s?.limit ?? null;
                        const pct = limit && limit > 0 ? Math.min((used / limit) * 100, 100) : 0;
                        const color = pct > 90 ? 'var(--danger)' : pct > 70 ? 'var(--warning)' : 'var(--success)';
                        const available = s?.['available?'] ?? true;
                        // Concurrent rows carry extra metric counters — show them on hover.
                        const metricTitle = s
                          ? Object.entries(s)
                              .filter(([k]) => !['used', 'limit', 'reset_at', 'available?'].includes(k))
                              .map(([k, v]) => `${k}=${v}`)
                              .join('  ')
                          : '';
                        return (
                          <tr>
                            <td style={{ 'font-weight': 500 }} title={limiter.name}>{limiter.name}</td>
                            <td><span class="badge badge-accent">{limiter.type}</span></td>
                            <td style={{ 'font-variant-numeric': 'tabular-nums' }} title={metricTitle}>
                              {formatNumber(used)}
                            </td>
                            <td style={{ 'font-variant-numeric': 'tabular-nums' }}>
                              {limit == null ? '∞' : formatNumber(limit)}
                            </td>
                            <td style={{ width: '160px' }}>
                              <Show
                                when={limit != null}
                                fallback={<span style={{ color: 'var(--text-muted)' }}>—</span>}
                              >
                                <div style={{ display: 'flex', 'align-items': 'center', gap: '0.5rem' }}>
                                  <div class="progress-bar-track" style={{ flex: 1 }}>
                                    <div class="progress-bar-fill" style={{ width: `${pct}%`, background: color }} />
                                  </div>
                                  <span style={{ 'font-size': '12px', color: 'var(--text-muted)', 'min-width': '36px' }}>
                                    {Math.round(pct)}%
                                  </span>
                                </div>
                              </Show>
                            </td>
                            <td>
                              <Show
                                when={available}
                                fallback={<span class="badge badge-danger">{t('limiters.exhausted')}</span>}
                              >
                                <span class="badge badge-success">{t('limiters.available')}</span>
                              </Show>
                            </td>
                            <Show when={!readOnly()}>
                              <td>
                                <button
                                  class="btn btn-sm"
                                  disabled={reset.isPending}
                                  onClick={() => confirmReset(limiter.name)}
                                >
                                  {t('actions.reset')}
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
              <Pagination page={page()} total={data().total} count={PAGE_SIZE} onChange={setPage} />
            </Show>
          </div>
        )}
      </Match>
    </Switch>
  );
}

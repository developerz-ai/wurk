import { useQuery } from '@tanstack/solid-query';
import { createEffect, createSignal, onCleanup, onMount, For, Show } from 'solid-js';
import { useSearchParams } from '@solidjs/router';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { ArgsValue } from '../components/ArgsValue';
import { SkeletonTable } from '../components/Skeleton';
import { relativeTime, truncate, isoTime, formatArgs } from '../utils';
import { basePath } from '../basePath';

type HitKind = 'queue' | 'retry' | 'scheduled' | 'dead';

// One row from GET /api/search — the backend ZSCAN/LRANGE substring scan across
// queues + retries + scheduled + dead (Wurk::Web::Search). Sorted-set kinds
// carry `at` (retry/scheduled/dead time) + error metadata; queue hits don't.
interface SearchHit {
  kind: HitKind;
  name: string;
  jid: string;
  klass: string;
  args: unknown;
  queue: string;
  enqueued_at: number | null;
  created_at: number | null;
  score?: number;
  at?: number;
  error_class?: string | null;
  error_message?: string | null;
  retry_count?: number | null;
}

interface SearchResponse {
  substr: string;
  total: number;
  hits: SearchHit[];
  truncated: boolean;
}

const MIN_CHARS = 2;
const DEBOUNCE_MS = 300;

// One badge tone per source set; queues ride along (Wurk extends Pro's search
// to the live queue LIST) so they get their own tone.
const KIND_BADGE: Record<HitKind, string> = {
  queue: 'badge-accent',
  retry: 'badge-warning',
  scheduled: 'badge-muted',
  dead: 'badge-danger',
};

// The pre-query landing: prompt + real-data sample chips (fetched only while
// this state is on screen — see the gated `sample` query below).
function EmptyState(props: { suggestions: () => string[]; onPick: (v: string) => void }) {
  return (
    <div class="search-empty">
      <div class="search-empty__icon">
        <i class="fa-solid fa-magnifying-glass" />
      </div>
      <p class="search-empty__title">{t('search.emptyTitle')}</p>
      <p class="search-empty__hint">{t('search.emptyHint')}</p>
      <Show when={props.suggestions().length > 0}>
        <div class="search-empty__chips">
          <span class="search-empty__chips-label">{t('search.try')}</span>
          <For each={props.suggestions()}>
            {(s) => (
              <button type="button" class="chip" onClick={() => props.onPick(s)}>
                {s}
              </button>
            )}
          </For>
        </div>
      </Show>
    </div>
  );
}

export default function Search() {
  const [sp, setSp] = useSearchParams();
  const [input, setInput] = createSignal((sp.q as string) ?? '');
  const [term, setTerm] = createSignal(input().trim());

  onMount(() => {
    document.title = `${t('nav.search')} — Wurk`;
  });

  // Debounce the raw input into the term that drives the query + URL, so a burst
  // of keystrokes issues one request against the final value, not one each.
  createEffect(() => {
    const next = input().trim();
    const id = setTimeout(() => {
      setTerm(next);
      setSp({ q: next || undefined });
    }, DEBOUNCE_MS);
    onCleanup(() => clearTimeout(id));
  });

  const active = () => term().length >= MIN_CHARS;

  // Server-side substring scan (budget-bounded). The term is in the query key so
  // each search caches independently and returning to a prior term is instant.
  const results = useQuery<SearchResponse>(() => ({
    queryKey: ['search', term()],
    queryFn: () =>
      fetch(`${basePath()}/api/search?substr=${encodeURIComponent(term())}`).then(
        (r) => r.json() as Promise<SearchResponse>,
      ),
    enabled: active(),
    staleTime: 10_000,
  }));

  // Empty-state suggestion chips: real job classes sampled from retries/dead so
  // the hint fits any app, not the demo. Gated to the empty state (no active term).
  const sample = useQuery<Array<{ entries?: Array<{ klass?: string }> }>>(() => ({
    queryKey: ['search-suggest'],
    queryFn: () =>
      Promise.all(
        [`${basePath()}/api/retries?page=0&count=10`, `${basePath()}/api/dead?page=0&count=10`].map((u) =>
          fetch(u).then((r) => r.json()),
        ),
      ),
    enabled: !active(),
    staleTime: 30_000,
  }));
  const suggestions = () =>
    Array.from(
      new Set(
        (sample.data ?? []).flatMap((s) => (s.entries ?? []).map((e) => e.klass)).filter(Boolean) as string[],
      ),
    ).slice(0, 5);

  // Sorted-set hits carry `at`; queue hits fall back to enqueue time. NaN when
  // neither is present — relativeTime/isoTime both render that as a safe dash.
  const whenOf = (h: SearchHit) => (typeof h.at === 'number' ? h.at : (h.enqueued_at ?? NaN));
  const count = () => results.data?.hits.length ?? 0;

  return (
    <div>
      <PageHeader icon="fa-magnifying-glass" title={t('nav.search')} summary={t('summaries.search')} />

      <form
        onSubmit={(e) => {
          e.preventDefault();
          setTerm(input().trim());
        }}
        style={{ display: 'flex', gap: '0.75rem', 'margin-bottom': '2rem' }}
      >
        <input
          class="input"
          type="search"
          placeholder={t('search.placeholder')}
          value={input()}
          onInput={(e) => setInput(e.currentTarget.value)}
          style={{ flex: 1, 'max-width': '480px' }}
        />
        <button type="submit" class="btn btn-accent">
          {t('actions.search')}
        </button>
      </form>

      <Show when={active()} fallback={<EmptyState suggestions={suggestions} onPick={setInput} />}>
        <Show when={!results.isLoading} fallback={<SkeletonTable rows={8} cols={6} />}>
          <Show
            when={!results.isError && results.data}
            fallback={<div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>}
          >
            {(data) => (
              <>
                <Show when={data().truncated}>
                  <div class="search-truncated" role="status">
                    <i class="fa-solid fa-triangle-exclamation" aria-hidden="true" />
                    <span>{t('search.truncated')}</span>
                  </div>
                </Show>

                <div class="search-count">
                  {count() === 1
                    ? t('search.result', { n: count(), term: term() })
                    : t('search.results', { n: count(), term: term() })}
                </div>

                <Show when={count() > 0} fallback={<div class="empty-state">{t('common.empty')}</div>}>
                  <div class="table-wrapper">
                    <table>
                      <thead>
                        <tr>
                          <th>{t('search.source')}</th>
                          <th>{t('table.jid')}</th>
                          <th>{t('table.class')}</th>
                          <th>{t('table.args')}</th>
                          <th>{t('table.error')}</th>
                          <th>{t('search.when')}</th>
                        </tr>
                      </thead>
                      <tbody>
                        <For each={data().hits}>
                          {(hit) => (
                            <tr>
                              <td>
                                <span class={`badge ${KIND_BADGE[hit.kind]}`}>{t(`search.kind.${hit.kind}`)}</span>
                              </td>
                              <td
                                title={hit.jid}
                                style={{ 'font-family': 'monospace', 'font-size': '12px', color: 'var(--text-muted)' }}
                              >
                                {truncate(hit.jid, 12)}
                              </td>
                              <td style={{ 'font-weight': 500 }}>{hit.klass}</td>
                              <td>
                                <ArgsValue str={formatArgs(hit.args)} max={40} />
                              </td>
                              <td style={{ color: 'var(--danger)' }}>
                                <Show
                                  when={hit.error_class}
                                  fallback={<span style={{ color: 'var(--text-muted)' }}>—</span>}
                                >
                                  <span title={hit.error_message ?? ''}>{truncate(hit.error_class, 28)}</span>
                                </Show>
                              </td>
                              <td title={isoTime(whenOf(hit))}>{relativeTime(whenOf(hit))}</td>
                            </tr>
                          )}
                        </For>
                      </tbody>
                    </table>
                  </div>
                </Show>
              </>
            )}
          </Show>
        </Show>
      </Show>
    </div>
  );
}

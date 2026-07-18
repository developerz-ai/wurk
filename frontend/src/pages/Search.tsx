import { useQuery } from '@tanstack/solid-query';
import { onMount, createSignal, For, Show } from 'solid-js';
import { useSearchParams } from '@solidjs/router';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs } from '../utils';
import { basePath } from '../basePath';

interface RetryEntry {
  jid: string;
  klass: string;
  args: unknown;
  error_class: string | null;
  error_message: string | null;
  failed_at: number;
  retry_at: number;
  retried_at: number | null;
  retry_count: number;
  score: number;
}

interface ScheduledEntry {
  jid: string;
  klass: string;
  args: unknown;
  score: number;
  at: number;
}

interface DeadEntry {
  jid: string;
  klass: string;
  args: unknown;
  error_class: string | null;
  error_message: string | null;
  failed_at: number;
  score: number;
}

interface RetriesResponse {
  total: number;
  page: number;
  count: number;
  entries: RetryEntry[];
}

interface ScheduledResponse {
  total: number;
  page: number;
  count: number;
  entries: ScheduledEntry[];
}

interface DeadResponse {
  total: number;
  page: number;
  count: number;
  entries: DeadEntry[];
}

function matches(term: string, jid: string, cls: string): boolean {
  const q = term.toLowerCase();
  return (jid ?? '').toLowerCase().includes(q) || (cls ?? '').toLowerCase().includes(q);
}

export default function Search() {
  const [sp, setSp] = useSearchParams();
  const [query, setQuery] = createSignal((sp.q as string) ?? '');
  const submitted = () => (sp.q as string) ?? '';

  onMount(() => {
    document.title = `${t('nav.search')} — Wurk`;
  });

  const retries = useQuery<RetriesResponse>(() => ({
    queryKey: ['search-retries'],
    queryFn: () =>
      fetch(`${basePath()}/api/retries?page=0&count=200`).then(
        (r) => r.json() as Promise<RetriesResponse>
      ),
    enabled: submitted().length >= 2,
  }));

  const scheduled = useQuery<ScheduledResponse>(() => ({
    queryKey: ['search-scheduled'],
    queryFn: () =>
      fetch(`${basePath()}/api/scheduled?page=0&count=200`).then(
        (r) => r.json() as Promise<ScheduledResponse>
      ),
    enabled: submitted().length >= 2,
  }));

  const dead = useQuery<DeadResponse>(() => ({
    queryKey: ['search-dead'],
    queryFn: () =>
      fetch(`${basePath()}/api/dead?page=0&count=200`).then(
        (r) => r.json() as Promise<DeadResponse>
      ),
    enabled: submitted().length >= 2,
  }));

  // Live sample of job classes for the empty-state suggestion chips — derived
  // from real data so it works for any app, not hardcoded to the demo.
  const sample = useQuery<Array<{ entries?: Array<{ klass?: string }> }>>(() => ({
    queryKey: ['search-suggest'],
    queryFn: () =>
      Promise.all(
        [`${basePath()}/api/retries?page=0&count=10`, `${basePath()}/api/dead?page=0&count=10`].map((u) =>
          fetch(u).then((r) => r.json())
        )
      ),
    staleTime: 30000,
  }));
  const suggestions = () =>
    Array.from(
      new Set(
        (sample.data ?? []).flatMap((s) => (s.entries ?? []).map((e) => e.klass)).filter(Boolean) as string[]
      )
    ).slice(0, 5);

  const runSearch = (term: string) => {
    setQuery(term);
    setSp({ q: term || undefined });
  };

  const filteredRetries = () =>
    submitted().length >= 2
      ? (retries.data?.entries ?? []).filter((e) => matches(submitted(), e.jid, e.klass))
      : [];

  const filteredScheduled = () =>
    submitted().length >= 2
      ? (scheduled.data?.entries ?? []).filter((e) => matches(submitted(), e.jid, e.klass))
      : [];

  const filteredDead = () =>
    submitted().length >= 2
      ? (dead.data?.entries ?? []).filter((e) => matches(submitted(), e.jid, e.klass))
      : [];

  const handleSearch = (e: Event) => {
    e.preventDefault();
    setSp({ q: query() || undefined });
  };

  const totalResults = () => filteredRetries().length + filteredScheduled().length + filteredDead().length;

  return (
    <div>
      <PageHeader icon="fa-magnifying-glass" title={t('nav.search')} summary={t('summaries.search')} />

      <form onSubmit={handleSearch} style={{ display: 'flex', gap: '0.75rem', 'margin-bottom': '2rem' }}>
        <input
          class="input"
          type="text"
          placeholder="Search by JID or class name…"
          value={query()}
          onInput={(e) => setQuery(e.currentTarget.value)}
          style={{ flex: 1, 'max-width': '480px' }}
        />
        <button type="submit" class="btn btn-accent">
          {t('actions.search')}
        </button>
      </form>

      <Show when={submitted().length < 2}>
        <div class="search-empty">
          <div class="search-empty__icon"><i class="fa-solid fa-magnifying-glass" /></div>
          <p class="search-empty__title">{t('search.emptyTitle')}</p>
          <p class="search-empty__hint">{t('search.emptyHint')}</p>
          <Show when={suggestions().length > 0}>
            <div class="search-empty__chips">
              <span class="search-empty__chips-label">{t('search.try')}</span>
              <For each={suggestions()}>
                {(s) => (
                  <button type="button" class="chip" onClick={() => runSearch(s)}>
                    {s}
                  </button>
                )}
              </For>
            </div>
          </Show>
        </div>
      </Show>

      <Show when={submitted().length >= 2}>
        <div style={{ 'margin-bottom': '0.75rem', color: 'var(--text-muted)', 'font-size': '13px' }}>
          {totalResults()} result{totalResults() !== 1 ? 's' : ''} for "{submitted()}"
        </div>
      </Show>

      <Show when={filteredRetries().length > 0}>
        <div style={{ 'margin-bottom': '2rem' }}>
          <h2 class="section-title" style={{ 'margin-bottom': '0.75rem' }}>
            Retries <span class="badge badge-warning">{filteredRetries().length}</span>
          </h2>
          <div class="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>{t('table.jid')}</th>
                  <th>{t('table.class')}</th>
                  <th>{t('table.args')}</th>
                  <th>{t('table.error')}</th>
                  <th>Count</th>
                  <th>{t('table.retry_at')}</th>
                </tr>
              </thead>
              <tbody>
                <For each={filteredRetries()}>
                  {(entry) => {
                    const argsStr = formatArgs(entry.args);
                    return (
                      <tr>
                        <td title={entry.jid} style={{ 'font-family': 'monospace', 'font-size': '12px', color: 'var(--text-muted)' }}>
                          {truncate(entry.jid, 12)}
                        </td>
                        <td style={{ 'font-weight': 500 }}>{entry.klass}</td>
                        <td title={argsStr}>{truncate(argsStr, 40)}</td>
                        <td title={entry.error_class ?? ''} style={{ color: 'var(--danger)' }}>
                          {truncate(entry.error_class, 25)}
                        </td>
                        <td>{entry.retry_count}</td>
                        <td>{relativeTime(entry.retry_at)}</td>
                      </tr>
                    );
                  }}
                </For>
              </tbody>
            </table>
          </div>
        </div>
      </Show>

      <Show when={filteredScheduled().length > 0}>
        <div style={{ 'margin-bottom': '2rem' }}>
          <h2 class="section-title" style={{ 'margin-bottom': '0.75rem' }}>
            Scheduled <span class="badge badge-accent">{filteredScheduled().length}</span>
          </h2>
          <div class="table-wrapper">
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
                <For each={filteredScheduled()}>
                  {(entry) => {
                    const argsStr = formatArgs(entry.args);
                    return (
                      <tr>
                        <td title={entry.jid} style={{ 'font-family': 'monospace', 'font-size': '12px', color: 'var(--text-muted)' }}>
                          {truncate(entry.jid, 12)}
                        </td>
                        <td style={{ 'font-weight': 500 }}>{entry.klass}</td>
                        <td title={argsStr}>{truncate(argsStr, 60)}</td>
                        <td>{relativeTime(entry.at)}</td>
                      </tr>
                    );
                  }}
                </For>
              </tbody>
            </table>
          </div>
        </div>
      </Show>

      <Show when={filteredDead().length > 0}>
        <div style={{ 'margin-bottom': '2rem' }}>
          <h2 class="section-title" style={{ 'margin-bottom': '0.75rem' }}>
            Dead <span class="badge badge-danger">{filteredDead().length}</span>
          </h2>
          <div class="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>{t('table.jid')}</th>
                  <th>{t('table.class')}</th>
                  <th>{t('table.args')}</th>
                  <th>{t('table.error')}</th>
                  <th>{t('table.failed_at')}</th>
                </tr>
              </thead>
              <tbody>
                <For each={filteredDead()}>
                  {(entry) => {
                    const argsStr = formatArgs(entry.args);
                    return (
                      <tr>
                        <td title={entry.jid} style={{ 'font-family': 'monospace', 'font-size': '12px', color: 'var(--text-muted)' }}>
                          {truncate(entry.jid, 12)}
                        </td>
                        <td style={{ 'font-weight': 500 }}>{entry.klass}</td>
                        <td title={argsStr}>{truncate(argsStr, 40)}</td>
                        <td title={entry.error_class ?? ''} style={{ color: 'var(--danger)' }}>
                          {truncate(entry.error_class, 25)}
                        </td>
                        <td>{relativeTime(entry.failed_at)}</td>
                      </tr>
                    );
                  }}
                </For>
              </tbody>
            </table>
          </div>
        </div>
      </Show>

      <Show when={submitted().length >= 2 && totalResults() === 0}>
        <div class="empty-state">{t('common.empty')}</div>
      </Show>
    </div>
  );
}

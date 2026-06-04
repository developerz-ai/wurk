import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { t } from '../i18n';
import { PageHeader } from '../components/PageHeader';
import { relativeTime, truncate, formatArgs } from '../utils';

interface RetryEntry {
  jid: string;
  klass: string;
  args: unknown;
  error_class: string;
  error_message: string;
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
  error_class: string;
  error_message: string;
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
  const [query, setQuery] = useState('');
  const [submitted, setSubmitted] = useState('');

  useEffect(() => {
    document.title = `${t('nav.search')} — Wurk`;
  }, []);

  const { data: retries } = useQuery<RetriesResponse>({
    queryKey: ['search-retries'],
    queryFn: () =>
      fetch('/wurk/api/retries?page=0&count=200').then(
        (r) => r.json() as Promise<RetriesResponse>
      ),
    enabled: submitted.length >= 2,
  });

  const { data: scheduled } = useQuery<ScheduledResponse>({
    queryKey: ['search-scheduled'],
    queryFn: () =>
      fetch('/wurk/api/scheduled?page=0&count=200').then(
        (r) => r.json() as Promise<ScheduledResponse>
      ),
    enabled: submitted.length >= 2,
  });

  const { data: dead } = useQuery<DeadResponse>({
    queryKey: ['search-dead'],
    queryFn: () =>
      fetch('/wurk/api/dead?page=0&count=200').then(
        (r) => r.json() as Promise<DeadResponse>
      ),
    enabled: submitted.length >= 2,
  });

  // Live sample of job classes for the empty-state suggestion chips — derived
  // from real data so it works for any app, not hardcoded to the demo.
  const { data: sample } = useQuery<Array<{ entries?: Array<{ klass?: string }> }>>({
    queryKey: ['search-suggest'],
    queryFn: () =>
      Promise.all(
        ['/wurk/api/retries?page=0&count=10', '/wurk/api/dead?page=0&count=10'].map((u) =>
          fetch(u).then((r) => r.json())
        )
      ),
    staleTime: 30000,
  });
  const suggestions = Array.from(
    new Set(
      (sample ?? []).flatMap((s) => (s.entries ?? []).map((e) => e.klass)).filter(Boolean) as string[]
    )
  ).slice(0, 5);

  const runSearch = (term: string) => {
    setQuery(term);
    setSubmitted(term);
  };

  const filteredRetries =
    submitted.length >= 2
      ? (retries?.entries ?? []).filter((e) => matches(submitted, e.jid, e.klass))
      : [];

  const filteredScheduled =
    submitted.length >= 2
      ? (scheduled?.entries ?? []).filter((e) => matches(submitted, e.jid, e.klass))
      : [];

  const filteredDead =
    submitted.length >= 2
      ? (dead?.entries ?? []).filter((e) => matches(submitted, e.jid, e.klass))
      : [];

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitted(query);
  };

  const totalResults = filteredRetries.length + filteredScheduled.length + filteredDead.length;

  return (
    <div>
      <PageHeader icon="fa-magnifying-glass" title={t('nav.search')} summary={t('summaries.search')} />

      <form onSubmit={handleSearch} style={{ display: 'flex', gap: '0.75rem', marginBottom: '2rem' }}>
        <input
          className="input"
          type="text"
          placeholder="Search by JID or class name…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          style={{ flex: 1, maxWidth: 480 }}
        />
        <button type="submit" className="btn btn-accent">
          {t('actions.search')}
        </button>
      </form>

      {submitted.length < 2 && (
        <div className="search-empty">
          <div className="search-empty__icon"><i className="fa-solid fa-magnifying-glass" /></div>
          <p className="search-empty__title">{t('search.emptyTitle')}</p>
          <p className="search-empty__hint">{t('search.emptyHint')}</p>
          {suggestions.length > 0 && (
            <div className="search-empty__chips">
              <span className="search-empty__chips-label">{t('search.try')}</span>
              {suggestions.map((s) => (
                <button key={s} type="button" className="chip" onClick={() => runSearch(s)}>
                  {s}
                </button>
              ))}
            </div>
          )}
        </div>
      )}

      {submitted.length >= 2 && (
        <div style={{ marginBottom: '0.75rem', color: 'var(--text-muted)', fontSize: 13 }}>
          {totalResults} result{totalResults !== 1 ? 's' : ''} for "{submitted}"
        </div>
      )}

      {filteredRetries.length > 0 && (
        <div style={{ marginBottom: '2rem' }}>
          <h2 className="section-title" style={{ marginBottom: '0.75rem' }}>
            Retries <span className="badge badge-warning">{filteredRetries.length}</span>
          </h2>
          <div className="table-wrapper">
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
                {filteredRetries.map((entry) => {
                  const argsStr = formatArgs(entry.args);
                  return (
                    <tr key={entry.jid}>
                      <td title={entry.jid} style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text-muted)' }}>
                        {truncate(entry.jid, 12)}
                      </td>
                      <td style={{ fontWeight: 500 }}>{entry.klass}</td>
                      <td title={argsStr}>{truncate(argsStr, 40)}</td>
                      <td title={entry.error_class} style={{ color: 'var(--danger)' }}>
                        {truncate(entry.error_class, 25)}
                      </td>
                      <td>{entry.retry_count}</td>
                      <td>{relativeTime(entry.retry_at)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {filteredScheduled.length > 0 && (
        <div style={{ marginBottom: '2rem' }}>
          <h2 className="section-title" style={{ marginBottom: '0.75rem' }}>
            Scheduled <span className="badge badge-accent">{filteredScheduled.length}</span>
          </h2>
          <div className="table-wrapper">
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
                {filteredScheduled.map((entry) => {
                  const argsStr = formatArgs(entry.args);
                  return (
                    <tr key={entry.jid}>
                      <td title={entry.jid} style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text-muted)' }}>
                        {truncate(entry.jid, 12)}
                      </td>
                      <td style={{ fontWeight: 500 }}>{entry.klass}</td>
                      <td title={argsStr}>{truncate(argsStr, 60)}</td>
                      <td>{relativeTime(entry.at)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {filteredDead.length > 0 && (
        <div style={{ marginBottom: '2rem' }}>
          <h2 className="section-title" style={{ marginBottom: '0.75rem' }}>
            Dead <span className="badge badge-danger">{filteredDead.length}</span>
          </h2>
          <div className="table-wrapper">
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
                {filteredDead.map((entry) => {
                  const argsStr = formatArgs(entry.args);
                  return (
                    <tr key={entry.jid}>
                      <td title={entry.jid} style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text-muted)' }}>
                        {truncate(entry.jid, 12)}
                      </td>
                      <td style={{ fontWeight: 500 }}>{entry.klass}</td>
                      <td title={argsStr}>{truncate(argsStr, 40)}</td>
                      <td title={entry.error_class} style={{ color: 'var(--danger)' }}>
                        {truncate(entry.error_class, 25)}
                      </td>
                      <td>{relativeTime(entry.failed_at)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {submitted.length >= 2 && totalResults === 0 && (
        <div className="empty-state">{t('common.empty')}</div>
      )}
    </div>
  );
}

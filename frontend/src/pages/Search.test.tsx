import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Search from './Search';
import { t } from '../i18n';

const NOW = Date.now() / 1000;

const RETRY_HIT = {
  kind: 'retry',
  name: 'retry',
  jid: 'jid-boom-1',
  klass: 'BoomJob',
  args: [1, 2],
  queue: 'default',
  enqueued_at: NOW - 100,
  created_at: NOW - 200,
  score: NOW + 60,
  at: NOW + 60,
  error_class: 'RuntimeError',
  error_message: 'kaboom',
  retry_count: 2,
};

const QUEUE_HIT = {
  kind: 'queue',
  name: 'default',
  jid: 'jid-boom-2',
  klass: 'BoomJob',
  args: [],
  queue: 'default',
  enqueued_at: NOW - 10,
  created_at: NOW - 20,
};

function mockFetch(searchBody: unknown) {
  return vi.fn((url: string) => {
    let body: unknown = { entries: [] };
    if (url.includes('/api/search')) body = searchBody;
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
  });
}

function renderSearch(path = '/search') {
  const history = createMemoryHistory();
  history.set({ value: path, replace: true });
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const result = render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path="/search" component={Search} />
      </MemoryRouter>
    </QueryClientProvider>
  ));
  return { ...result, history };
}

describe('Search', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('hits GET /api/search with the term and renders sorted-entry fields', async () => {
    const fetchMock = mockFetch({ substr: 'Boom', total: 2, hits: [RETRY_HIT, QUEUE_HIT], truncated: false });
    vi.stubGlobal('fetch', fetchMock);
    // Seed the term via the URL so the query fires without waiting on debounce.
    renderSearch('/search?q=Boom');

    // The backend endpoint is used — not the old per-set client-side scan.
    await waitFor(() =>
      expect(fetchMock.mock.calls.some(([u]) => String(u).includes('/api/search?substr=Boom'))).toBe(true),
    );

    // error_class (once always "—") now renders from the search payload.
    expect(await screen.findByText('RuntimeError')).toBeInTheDocument();
    expect(screen.getAllByText('BoomJob')).toHaveLength(2);
    // Kind badges: both the retry and the queue hit are surfaced.
    expect(screen.getByText(t('search.kind.retry'))).toBeInTheDocument();
    expect(screen.getByText(t('search.kind.queue'))).toBeInTheDocument();
  });

  it('shows the truncated banner when the scan stopped early', async () => {
    vi.stubGlobal('fetch', mockFetch({ substr: 'Boom', total: 1, hits: [RETRY_HIT], truncated: true }));
    renderSearch('/search?q=Boom');
    expect(await screen.findByText(t('search.truncated'))).toBeInTheDocument();
  });

  it('shows the empty prompt and skips the search endpoint below the min length', async () => {
    const fetchMock = mockFetch({ substr: '', total: 0, hits: [], truncated: false });
    vi.stubGlobal('fetch', fetchMock);
    renderSearch('/search');

    expect(await screen.findByText(t('search.emptyTitle'))).toBeInTheDocument();
    expect(fetchMock.mock.calls.some(([u]) => String(u).includes('/api/search'))).toBe(false);
  });

  it('debounces typed input into a single /api/search request', async () => {
    const fetchMock = mockFetch({ substr: 'Xyz', total: 0, hits: [], truncated: false });
    vi.stubGlobal('fetch', fetchMock);
    renderSearch('/search');

    const input = await screen.findByPlaceholderText(t('search.placeholder'));
    fireEvent.input(input, { target: { value: 'Xyz' } });

    await waitFor(() =>
      expect(fetchMock.mock.calls.some(([u]) => String(u).includes('/api/search?substr=Xyz'))).toBe(true),
    );
  });

  it('resyncs the field and results when the URL query changes (history navigation)', async () => {
    const fetchMock = vi.fn((url: string) => {
      let body: unknown = { entries: [] };
      if (url.includes('/api/search?substr=Boom')) body = { substr: 'Boom', total: 1, hits: [RETRY_HIT], truncated: false };
      else if (url.includes('/api/search?substr=Other')) body = { substr: 'Other', total: 1, hits: [QUEUE_HIT], truncated: false };
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
    });
    vi.stubGlobal('fetch', fetchMock);
    const { history } = renderSearch('/search?q=Boom');

    const input = (await screen.findByPlaceholderText(t('search.placeholder'))) as HTMLInputElement;
    await waitFor(() => expect(input.value).toBe('Boom'));
    expect(await screen.findByText('RuntimeError')).toBeInTheDocument();

    // Back/forward navigation (or any same-route ?q= change) must drive the
    // field + results without the user re-typing.
    history.set({ value: '/search?q=Other' });

    await waitFor(() => expect(input.value).toBe('Other'));
    await waitFor(() =>
      expect(fetchMock.mock.calls.some(([u]) => String(u).includes('/api/search?substr=Other'))).toBe(true),
    );
    expect(await screen.findByText(t('search.kind.queue'))).toBeInTheDocument();
  });
});

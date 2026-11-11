import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Dashboard, { rangeIndexForDays } from './Dashboard';
import { t } from '../i18n';
import { requests, renderPage, stubFetch } from '../test-page';

// The charts need a measured container width under jsdom; the dashboard's own
// numbers are what these tests are about, so stub them to a marker element.
vi.mock('../components/charts', () => ({
  AreaChart: () => <div data-testid="areachart" />,
}));

// No EventSource in jsdom, and the live stream is not what is under test.
vi.mock('../hooks/useSSE', () => ({
  useSSE: () => ({ stats: () => null, connected: () => false }),
}));

const STATS = { processed: 1200, failed: 12, enqueued: 3, busy: 1, scheduled: 4, retries: 0, dead: 2, latency: 0.4, processes: 2, queues: [] };
const HISTORY = { bucket: '1m', window: 3600, series: [] };

/** Route every fetch the page makes; `stats` decides which branch renders. */
function mockFetch(stats: 'ok' | 'error' | 'empty') {
  return vi.fn((url: string) => {
    if (url.includes('/api/history/')) {
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(HISTORY) } as Response);
    }
    if (stats === 'error') return Promise.reject(new Error('stats unavailable'));
    const body = stats === 'empty' ? null : STATS;
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
  });
}

function renderDashboard() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const history = createMemoryHistory();
  history.set({ value: '/', replace: true });
  return render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path="/" component={Dashboard} />
      </MemoryRouter>
    </QueryClientProvider>
  ));
}

/**
 * The dashboard is the product's front page, and for a while it had no `<h1>` at
 * all — it was one of two pages that skipped `PageHeader`. Fixing the populated
 * state alone is not enough: a visitor whose API is down or whose realm is idle
 * sees a different branch, and each one has to title the document too.
 */
describe('Dashboard heading', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // Each case waits for copy unique to its branch BEFORE asserting the heading.
  // Waiting on the h1 alone passes on the loading frame, which always had one —
  // so the assertion has to be pinned to the branch it claims to cover.
  const BRANCHES = [
    { state: 'ok', marker: 'Processed' },
    { state: 'error', marker: 'Error loading data' },
    { state: 'empty', marker: 'No items' },
  ] as const;

  for (const { state, marker } of BRANCHES) {
    it(`renders exactly one h1 in the ${state} state`, async () => {
      vi.stubGlobal('fetch', mockFetch(state));
      const { container } = renderDashboard();
      // findAllBy: the populated state prints "Processed" twice, as a card label
      // and again in the chart legend.
      expect((await screen.findAllByText(marker)).length).toBeGreaterThan(0);
      expect(container.querySelectorAll('h1')).toHaveLength(1);
      expect(container.querySelector('h1')?.textContent).toBe('Dashboard');
    });
  }
});

describe('Sidekiq Web ?days=N', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('picks the narrowest range covering N days, ignoring anything outside 1..180', () => {
    expect([undefined, '0', 'x', '181', '1.5'].map(rangeIndexForDays)).toEqual([0, 0, 0, 0, 0]);
    expect(['1', '2', '7', '8', '30', '180'].map(rangeIndexForDays)).toEqual([1, 2, 2, 3, 3, 3]);
  });

  it('opens the 7d history for ?days=7', async () => {
    const fetchMock = stubFetch((url) => (url.pathname.includes('/api/history/') ? HISTORY : url.pathname.endsWith('/api/stats') ? STATS : []));
    renderPage('/?days=7', '/', Dashboard);

    await screen.findByRole('heading', { level: 1 });
    const history = requests(fetchMock).find(({ url }) => url.pathname.includes('/api/history/'))!;
    expect(history.url.pathname).toBe('/wurk/api/history/5m');
    expect(history.url.searchParams.get('window')).toBe('7d');
  });
});

describe('Health notices strip', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('shows what wurk verify would warn about from /api/processes and /api/queues', async () => {
    stubFetch((url) => {
      if (url.pathname.includes('/api/history/')) return HISTORY;
      if (url.pathname.endsWith('/api/stats')) return STATS;
      if (url.pathname.endsWith('/api/processes')) return [{ identity: 'w:1', version: '1.14.0', cores: 4 }];
      return [{ name: 'orphan', size: 3, paused: false, consumers: 0 }];
    });
    renderPage('/', '/', Dashboard);

    expect(await screen.findByText(t('notices.unconsumed', { names: 'orphan' }))).toBeInTheDocument();
    expect(screen.getByRole('region', { name: t('notices.title') })).toBeInTheDocument();
  });
});

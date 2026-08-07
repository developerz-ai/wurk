import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Dashboard from './Dashboard';

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

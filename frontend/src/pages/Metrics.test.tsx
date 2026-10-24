import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Metrics from './Metrics';

// Stub the hand-rolled SVG charts so chart logic (one series per queue/field,
// pivoted rows) is observable without a real layout — the charts need a measured
// container width to render under jsdom. Each series' `name ?? key` is rendered
// into a distinct testid so the per-queue latency lines and the throughput area
// series can be told apart, mirroring the old recharts <Line>/<Area> mock.
vi.mock('../components/charts', () => {
  type Series = { key: string; name?: string };
  return {
    AreaChart: (props: { series: Series[] }) => (
      <div data-testid="areachart">
        {props.series.map((s) => (
          <span data-testid="area">{s.name ?? s.key}</span>
        ))}
      </div>
    ),
    LineChart: (props: { series: Series[] }) => (
      <div data-testid="linechart">
        {props.series.map((s) => (
          <span data-testid="line">{s.name ?? s.key}</span>
        ))}
      </div>
    ),
    BarChart: () => <div data-testid="barchart" />,
  };
});

function renderMetrics(path = '/metrics') {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const history = createMemoryHistory();
  history.set({ value: path, replace: true });
  return render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path="/metrics" component={Metrics} />
        <Route path="/metrics/:klass" component={Metrics} />
      </MemoryRouter>
    </QueryClientProvider>
  ));
}

// The Metrics toolbar's four range tabs, as the exact URLs they request.
// The mock dispatches on the whole URL string, so a corrupted bucket or a
// dropped query parameter lands on an unmapped URL instead of quietly
// matching a substring — the panel it feeds stays empty and the test fails.
const RANGE_URLS = [
  { bucket: '1m', window: '24h', windowSeconds: 86_400, minutes: 60 },
  { bucket: '1m', window: '24h', windowSeconds: 86_400, minutes: 1_440 },
  { bucket: '5m', window: '7d', windowSeconds: 604_800, minutes: 10_080 },
  { bucket: '1h', window: '30d', windowSeconds: 2_592_000, minutes: 43_200 },
];

// Route the component's fetches by their exact URL. Defaults render an
// empty-but-valid page; each test overrides the payload it cares about.
// Every requested URL is recorded on `urls`, so a test can pin the strings
// the page asks for rather than only what it renders.
function mockFetch(
  opts: {
    queueHistory?: unknown;
    snapshots?: unknown[];
    topJobs?: unknown[];
    series?: unknown[];
    stats?: unknown;
  } = {},
) {
  const { queueHistory = { bucket: '1m', window: 86400, queues: [] }, snapshots = [], topJobs = [], series = [], stats = {} } = opts;

  const bodies = new Map<string, unknown>([
    ['/wurk/api/stats', stats],
    ['/wurk/api/history/snapshots?limit=1000', { snapshots }],
  ]);
  for (const r of RANGE_URLS) {
    bodies.set(`/wurk/api/history/${r.bucket}?window=${r.window}`, { bucket: r.bucket, window: r.windowSeconds, series });
    bodies.set(`/wurk/api/metrics?minutes=${r.minutes}`, { minutes: r.minutes, top_jobs: topJobs });
    bodies.set(`/wurk/api/queue-history/${r.bucket}?window=${r.window}`, queueHistory);
  }

  const urls: string[] = [];
  const fetchMock = vi.fn((url: string) => {
    urls.push(url);
    // An unmapped URL is one the page should never ask for (or one whose
    // shape drifted): answer with an empty body so nothing renders from it
    // and the recorded-URL assertion reports the mismatch.
    const body = bodies.get(url) ?? {};
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
  });
  return Object.assign(fetchMock, { urls });
}

describe('Metrics page', () => {
  beforeEach(() => {
    vi.stubGlobal('fetch', mockFetch({ stats: { processed: 100, failed: 5, latency: 1.2, processes: 4 } }));
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('gives the document exactly one h1', async () => {
    // Not just "a heading exists": this page began at h2 for a while, because it was
    // one of two that skipped <PageHeader>. Rendered, not read from the source.
    const { container } = renderMetrics();
    await screen.findByText('Total Processed');
    const h1s = container.querySelectorAll('h1');
    expect(h1s).toHaveLength(1);
    expect(h1s[0]?.textContent).toBe('Metrics');
  });

  it('renders the four metric cards', async () => {
    renderMetrics();
    expect(await screen.findByText('Total Processed')).toBeInTheDocument();
    expect(screen.getByText('Failed Jobs')).toBeInTheDocument();
    expect(screen.getByText('Avg Latency')).toBeInTheDocument();
    expect(screen.getByText('Active Workers')).toBeInTheDocument();
  });

  it('renders the throughput, queue depth, and top-job sections', async () => {
    renderMetrics();
    expect(await screen.findByText('Throughput & Failures')).toBeInTheDocument();
    expect(screen.getByText('Queue Depth')).toBeInTheDocument();
    expect(screen.getByText('Top Job Types (Volume)')).toBeInTheDocument();
  });

  it('lists top job types with their share of total volume', async () => {
    vi.stubGlobal(
      'fetch',
      mockFetch({
        stats: { processed: 100, failed: 5, latency: 1.2, processes: 4 },
        topJobs: [
          { klass: 'App::FooJob', processed: 100, failed: 20, runtime_ms: 0 },
          { klass: 'BarJob', processed: 50, failed: 0, runtime_ms: 0 },
        ],
      }),
    );
    renderMetrics();
    // `processed` already counts failures (Sidekiq's `p`), so volume is
    // processed alone: foo = 100, bar = 50, total = 150 → 67% / 33%.
    expect(await screen.findByText('FooJob')).toBeInTheDocument();
    expect(screen.getByText('67%')).toBeInTheDocument();
    expect(screen.getByText('33%')).toBeInTheDocument();
  });

  it('shows the throughput empty state when there is no history', async () => {
    renderMetrics();
    await waitFor(() => expect(screen.getByText(/No history yet/i)).toBeInTheDocument());
  });

  it('switches the time range when a segment is clicked', async () => {
    renderMetrics();
    const btn = await screen.findByRole('tab', { name: '24h' });
    fireEvent.click(btn);
    await waitFor(() => expect(btn.getAttribute('aria-selected')).toBe('true'));
  });
});

describe('Metrics — queue latency history', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('renders one latency line per queue when data exists', async () => {
    const at = 1_781_000_000;
    vi.stubGlobal(
      'fetch',
      mockFetch({
        stats: { processed: 1, failed: 0, latency: 0, processes: 1 },
        queueHistory: {
          bucket: '1m',
          window: 86400,
          queues: [
            { name: 'default', points: [{ at, size: 5, latency: 1.2 }] },
            { name: 'critical', points: [{ at, size: 2, latency: 0.4 }] },
          ],
        },
      }),
    );
    renderMetrics();
    expect(await screen.findByText('Queue Latency (seconds)')).toBeInTheDocument();
    const lines = screen.getAllByTestId('line').map((n) => n.textContent);
    expect(lines).toContain('default');
    expect(lines).toContain('critical');
  });

  it('hides the latency section when there is no queue latency', async () => {
    vi.stubGlobal('fetch', mockFetch({ stats: { processed: 1, failed: 0, latency: 0, processes: 1 } }));
    renderMetrics();
    await screen.findByText('Throughput & Failures');
    expect(screen.queryByText('Queue Latency (seconds)')).toBeNull();
  });
});

describe('Metrics — historical snapshots', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('is hidden when the history:metrics stream is empty', async () => {
    vi.stubGlobal('fetch', mockFetch({ stats: { processed: 1, failed: 0, latency: 0, processes: 1 } }));
    renderMetrics();
    await screen.findByText('Throughput & Failures');
    expect(screen.queryByText('Historical Snapshots')).toBeNull();
  });

  it('charts the backlog gauge fields and hides the cumulative counters', async () => {
    const snapshots = [{ at: 1_781_000_000, processed: 100, failures: 2, enqueued: 5, dead: 1 }];
    vi.stubGlobal('fetch', mockFetch({ stats: { processed: 1, failed: 0, latency: 0, processes: 1 }, snapshots }));
    renderMetrics();
    expect(await screen.findByText('Historical Snapshots')).toBeInTheDocument();
    const lines = screen.getAllByTestId('line').map((n) => n.textContent);
    expect(lines).toContain('enqueued');
    expect(lines).toContain('dead');
    expect(lines).not.toContain('processed');
    expect(lines).not.toContain('failures');
  });
});

describe('Metrics — requested API URLs', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('requests the queue history with the range bucket and the window parameter', async () => {
    const at = 1_781_000_000;
    const fetchMock = mockFetch({
      stats: { processed: 1, failed: 0, latency: 0, processes: 1 },
      queueHistory: {
        bucket: '5m',
        window: 604_800,
        queues: [{ name: 'default', points: [{ at, size: 5, latency: 1.2 }] }],
      },
    });
    vi.stubGlobal('fetch', fetchMock);
    renderMetrics();
    // Wait for both independent queue-history queries to land. The assertions
    // below are about the recorded URLs, so their render gates must not be
    // able to suppress them when the requested URL is wrong.
    await screen.findByText('Queue Latency (seconds)');
    await waitFor(() => expect(screen.getByTestId('barchart')).toBeInTheDocument());

    const urls = fetchMock.urls;
    // Two call sites ask for the queue history — the depth panel and the
    // latency panel — and both must ask for the same exact URL: the range's
    // bucket interpolated into the path, with the window as a parameter.
    expect(urls.filter((u) => u.startsWith('/wurk/api/queue-history/'))).toEqual([
      '/wurk/api/queue-history/5m?window=7d',
      '/wurk/api/queue-history/5m?window=7d',
    ]);
    // Nothing else the default range requests may drift either.
    expect([...new Set(urls)].sort()).toEqual([
      '/wurk/api/history/5m?window=7d',
      '/wurk/api/history/snapshots?limit=1000',
      '/wurk/api/metrics?minutes=10080',
      '/wurk/api/queue-history/5m?window=7d',
      '/wurk/api/stats',
    ]);
  });

  it('requests the historical snapshots with their limit parameter', async () => {
    const fetchMock = mockFetch({
      stats: { processed: 1, failed: 0, latency: 0, processes: 1 },
      snapshots: [{ at: 1_781_000_000, processed: 100, failures: 2, enqueued: 5, dead: 1 }],
    });
    vi.stubGlobal('fetch', fetchMock);
    renderMetrics();
    // The panel renders only after the snapshots response lands.
    expect(await screen.findByText('Historical Snapshots')).toBeInTheDocument();

    expect(fetchMock.urls.filter((u) => u.startsWith('/wurk/api/history/snapshots'))).toEqual([
      '/wurk/api/history/snapshots?limit=1000',
    ]);
  });
});

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
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

function renderMetrics() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(() => (
    <QueryClientProvider client={client}>
      <Metrics />
    </QueryClientProvider>
  ));
}

// Route the component's fetches by URL. Defaults render an empty-but-valid page;
// each test overrides the payload it cares about.
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
  return vi.fn((url: string) => {
    let body: unknown = {};
    // /history/snapshots must be matched before the /history/ rollup route.
    if (url.includes('/history/snapshots')) body = { snapshots };
    else if (url.includes('/queue-history/')) body = queueHistory;
    else if (url.includes('/history/')) body = { bucket: '1m', window: 86400, series };
    else if (url.includes('/metrics')) body = { minutes: 60, top_jobs: topJobs };
    else if (url.includes('/stats')) body = stats;
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
  });
}

describe('Metrics page', () => {
  beforeEach(() => {
    vi.stubGlobal('fetch', mockFetch({ stats: { processed: 100, failed: 5, latency: 1.2, processes: 4 } }));
  });
  afterEach(() => {
    vi.unstubAllGlobals();
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
          { klass: 'App::FooJob', processed: 80, failed: 20, runtime_ms: 0 },
          { klass: 'BarJob', processed: 50, failed: 0, runtime_ms: 0 },
        ],
      }),
    );
    renderMetrics();
    // foo = 100, bar = 50, total = 150 → 67% / 33%.
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

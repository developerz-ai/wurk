import React from 'react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, waitFor, cleanup } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import Metrics from './Metrics';

// Stub Recharts so the per-queue chart logic (one <Line> per queue, pivoted
// rows) is observable without a real layout — ResponsiveContainer renders
// nothing under jsdom otherwise. Each Line exposes its dataKey as text.
vi.mock('recharts', () => {
  const Pass = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>;
  return {
    ResponsiveContainer: Pass,
    LineChart: ({ children }: { children?: React.ReactNode }) => (
      <div data-testid="linechart">{children}</div>
    ),
    Line: ({ dataKey }: { dataKey: string }) => <span data-testid="line">{dataKey}</span>,
    BarChart: Pass,
    Bar: () => null,
    XAxis: () => null,
    YAxis: () => null,
    CartesianGrid: () => null,
    Tooltip: () => null,
    Legend: () => null,
  };
});

function renderMetrics() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <Metrics />
    </QueryClientProvider>
  );
}

// Route the component's three fetches by URL; the queue-history payload is the
// one under test, the others return empty so the page renders. `queueOk: false`
// drives the queue-history error path.
function mockFetch(queueHistory: unknown, queueOk = true, snapshots: unknown[] = []) {
  return vi.fn((url: string) => {
    let body: unknown = {};
    let ok = true;
    // /history/snapshots must be matched before the /history/ rollup route.
    if (url.includes('/history/snapshots')) body = { snapshots };
    else if (url.includes('/queue-history/')) {
      body = queueHistory;
      ok = queueOk;
    } else if (url.includes('/history/')) body = { bucket: '1m', window: 86400, series: [] };
    else if (url.includes('/metrics')) body = { minutes: 60, top_jobs: [] };
    return Promise.resolve({ ok, status: ok ? 200 : 400, json: () => Promise.resolve(body) } as Response);
  });
}

describe('QueueGaugeCharts', () => {
  beforeEach(() => {
    vi.stubGlobal('fetch', mockFetch({ bucket: '1m', window: 86400, queues: [] }));
  });
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('always renders the section heading', async () => {
    renderMetrics();
    expect(await screen.findByText('Queue Size & Latency')).toBeDefined();
  });

  it('shows the empty state when no queue history exists', async () => {
    renderMetrics();
    await waitFor(() =>
      expect(screen.getByText(/No queue history yet/i)).toBeDefined()
    );
    expect(screen.queryByText('Depth (jobs)')).toBeNull();
  });

  it('renders a size and a latency chart with one line per queue', async () => {
    const at = 1_781_000_000;
    vi.stubGlobal(
      'fetch',
      mockFetch({
        bucket: '1m',
        window: 86400,
        queues: [
          { name: 'default', points: [{ at, size: 5, latency: 1.2 }] },
          { name: 'critical', points: [{ at, size: 0, latency: 0 }] },
        ],
      })
    );

    renderMetrics();

    // Both gauge charts render (size + latency).
    await waitFor(() => expect(screen.getByText('Depth (jobs)')).toBeDefined());
    expect(screen.getByText('Latency (seconds)')).toBeDefined();

    // One <Line> per queue in each of the two charts → each queue name twice.
    const lines = screen.getAllByTestId('line').map((n) => n.textContent);
    expect(lines.filter((k) => k === 'default')).toHaveLength(2);
    expect(lines.filter((k) => k === 'critical')).toHaveLength(2);

    // Empty state is gone once there's data.
    expect(screen.queryByText(/No queue history yet/i)).toBeNull();
  });

  it('shows an error state (not the empty state) when the API fails', async () => {
    vi.stubGlobal('fetch', mockFetch({ error: 'bucket must be one of …' }, false));

    renderMetrics();

    await waitFor(() => expect(screen.getByText('Error loading data')).toBeDefined());
    expect(screen.queryByText(/No queue history yet/i)).toBeNull();
    expect(screen.queryByText('Depth (jobs)')).toBeNull();
  });
});

describe('HistoricalSnapshots', () => {
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('shows the empty state when the history:metrics stream is empty', async () => {
    vi.stubGlobal('fetch', mockFetch({ bucket: '1m', window: 86400, queues: [] }, true, []));
    renderMetrics();

    expect(await screen.findByText('Historical Snapshots')).toBeDefined();
    await waitFor(() => expect(screen.getByText(/No snapshots yet/i)).toBeDefined());
  });

  it('charts the backlog gauge fields and hides the cumulative counters', async () => {
    const snapshots = [{ at: 1_781_000_000, processed: 100, failures: 2, enqueued: 5, dead: 1 }];
    vi.stubGlobal('fetch', mockFetch({ bucket: '1m', window: 86400, queues: [] }, true, snapshots));
    renderMetrics();

    const lines = (await screen.findAllByTestId('line')).map((n) => n.textContent);

    // backlog gauges charted…
    expect(lines).toContain('enqueued');
    expect(lines).toContain('dead');
    // …cumulative counters are not (HistoryCharts shows throughput instead).
    expect(lines).not.toContain('processed');
    expect(lines).not.toContain('failures');
  });
});

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import Busy from './Busy';
import { t } from '../i18n';
import { TICK_MS, __resetTick, useLiveTick } from '../tick';

const NOW = Date.now() / 1000;

const PROCESSES = [
  {
    identity: 'host-a:100:aaaa',
    pid: 100,
    hostname: 'host-a',
    tag: 'app',
    queues: ['default'],
    labels: [],
    concurrency: 10,
    busy: 3,
    quiet: false,
    beat: NOW - 5,
    rss: 262144, // 256 MB
    rtt_us: 1200,
    started_at: NOW - 3600,
    cpu_model: 'AMD EPYC 7702P 64-Core Processor',
    cores: 64,
    memory_total_kb: 16777216, // 16 GB
    version: '1.0.0',
  },
  {
    identity: 'host-a:101:bbbb',
    pid: 101,
    hostname: 'host-a',
    tag: 'app',
    queues: ['default'],
    labels: [],
    concurrency: 10,
    busy: 2,
    quiet: false,
    beat: NOW - 4,
    rss: 262144,
    rtt_us: 900,
    started_at: NOW - 3600,
    cpu_model: 'AMD EPYC 7702P 64-Core Processor',
    cores: 64,
    memory_total_kb: 16777216,
    version: '1.0.0',
  },
  {
    identity: 'host-b:200:cccc',
    pid: 200,
    hostname: 'host-b',
    tag: 'app',
    queues: ['critical'],
    labels: ['canary'],
    concurrency: 5,
    busy: 0,
    quiet: false,
    beat: NOW - 8,
    rss: 131072,
    rtt_us: 700,
    started_at: NOW - 60,
    cpu_model: 'Intel Xeon',
    cores: 8,
    memory_total_kb: 8388608,
    version: '1.0.0',
  },
];

const WORK = [
  {
    process_id: 'host-a:100:aaaa',
    thread_id: 't1',
    queue: 'default',
    klass: 'HardJob',
    args: [1],
    jid: 'jid-running-1',
    run_at: NOW - 30,
  },
  {
    process_id: 'host-b:200:cccc',
    thread_id: 't9',
    queue: 'critical',
    klass: 'OtherJob',
    args: [],
    jid: 'jid-other',
    run_at: NOW - 10,
  },
];

function mockFetch() {
  return vi.fn((url: string) => {
    let body: unknown = {};
    if (url.includes('/api/processes')) body = PROCESSES;
    else if (url.includes('/api/workers')) body = WORK;
    else if (url.includes('/api/meta')) body = { read_only: true };
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
  });
}

function renderBusy() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(() => (
    <QueryClientProvider client={client}>
      <Busy />
    </QueryClientProvider>
  ));
}

describe('Busy', () => {
  beforeEach(() => {
    vi.stubGlobal('fetch', mockFetch());
    // jsdom has no <dialog> top-layer support; the modal's content visibility
    // is signal-driven, so stubbing these is enough for showModal()/close().
    HTMLDialogElement.prototype.showModal = vi.fn();
    HTMLDialogElement.prototype.close = vi.fn();
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('groups processes into one section per host', async () => {
    renderBusy();
    expect(await screen.findByText('host-a')).toBeInTheDocument();
    expect(screen.getByText('host-b')).toBeInTheDocument();
    // Host badge: total processes; host-a folds two processes into one header.
    expect(screen.getByText('2 hosts')).toBeInTheDocument();
    expect(screen.getByText('3 processes')).toBeInTheDocument();
  });

  it('shows host hardware facts: CPU model, cores and RAM usage', async () => {
    renderBusy();
    expect(await screen.findByText(/AMD EPYC 7702P/)).toBeInTheDocument();
    expect(screen.getByText('64 cores')).toBeInTheDocument();
    // host-a: 2 × 256 MB RSS of 16 GB total.
    expect(screen.getByText(/512 MB \/ 16\.0 GB/)).toBeInTheDocument();
  });

  function stubProcesses(rows: unknown[]) {
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => ({
        ok: true,
        status: 200,
        json: async () => (url.includes('/api/processes') ? rows : url.includes('/api/meta') ? { read_only: true } : []),
      }) as Response),
    );
  }

  // A pod's heartbeat carries the node's cores and RAM; the cgroup limits are
  // what the process can use, so they are the figures shown.
  it('shows a container limit instead of the node RAM and cores', async () => {
    stubProcesses([{ ...PROCESSES[2], cpu_limit: 1.5, memory_limit_kb: 2097152, memory_total_kb: 32505856 }]);
    renderBusy();

    expect(await screen.findByText(/128 MB \/ 2\.0 GB limit/)).toBeInTheDocument();
    expect(screen.getByText(t('busy.cpu_limit', { n: '1.5' }))).toBeInTheDocument();
    expect(screen.getByTitle(t('busy.host_cores', { n: 8 }))).toBeInTheDocument();
    expect(screen.queryByText(/31\.0 GB/)).toBeNull();
  });

  // One process per host is a Kubernetes fleet: every pod's card shares one
  // grid and carries its hostname, with no per-host header row.
  it('puts single-process hosts in one grid of cards titled by hostname', async () => {
    const pods = [0, 1, 2].map((i) => ({ ...PROCESSES[2], identity: `pod-${i}:1:x`, hostname: `pod-${i}`, pid: 1 }));
    stubProcesses(pods);
    const { container } = renderBusy();

    expect(await screen.findByText('pod-0')).toBeInTheDocument();
    expect(container.querySelectorAll('.busy-host')).toHaveLength(0);
    expect(container.querySelectorAll('.busy-grid')).toHaveLength(1);
    expect(container.querySelectorAll('.busy-grid > .card')).toHaveLength(3);
  });

  it('collapses a long queue list behind a toggle', async () => {
    const queues = Array.from({ length: 10 }, (_, i) => `q${i}`);
    stubProcesses([{ ...PROCESSES[2], queues }]);
    renderBusy();

    const more = await screen.findByText(t('busy.more_queues', { n: 4 }));
    expect(screen.queryByText('q9')).toBeNull();
    fireEvent.click(more);
    expect(screen.getByText('q9')).toBeInTheDocument();
    // The toggle does not open the process detail.
    expect(screen.queryByText(t('busy.running_jobs'))).toBeNull();
  });

  // Every poll rebuilds the host groups; the cards must update in place, not
  // remount, or an open queue list folds up and the toggle loses focus.
  // Every poll rebuilds the row objects. A card must take the new values in
  // place, not remount (an open queue list would fold up and focus drop), and
  // a card added in front must not shift another worker's state onto it.
  it('updates a card in place across a poll, keyed by process', async () => {
    const queues = Array.from({ length: 10 }, (_, i) => `q${i}`);
    const pod = (host: string, busy: number) => ({ ...PROCESSES[2], identity: `${host}:1:x`, hostname: host, queues, busy });
    let rows = [pod('pod-b', 1)];
    const fetchMock = vi.fn(async (url: string) => ({
      ok: true,
      status: 200,
      json: async () => (url.includes('/api/processes') ? rows : []),
    }) as Response);
    vi.stubGlobal('fetch', fetchMock);
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    render(() => (
      <QueryClientProvider client={client}>
        <Busy />
      </QueryClientProvider>
    ));

    const toggle = await screen.findByText(t('busy.more_queues', { n: 4 }));
    const card = toggle.closest('.card');
    fireEvent.click(toggle);
    expect(screen.getByText('q9')).toBeInTheDocument();

    rows = [pod('pod-a', 0), pod('pod-b', 4)];
    await client.invalidateQueries({ queryKey: ['processes'] });
    await screen.findByText('pod-a');

    const podB = screen.getByText('pod-b').closest('.card');
    expect(podB).toBe(card);
    expect(podB).toHaveTextContent('4 / 5');
    expect(podB).toHaveTextContent('q9');
    // pod-a, new and in front, did not inherit pod-b's open list.
    expect(screen.getByText('pod-a').closest('.card')).toHaveTextContent(t('busy.more_queues', { n: 4 }));
  });

  it('renders a live heartbeat from the API `beat` field', async () => {
    renderBusy();
    const beats = await screen.findAllByText(/\d seconds ago/);
    expect(beats.length).toBeGreaterThanOrEqual(3);
    expect(screen.queryAllByText('—')).toHaveLength(0);
  });

  it('opens the process detail with its running jobs on card click', async () => {
    renderBusy();
    const card = (await screen.findByText('PID 100')).closest('.card');
    expect(card).not.toBeNull();
    fireEvent.click(card!);

    expect(await screen.findByText('HardJob')).toBeInTheDocument();
    expect(screen.getByText('host-a:100:aaaa')).toBeInTheDocument();
    // Only this process's in-flight jobs — host-b's job stays out.
    expect(screen.queryByText('OtherJob')).toBeNull();
  });

  it('opens the process detail from the keyboard', async () => {
    renderBusy();
    const card = (await screen.findByText('PID 100')).closest<HTMLElement>('.card')!;
    expect(card).toHaveAttribute('tabindex', '0');
    fireEvent.keyDown(card, { key: 'Enter' });

    expect(await screen.findByText('HardJob')).toBeInTheDocument();
  });

  it('labels the quiet and embedded states through i18n', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({ ok: true, status: 200, json: async () => [{ ...PROCESSES[0], quiet: true, embedded: true }] }) as Response),
    );
    renderBusy();

    expect(await screen.findByText(t('busy.quiet'))).toBeInTheDocument();
    expect(screen.getByText(t('busy.embedded'))).toBeInTheDocument();
  });

  // A killed process keeps its last `beat` until its heartbeat key expires, so
  // every poll returns the same row and only the clock can retire the dot.
  it('drops the heartbeat-OK dot once the last beat ages past 30s, without new data', async () => {
    const start = Date.now();
    const now = vi.spyOn(Date, 'now').mockReturnValue(start);
    try {
      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
      const Shell = () => {
        useLiveTick();
        return <Busy />;
      };
      render(() => (
        <QueryClientProvider client={client}>
          <Shell />
        </QueryClientProvider>
      ));
      await screen.findByText('PID 100');
      expect(screen.getAllByTitle(t('busy.heartbeat_ok'))).toHaveLength(3);

      now.mockReturnValue(start + 60_000);
      await waitFor(() => expect(screen.queryAllByTitle(t('busy.heartbeat_ok'))).toHaveLength(0), { timeout: TICK_MS * 3 });
    } finally {
      now.mockRestore();
      __resetTick();
    }
  });
});

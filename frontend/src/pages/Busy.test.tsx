import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import Busy from './Busy';

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

  it('renders a live heartbeat from the API `beat` field', async () => {
    renderBusy();
    const beats = await screen.findAllByText(/\ds ago/);
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
});

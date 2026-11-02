import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Queues from './Queues';

const QUEUES = [
  { name: 'stranded', size: 4, latency: 90, paused: false, consumers: 0 },
  { name: 'served', size: 4, latency: 1, paused: false, consumers: 2 },
  { name: 'drained', size: 0, latency: 0, paused: false, consumers: 0 },
];

function renderQueues() {
  vi.stubGlobal(
    'fetch',
    vi.fn((url: string) => {
      const body = url.includes('/api/queues') ? QUEUES : {};
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
    }),
  );
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const history = createMemoryHistory();
  history.set({ value: '/', replace: true });
  return render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path="/" component={Queues} />
      </MemoryRouter>
    </QueryClientProvider>
  ));
}

describe('Queues no-consumer badge', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // Only a queue with jobs waiting is a problem: an empty one with no consumer
  // is what every retired queue looks like.
  it('marks only the non-empty queue nothing subscribes to', async () => {
    renderQueues();

    const badges = await screen.findAllByText('No consumer');

    expect(badges).toHaveLength(1);
    expect(badges[0].closest('tr')?.textContent).toContain('stranded');
  });
});

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Queues from './Queues';
import { t } from '../i18n';
import { requests, renderPage, stubFetch } from '../test-page';

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

describe('queue page ?direction=asc', () => {
  // jsdom has no <dialog> modality; Modal only needs the calls to exist.
  const saved = { showModal: HTMLDialogElement.prototype.showModal, close: HTMLDialogElement.prototype.close };
  afterEach(() => {
    vi.unstubAllGlobals();
    Object.assign(HTMLDialogElement.prototype, saved);
  });

  const detail = { name: 'default', size: 2, latency: 0, paused: false, page: 0, count: 25, jobs: [] };
  const detailRequests = (fetchMock: ReturnType<typeof stubFetch>) =>
    requests(fetchMock).filter(({ url }) => url.pathname === '/wurk/api/queues/default');

  it('carries direction=asc from the URL to the request, and the toggle drops it', async () => {
    HTMLDialogElement.prototype.showModal = vi.fn(function (this: HTMLDialogElement) {
      this.setAttribute('open', '');
    });
    HTMLDialogElement.prototype.close = vi.fn();
    const fetchMock = stubFetch((url) => (url.pathname.endsWith('/api/queues') ? QUEUES : detail));
    const history = renderPage('/queues/default?direction=asc', '/queues/:name', Queues);

    const toggle = await screen.findByRole('button', { name: t('queues.oldest_first') });
    expect(toggle).toHaveAttribute('aria-pressed', 'true');
    expect(detailRequests(fetchMock)[0].url.searchParams.get('direction')).toBe('asc');

    fireEvent.click(toggle);

    expect(await screen.findByRole('button', { name: t('queues.newest_first') })).toHaveAttribute('aria-pressed', 'false');
    await waitFor(() => expect(detailRequests(fetchMock).at(-1)!.url.searchParams.get('direction')).toBeNull());
    expect(history.get()).not.toContain('direction');
  });
});

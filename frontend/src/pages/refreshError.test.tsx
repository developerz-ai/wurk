import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import type { Component } from 'solid-js';
import Queues from './Queues';
import Busy from './Busy';
import Limiters from './Limiters';
import Flows from './Flows';
import Cron from './Cron';
import Profiles from './Profiles';
import { t } from '../i18n';

// One failed poll must not replace a polled page (or the modal open on it)
// with the full error state while an earlier payload is still cached.

const PROCESS = {
  identity: 'host-a:100:aaaa',
  pid: 100,
  hostname: 'host-a',
  tag: 'app',
  queues: ['default'],
  labels: [],
  concurrency: 10,
  busy: 0,
  quiet: false,
  beat: Date.now() / 1000,
  rss: 1024,
  started_at: Date.now() / 1000 - 60,
  version: '1.0.0',
};
const LOOP = { lid: 'l1', schedule: '* * * * *', klass: 'NightlyJob', queue: 'default', tz: null, paused: false, args: [], last_fire_at: null, next_fire_at: null };
const FLOW = { fid: 'F-keep', state: 'running', total: 2, pending: 1, succeeded: 1, depth: 1, width: 1, created_at: null, finished_at: null, failed_at: null, abandoned_at: null };
const LIMITER = { name: 'stripe-api', type: 'concurrent', fingerprint: 'f', options: {}, status: { used: 1, limit: 5, reset_at: null, 'available?': true } };
const PROFILE = { key: 'k1', jid: 'jid-keep', token: 'tok', type: 'ProfiledJob', size: 10, elapsed: 0.5, started_at: null };

interface Case {
  name: string;
  page: Component;
  path: string;
  route: string;
  payload: (pathname: string) => unknown;
  kept: string;
}

const CASES: Case[] = [
  {
    name: 'Queues',
    page: Queues,
    path: '/queues',
    route: '/queues',
    payload: () => [{ name: 'mailers', size: 4, latency: 1, paused: false, consumers: 1 }],
    kept: 'mailers',
  },
  {
    name: 'Busy',
    page: Busy,
    path: '/busy',
    route: '/busy',
    payload: (p) => (p.endsWith('/api/processes') ? [PROCESS] : []),
    kept: 'host-a',
  },
  {
    name: 'Limiters',
    page: Limiters,
    path: '/limiters',
    route: '/limiters',
    payload: () => ({ total: 1, page: 0, count: 25, limiters: [LIMITER] }),
    kept: 'stripe-api',
  },
  {
    name: 'Flows',
    page: Flows,
    path: '/flows',
    route: '/flows',
    payload: () => ({ total: 1, page: 0, count: 25, flows: [FLOW] }),
    kept: 'F-keep',
  },
  { name: 'Cron', page: Cron, path: '/cron', route: '/cron', payload: () => [LOOP], kept: 'NightlyJob' },
  { name: 'Profiles', page: Profiles, path: '/profiles', route: '/profiles', payload: () => [PROFILE], kept: 'ProfiledJob' },
];

let failing = false;

function mount(c: Case) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: RequestInfo | URL) => {
      const { pathname } = new URL(String(input), 'http://x');
      if (pathname.endsWith('/api/meta')) return { ok: true, status: 200, json: async () => ({ read_only: false }) } as Response;
      if (failing) return { ok: false, status: 503, json: async () => ({}) } as Response;
      return { ok: true, status: 200, json: async () => c.payload(pathname) } as Response;
    }),
  );
  const history = createMemoryHistory();
  history.set({ value: c.path, replace: true });
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path={c.route} component={c.page} />
      </MemoryRouter>
    </QueryClientProvider>
  ));
  return client;
}

describe('a failed poll on a polled page', () => {
  const saved = { showModal: HTMLDialogElement.prototype.showModal, close: HTMLDialogElement.prototype.close };
  beforeEach(() => {
    failing = false;
    // jsdom has no <dialog> modality; Modal only needs the calls to exist.
    HTMLDialogElement.prototype.showModal = vi.fn(function (this: HTMLDialogElement) {
      this.setAttribute('open', '');
    });
    HTMLDialogElement.prototype.close = vi.fn();
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    Object.assign(HTMLDialogElement.prototype, saved);
  });

  for (const c of CASES) {
    it(`${c.name}: keeps the last good data under an inline notice`, async () => {
      const client = mount(c);
      expect((await screen.findAllByText(c.kept)).length).toBeGreaterThan(0);
      expect(screen.queryByRole('alert')).not.toBeInTheDocument();

      failing = true;
      await client.refetchQueries();

      expect(await screen.findByRole('alert')).toHaveTextContent(t('common.refresh_failed'));
      expect(screen.getAllByText(c.kept).length).toBeGreaterThan(0);
      expect(screen.queryByText(t('common.error'))).not.toBeInTheDocument();

      failing = false;
      await client.refetchQueries();

      await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument());
    });

    it(`${c.name}: shows the full error state when nothing has loaded`, async () => {
      failing = true;
      mount(c);

      expect(await screen.findByText(t('common.error'))).toBeInTheDocument();
      expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    });
  }

  it('Busy: the open process modal survives the failed poll', async () => {
    const client = mount(CASES[1]);
    fireEvent.click(await screen.findByText(/PID 100/));
    const dialog = await screen.findByRole('dialog');

    failing = true;
    await client.refetchQueries();

    await screen.findByRole('alert');
    expect(dialog).toBeInTheDocument();
    expect(dialog).toHaveAttribute('open');
  });
});

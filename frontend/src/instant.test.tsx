import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor, within } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import { Suspense, type Component } from 'solid-js';
import Retries from './pages/Retries';
import Busy from './pages/Busy';
import Queues from './pages/Queues';
import { t } from './i18n';
import { Toasts, dismissToast, toasts } from './toast';

// Pages render inside the app's route <Suspense> (App.tsx). Every case here
// mounts them under one, whose fallback must never show: a page draws its own
// skeleton, a modal opens on the click, and polls and actions never blank it.

const NOW = Math.floor(Date.now() / 1000);
const FALLBACK = 'ROUTE-SUSPENSE-FALLBACK';

function entry(i: number) {
  return { jid: `jid${i}`, klass: `Job${i}`, args: [i], error_class: 'RuntimeError', error_message: 'boom', at: NOW + 60, retry_count: 1, score: NOW + 60 + i };
}
const page = (n: number) => ({ total: n, page: 0, count: n, entries: Array.from({ length: n }, (_, i) => entry(i + 1)) });

type Reply = unknown | { status: number; body?: unknown } | Promise<unknown>;
let handler: (url: URL, method: string) => Reply;

function stub() {
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input), 'http://x');
    const reply = url.pathname.endsWith('/api/meta') ? { read_only: false } : await handler(url, init?.method ?? 'GET');
    if (reply && typeof reply === 'object' && 'status' in reply && typeof (reply as { status: unknown }).status === 'number') {
      const { status, body } = reply as { status: number; body?: unknown };
      return { ok: status < 300, status, json: async () => body ?? {} } as Response;
    }
    return { ok: true, status: 200, json: async () => reply } as Response;
  });
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}

function mount(path: string, routePath: string, component: Component, client = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
  const history = createMemoryHistory();
  history.set({ value: path, replace: true });
  const view = render(() => (
    <QueryClientProvider client={client}>
      <Suspense fallback={<div>{FALLBACK}</div>}>
        <MemoryRouter history={history}>
          <Route path={routePath} component={component} />
        </MemoryRouter>
      </Suspense>
      <Toasts />
    </QueryClientProvider>
  ));
  return { client, ...view };
}

const never = () => new Promise(() => {});

beforeEach(() => {
  HTMLDialogElement.prototype.showModal = vi.fn(function (this: HTMLDialogElement) {
    this.setAttribute('open', '');
  });
  HTMLDialogElement.prototype.close = vi.fn(function (this: HTMLDialogElement) {
    this.removeAttribute('open');
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  for (const toast of toasts()) dismissToast(toast.id);
});

describe('pages render their own shell at once', () => {
  it('shows the page header and its skeleton, not the route fallback, before the list answers', async () => {
    handler = () => never();
    stub();
    mount('/retries', '/retries', Retries);

    expect(await screen.findByText(t('nav.retries'))).toBeInTheDocument();
    expect(document.querySelector('[aria-busy="true"]')).not.toBeNull();
    expect(screen.queryByText(FALLBACK)).toBeNull();
  });

  it('renders cached rows on a revisit before any request returns', async () => {
    handler = () => never();
    stub();
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    client.setQueryData(['retries', 1, ''], page(2));
    mount('/retries', '/retries', Retries, client);

    expect(screen.getByText('Job1')).toBeInTheDocument();
    expect(screen.getByText('Job2')).toBeInTheDocument();
    expect(screen.queryByText(FALLBACK)).toBeNull();
  });
});

describe('modals open on the click', () => {
  it('opens the job modal with a backtrace skeleton before the detail request resolves', async () => {
    handler = (url) => (url.pathname.endsWith('/api/retries') ? page(2) : never());
    stub();
    mount('/retries', '/retries', Retries);

    fireEvent.click((await screen.findByText('Job1')).closest('tr')!);

    const dialog = document.querySelector('dialog[open]')!;
    expect(dialog).not.toBeNull();
    expect(dialog).toHaveTextContent('jid1');
    expect(dialog.querySelector(`[aria-label="${t('job.backtrace_loading')}"]`)).not.toBeNull();
    expect(screen.queryByText(FALLBACK)).toBeNull();
    // The page behind it stayed mounted.
    expect(screen.getByText('Job2')).toBeInTheDocument();
  });

  it('keeps an open process modal mounted through a poll', async () => {
    const proc = { identity: 'h:1:a', pid: 1, hostname: 'h', queues: ['default'], labels: [], concurrency: 5, busy: 1, quiet: false, beat: NOW };
    let busy = 1;
    handler = (url) => {
      if (url.pathname.endsWith('/api/processes')) return [{ ...proc, busy, beat: NOW + busy }];
      if (url.pathname.endsWith('/api/workers')) return [{ process_id: 'h:1:a', thread_id: 't', queue: 'default', klass: 'RunningJob', args: [], jid: 'r1', run_at: NOW }];
      return {};
    };
    stub();
    const { client } = mount('/busy', '/busy', Busy);

    fireEvent.click((await screen.findByText('h')).closest('.card')!);
    const job = await screen.findByText('RunningJob');
    const body = job.closest('.modal-body')!;

    busy = 3;
    await client.invalidateQueries();
    await waitFor(() => expect(screen.getAllByText('3 / 5').length).toBeGreaterThan(0));

    expect(screen.getByText('RunningJob')).toBe(job);
    expect(job.closest('.modal-body')).toBe(body);
    expect(document.querySelector('dialog[open]')).not.toBeNull();
    expect(screen.queryByText(FALLBACK)).toBeNull();
  });
});

describe('optimistic actions', () => {
  it('drops a deleted retry at once and puts it back with a toast when the server answers 500', async () => {
    let answer!: (r: Reply) => void;
    handler = (url, method) => {
      if (method === 'POST') return new Promise((res) => (answer = res));
      if (url.pathname.endsWith('/api/retries')) return page(2);
      return never();
    };
    stub();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    mount('/retries', '/retries', Retries);

    fireEvent.click((await screen.findByText('Job1')).closest('tr')!);
    fireEvent.click(within(document.querySelector('dialog[open]') as HTMLElement).getByRole('button', { name: t('actions.delete') }));

    await waitFor(() => expect(screen.queryByText('Job1')).toBeNull());
    expect(screen.getByText('Job2')).toBeInTheDocument();

    answer({ status: 500, body: { error: 'boom' } });

    expect(await screen.findByText('Job1')).toBeInTheDocument();
    await waitFor(() => expect(toasts().some((x) => x.kind === 'error')).toBe(true));
  });

  it('pauses a queue at once and keeps it paused once the server agrees', async () => {
    let paused = false;
    let answer!: (r: Reply) => void;
    handler = (url, method) => {
      if (method === 'POST') {
        return new Promise((res) => (answer = (r) => { paused = true; res(r); }));
      }
      if (url.pathname.endsWith('/api/queues')) return [{ name: 'default', size: 3, latency: 0, paused }];
      return never();
    };
    stub();
    mount('/queues', '/queues', Queues);

    fireEvent.click(await screen.findByRole('button', { name: t('actions.pause') }));
    expect(await screen.findByRole('button', { name: t('actions.unpause') })).toBeInTheDocument();

    answer({ ok: true });
    await waitFor(() => expect(paused).toBe(true));
    expect(screen.getByRole('button', { name: t('actions.unpause') })).toBeInTheDocument();
  });
});

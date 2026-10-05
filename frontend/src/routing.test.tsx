import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { A, MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import { Suspense, createSignal, type ParentProps } from 'solid-js';
import { AppRoutes } from './App';
import ErrorBoundary from './components/ErrorBoundary';
import { t } from './i18n';

type Responder = (url: string) => { status: number; body: unknown } | undefined;

function stubFetch(respond: Responder = () => undefined) {
  const fetchMock = vi.fn((input: RequestInfo | URL) => {
    const url = String(input);
    const r = respond(url) ?? { status: 200, body: url.includes('/api/meta') ? { read_only: false, custom_tabs: [] } : {} };
    return Promise.resolve({
      ok: r.status >= 200 && r.status < 300,
      status: r.status,
      json: () => Promise.resolve(r.body),
      text: () => Promise.resolve(''),
    } as Response);
  });
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}

// The real shell's ErrorBoundary + Suspense, plus links to navigate with.
function Shell(props: ParentProps) {
  return (
    <>
      <A href="/queues">go-queues</A>
      <A href="/busy">go-busy</A>
      <A href="/boom">go-boom</A>
      <main>
        <ErrorBoundary>
          <Suspense fallback={<div>loading</div>}>{props.children}</Suspense>
        </ErrorBoundary>
      </main>
    </>
  );
}

function renderAt(path: string, extra?: () => unknown) {
  const history = createMemoryHistory();
  history.set({ value: path, replace: true });
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history} root={Shell}>
        {extra?.() as never}
        <AppRoutes />
      </MemoryRouter>
    </QueryClientProvider>
  ));
}

const heading = (name: string) => screen.findByRole('heading', { level: 1, name }, { timeout: 5000 });

describe('Sidekiq path aliases (W12)', () => {
  beforeEach(() => {
    HTMLDialogElement.prototype.showModal = vi.fn();
    HTMLDialogElement.prototype.close = vi.fn();
  });
  afterEach(() => vi.unstubAllGlobals());

  it('/morgue renders the Dead page', async () => {
    const fetchMock = stubFetch((url) =>
      url.includes('/api/dead') ? { status: 200, body: { total: 0, page: 0, count: 25, entries: [] } } : undefined,
    );
    renderAt('/morgue');
    expect(await heading(t('nav.dead'))).toBeInTheDocument();
    expect(fetchMock.mock.calls.map((c) => String(c[0])).some((u) => u.includes('/api/dead?'))).toBe(true);
  });

  it('/retries/:key opens Retries filtered to the jid of a Sidekiq "<score>-<jid>" key', async () => {
    const fetchMock = stubFetch((url) =>
      url.includes('/api/retries') ? { status: 200, body: { total: 0, page: 0, count: 25, entries: [] } } : undefined,
    );
    renderAt('/retries/1700000000.5-abc123def');
    expect(await heading(t('nav.retries'))).toBeInTheDocument();
    expect(fetchMock.mock.calls.map((c) => String(c[0]))).toContainEqual(expect.stringContaining('substr=abc123def'));
    expect(screen.getByRole('searchbox')).toHaveValue('abc123def');
  });

  it('/queues/:name opens that queue’s job list', async () => {
    const fetchMock = stubFetch((url) => {
      if (url.includes('/api/queues/emails')) return { status: 200, body: { name: 'emails', size: 0, latency: 0, paused: false, page: 0, count: 25, jobs: [] } };
      if (url.includes('/api/queues')) return { status: 200, body: [{ name: 'emails', size: 0, latency: 0, paused: false }] };
      return undefined;
    });
    renderAt('/queues/emails');
    expect(await heading(t('nav.queues'))).toBeInTheDocument();
    await vi.waitFor(() =>
      expect(fetchMock.mock.calls.map((c) => String(c[0]))).toContainEqual(expect.stringContaining('/api/queues/emails?')),
    );
  });

  it('an unknown path renders NotFound instead of a blank pane', async () => {
    stubFetch();
    renderAt('/definitely/not/a/page');
    expect(await heading(t('notfound.title'))).toBeInTheDocument();
  });
});

describe('route-level error recovery (W3)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('Busy shows its error state on a /api/processes 503 instead of crashing the SPA', async () => {
    stubFetch((url) => (url.includes('/api/processes') ? { status: 503, body: { error: 'redis unavailable' } } : undefined));
    renderAt('/busy');
    expect(await screen.findByText(t('common.error'), undefined, { timeout: 5000 })).toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('a route that throws resets the boundary on navigation — the next page renders', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    stubFetch((url) => (url.includes('/api/queues') ? { status: 200, body: [] } : undefined));
    // Throws after mounting, from a nested computation — the shape of a page
    // dereferencing an error payload once its query resolves.
    renderAt('/boom', () => (
      <Route
        path="/boom"
        component={() => {
          const [broken, setBroken] = createSignal(false);
          setTimeout(() => setBroken(true), 0);
          return (
            <div>
              {(() => {
                if (broken()) throw new Error('kaboom');
                return 'fine';
              })()}
            </div>
          );
        }}
      />
    ));

    expect(await screen.findByRole('alert')).toHaveTextContent(t('common.load_failed'));
    fireEvent.click(screen.getByText('go-queues'));
    expect(await heading(t('nav.queues'))).toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });
});

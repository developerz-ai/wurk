import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@solidjs/testing-library';
import appSource from './App.tsx?raw';
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

const clients: QueryClient[] = [];

afterEach(() => {
  cleanup();
  for (const client of clients.splice(0)) client.clear();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function renderAt(path: string, extra?: () => unknown) {
  const history = createMemoryHistory();
  history.set({ value: path, replace: true });
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  clients.push(client);
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

// Deliberately accept only the route declaration shape we understand. A router
// refactor must update this guard, not silently shrink the coverage inventory.
function routeInventory(source: string) {
  const imports = new Map<string, string>();
  for (const [, name, page] of source.matchAll(/const\s+(\w+)\s*=\s*lazy\(\(\)\s*=>\s*import\(['"]\.\/pages\/(\w+)['"]\)\);/g)) {
    imports.set(name!, page!);
  }
  const routes = [...source.matchAll(/<Route\b/g)].map((match) => {
    const declaration = source.slice(match.index).match(/^<Route\s+path="([^"]+)"\s+component=\{(\w+)\}\s*\/>/);
    if (!declaration) throw new Error('Unsupported Route declaration');
    const [, path, component] = declaration;
    const page = imports.get(component!);
    if (!page) throw new Error(`Unresolved Route component: ${component}`);
    return { path: path!, page };
  });
  if (!routes.length) throw new Error('No Route declarations found');
  return routes;
}

type HeadingCase = { page: string; url: string; title: string; settled: string };

function validateCoverage(source: string, cases: readonly HeadingCase[]) {
  const routes = routeInventory(source);
  const pages = new Set(routes.map((route) => route.page));
  const seen = new Set<string>();
  for (const entry of cases) {
    if (seen.has(entry.page)) throw new Error(`Duplicate case: ${entry.page}`);
    if (!pages.has(entry.page)) throw new Error(`Stale case: ${entry.page}`);
    seen.add(entry.page);
    const pathname = entry.url.split('?')[0]!;
    const matches = routes.filter(({ path }) => path !== '*' && new RegExp(`^${path.replace(/:[^/]+/g, '[^/]+')}$`).test(pathname));
    const route = matches[0] ?? routes.find(({ path }) => path === '*');
    if (route?.page !== entry.page) throw new Error(`Wrong representative URL: ${entry.page}`);
  }
  const missing = [...pages].filter((page) => !seen.has(page));
  if (missing.length) throw new Error(`Missing cases: ${missing.join(', ')}`);
}

const headingCases: HeadingCase[] = [
  { page: 'Dashboard', url: '/', title: t('nav.dashboard'), settled: t('dashboard.performance_insight') },
  { page: 'Queues', url: '/queues', title: t('nav.queues'), settled: t('common.empty') },
  { page: 'Retries', url: '/retries', title: t('nav.retries'), settled: t('common.empty') },
  { page: 'Scheduled', url: '/scheduled', title: t('nav.scheduled'), settled: 'ScheduledWorker' },
  { page: 'Dead', url: '/dead', title: t('nav.dead'), settled: t('common.empty') },
  { page: 'Busy', url: '/busy', title: t('nav.busy'), settled: t('common.empty') },
  { page: 'Batches', url: '/batches', title: t('nav.batches'), settled: 'Heading batch' },
  { page: 'BatchDetail', url: '/batches/heading-batch', title: 'heading-batch', settled: 'Heading batch' },
  { page: 'Flows', url: '/flows', title: t('nav.flows'), settled: 'heading-flow' },
  { page: 'FlowDetail', url: '/flows/heading-flow', title: 'heading-flow', settled: t('flows.released') },
  { page: 'Limiters', url: '/limiters', title: t('nav.limiters'), settled: 'heading-limiter' },
  { page: 'Cron', url: '/cron', title: t('nav.cron'), settled: 'CronWorker' },
  { page: 'Metrics', url: '/metrics', title: t('nav.metrics'), settled: 'MetricsWorker' },
  { page: 'Profiles', url: '/profiles', title: t('nav.profiles'), settled: 'heading-profile-jid' },
  { page: 'Search', url: '/search?q=heading', title: t('nav.search'), settled: t('common.empty') },
  { page: 'Extension', url: '/ext/heading', title: 'Heading extension', settled: 'Extension content' },
  { page: 'NotFound', url: '/unknown-heading-page', title: t('notfound.title'), settled: t('notfound.home') },
];

const batch = {
  bid: 'heading-batch', description: 'Heading batch', total: 1, pending: 0, failures: 0,
  complete: true, invalidated: false, created_at: 1700000000, complete_at: 1700000001,
  success_at: 1700000001, death_at: null, parent_bid: null, tags: [], child_count: 0,
  failed_jids: [], dead_jids: [],
};
const flow = {
  fid: 'heading-flow', state: 'abandoned', total: 1, pending: 0, succeeded: 0,
  depth: 1, width: 1, created_at: 1700000000, finished_at: null, failed_at: null,
  abandoned_at: 1700000001, dead_nodes: [], nodes: [],
};
const paged = { total: 1, page: 0, count: 25 };
const fixtures: Record<string, unknown> = {
  '/api/meta': { read_only: false, custom_tabs: [{ path: 'heading', name: 'Heading extension', ext_name: 'heading-extension' }] },
  '/api/stats': { processed: 1, failed: 0, expired: 0, busy: 0, enqueued: 0, retries: 0, scheduled: 1, dead: 0, processes: 0, latency: 0, queues: [] },
  '/api/history/snapshots': { snapshots: [] },
  '/api/history/1m': { bucket: '1m', window: 86400, series: [] },
  '/api/history/5m': { bucket: '5m', window: 604800, series: [] },
  '/api/queue-history/5m': { bucket: '5m', window: 604800, queues: [] },
  '/api/metrics': { minutes: 10080, top_jobs: [{ klass: 'MetricsWorker', processed: 1, failed: 0, runtime_ms: 10 }] },
  '/api/queues': [],
  '/api/retries': { ...paged, total: 0, entries: [] },
  '/api/dead': { ...paged, total: 0, entries: [] },
  '/api/scheduled': { ...paged, entries: [{ jid: 'heading-jid', klass: 'ScheduledWorker', args: [], score: 1700000000, at: 1700000000, queue: 'default' }] },
  '/api/processes': [],
  '/api/batches': { ...paged, batches: [batch] },
  '/api/batches/heading-batch': batch,
  '/api/flows': { ...paged, flows: [flow] },
  '/api/flows/heading-flow': flow,
  '/api/limiters': { ...paged, limiters: [{ name: 'heading-limiter', type: 'concurrent', fingerprint: 'heading-fingerprint', options: {}, status: { used: 0, limit: 2, reset_at: null, 'available?': true } }] },
  '/api/cron': [{ lid: 'heading-cron', schedule: '* * * * *', klass: 'CronWorker', queue: 'default', tz: null, paused: false, args: [], last_fire_at: null, next_fire_at: 1700000000 }],
  '/api/profiles': [{ key: 'heading-profile', jid: 'heading-profile-jid', token: 'heading-token', type: 'vernier', size: 1024, elapsed: 0.1, started_at: 1700000000 }],
  '/api/search': { substr: 'heading', total: 0, hits: [], truncated: false },
};

describe('routed page heading coverage', () => {
  it('covers each distinct routed page exactly once, ignoring aliases', () => {
    validateCoverage(appSource, headingCases);
  });

  it('rejects an added page without an executed case', () => {
    const source = appSource + `\nconst Added = lazy(() => import('./pages/Added'));\n<Route path="/added" component={Added} />`;
    expect(() => validateCoverage(source, headingCases)).toThrow('Missing cases: Added');
  });

  it('rejects a duplicate substituted for a missing page', () => {
    expect(() => validateCoverage(appSource, [headingCases[0]!, ...headingCases.slice(0, -1)])).toThrow('Duplicate case: Dashboard');
  });

  it('rejects an unresolved route component', () => {
    expect(() => validateCoverage(appSource.replace('component={Dashboard}', 'component={Unresolved}'), headingCases)).toThrow('Unresolved Route component: Unresolved');
  });

  it('rejects unsupported route declarations and stale cases', () => {
    expect(() => validateCoverage(appSource + '<Route {...extra} />', headingCases)).toThrow('Unsupported Route declaration');
    expect(() => validateCoverage(appSource, [...headingCases, { ...headingCases[0]!, page: 'Removed' }])).toThrow('Stale case: Removed');
  });

  const dialogDescriptors = new Map(['showModal', 'close'].map((name) => [name, Object.getOwnPropertyDescriptor(HTMLDialogElement.prototype, name)]));
  beforeEach(() => {
    HTMLDialogElement.prototype.showModal = vi.fn();
    HTMLDialogElement.prototype.close = vi.fn();
  });
  afterEach(() => {
    for (const [name, descriptor] of dialogDescriptors) {
      if (descriptor) Object.defineProperty(HTMLDialogElement.prototype, name, descriptor);
      else Reflect.deleteProperty(HTMLDialogElement.prototype, name);
    }
  });

  for (const entry of headingCases) {
    it(`${entry.page} renders exactly one named h1 after its content settles`, async () => {
      const unexpected: string[] = [];
      vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
        const path = new URL(String(input), window.location.origin).pathname.replace(/^\/wurk(?=\/)/, '');
        const extension = path === '/ext/heading-extension/heading';
        if (!extension && !Object.hasOwn(fixtures, path)) {
          unexpected.push(path);
          return Promise.reject(new Error(`Unexpected fixture request: ${path}`));
        }
        return Promise.resolve({
          ok: true, status: 200,
          json: () => Promise.resolve(fixtures[path]),
          text: () => Promise.resolve(extension ? '<p>Extension content</p>' : ''),
        } as Response);
      }));
      renderAt(entry.url);
      await screen.findByText(entry.settled, { exact: true }, { timeout: 5000 });
      await waitFor(() => {
        expect(clients.every((client) => client.isFetching() === 0)).toBe(true);
        expect(screen.getAllByRole('heading', { level: 1 })).toHaveLength(1);
        expect(screen.getByRole('heading', { level: 1, name: entry.title })).toBeInTheDocument();
      });
      expect(screen.queryByRole('alert')).not.toBeInTheDocument();
      expect(screen.queryByText(t('common.error'), { exact: true })).not.toBeInTheDocument();
      expect(unexpected).toEqual([]);
    });
  }
});

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

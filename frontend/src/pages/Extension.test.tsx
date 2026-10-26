import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Extension from './Extension';
import mainScss from '../styles/main.scss?raw';

function shadow() {
  const root = document.querySelector('[data-extension-view]')?.shadowRoot;
  expect(root).toBeTruthy();
  return root!;
}

function staticText(text: string) {
  const elements = Array.from(shadow().querySelectorAll('*'));
  const element = elements.find((el) => el.textContent === text && el.children.length === 0);
  expect(element).toBeTruthy();
  return element!;
}

const registeredMeta = {
  read_only: false,
  read_only_message: null,
  custom_tabs: [{ name: 'Demo Locks', path: 'locks/', ext_name: 'demo_locks' }],
};

function response(html: string, status = 200) {
  return { ok: status < 400, status, text: async () => html } as Response;
}

function deferredResponse() {
  let resolve!: (value: Response) => void;
  const promise = new Promise<Response>((done) => { resolve = done; });
  return { promise, resolve };
}

// Regression for the trailing-slash mismatch: registered index paths keep
// Sidekiq's trailing slash ("locks/") while the /ext/:tab route param has
// none. The tab must still resolve to its extension (native server-rendered
// embed), not fall back to the iframe "not rendered here" page.

function mockFetch(meta: unknown, extHtml: string) {
  return vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    if (url.includes('/api/meta')) {
      return { ok: true, status: 200, json: async () => meta, text: async () => '' } as Response;
    }
    return { ok: true, status: 200, json: async () => ({}), text: async () => extHtml } as Response;
  });
}

function renderAt(path: string) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const history = createMemoryHistory();
  history.set({ value: path, replace: true });
  return render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path="/ext/:tab" component={Extension} />
      </MemoryRouter>
    </QueryClientProvider>
  ));
}

describe('Extension', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('matches a registered tab whose index path has a trailing slash', async () => {
    const fetchMock = mockFetch(
      {
        read_only: false,
        read_only_message: null,
        custom_tabs: [{ name: 'Demo Locks', path: 'locks/', ext_name: 'demo_locks' }],
      },
      '<h2>Demo Locks</h2><table><tr><td>WelcomeEmailJob</td></tr></table>',
    );
    vi.stubGlobal('fetch', fetchMock);

    renderAt('/ext/locks');

    await waitFor(() => expect(staticText('WelcomeEmailJob')).toBeInTheDocument());
    const extCalls = fetchMock.mock.calls.map((c) => String(c[0])).filter((u) => u.includes('/ext/'));
    expect(extCalls).toContain('/wurk/ext/demo_locks/locks');
  });

  it('falls back to the iframe embed for a bare tabs[]= tab (no ext_name)', async () => {
    vi.stubGlobal(
      'fetch',
      mockFetch(
        { read_only: false, read_only_message: null, custom_tabs: [{ name: 'Legacy', path: 'legacy', ext_name: null }] },
        '',
      ),
    );

    renderAt('/ext/legacy');

    await waitFor(() => expect(screen.getByTitle('Legacy')).toBeTruthy());
    expect(screen.getByTitle('Legacy').getAttribute('src')).toBe('/wurk/legacy?wurk_ext_embed=1');
    const openLink = document.querySelector('a[target="_blank"]');
    expect(openLink).toHaveAttribute('href', '/wurk/legacy');
    expect(openLink).toHaveAttribute('rel', 'noopener noreferrer');
    expect(document.querySelector('[data-extension-view]')).toBeNull();
  });

  it('aborts the in-flight extension fetch on unmount and never resolves state after', async () => {
    let capturedSignal: AbortSignal | undefined;
    let resolveExt: (res: Response) => void = () => {};
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.includes('/api/meta')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            read_only: false,
            read_only_message: null,
            custom_tabs: [{ name: 'Demo Locks', path: 'locks/', ext_name: 'demo_locks' }],
          }),
          text: async () => '',
        } as Response;
      }
      capturedSignal = init?.signal ?? undefined;
      return new Promise<Response>((resolve) => {
        resolveExt = resolve;
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    const { unmount } = renderAt('/ext/locks');

    await waitFor(() => expect(capturedSignal).toBeInstanceOf(AbortSignal));
    expect(capturedSignal!.aborted).toBe(false);

    unmount();

    expect(capturedSignal!.aborted).toBe(true);

    // Resolving the stale fetch after unmount must not throw or update state.
    resolveExt({ ok: true, status: 200, json: async () => ({}), text: async () => '<h2>Late</h2>' } as Response);
    await new Promise((r) => setTimeout(r, 0));
    expect(screen.queryByText('Late')).not.toBeInTheDocument();
  });

  it('keeps colliding selectors and the compiled baseline in separate tree scopes', async () => {
    const dashboard = document.createElement('section');
    dashboard.innerHTML = '<style>h2, .btn, nav { color: red; }</style><h2>Dashboard heading</h2><button class="btn">Dashboard button</button><nav>Dashboard nav</nav>';
    document.body.append(dashboard);
    try {
      vi.stubGlobal('fetch', mockFetch(registeredMeta, '<style>h2, .btn, nav { color: blue; }</style><h2>Extension heading</h2><button class="btn">Extension button</button><nav>Extension nav</nav>'));
      renderAt('/ext/locks');
      await waitFor(() => expect(staticText('Extension heading')).toBeInTheDocument());
      const root = shadow();
      // jsdom proves tree/stylesheet boundaries, not browser cascade or layout.
      expect(document.querySelectorAll('h2')).toHaveLength(1);
      expect(document.querySelector('h2')).toHaveTextContent('Dashboard heading');
      expect(root.querySelector('h2')).toHaveTextContent('Extension heading');
      expect(root.querySelector('.btn')).toHaveTextContent('Extension button');
      expect(root.querySelector('nav')).toHaveTextContent('Extension nav');
      expect(document.querySelectorAll('style')).toHaveLength(1);
      expect(root.querySelectorAll('style')).toHaveLength(2);
      expect(root.querySelector('style')?.textContent).toMatch(/all:\s*initial/);
      expect(root.querySelector('style')?.textContent).toContain('var(--font-sans, sans-serif)');
      expect(root.querySelector('style')?.textContent).toContain('border-collapse: collapse');
      expect(root.querySelector('style')?.textContent).toContain('.ext-view button');
      expect(root.querySelector('style')?.textContent).not.toContain('.btn');
      expect(mainScss).not.toMatch(/@use\s+['"]pages\/extension['"]/);
      expect(screen.getByText('Demo Locks').getRootNode()).toBe(document);
    } finally {
      dashboard.remove();
    }
  });

  it('inserts script tags only through innerHTML and preserves stylesheet links', async () => {
    const innerHTML = vi.spyOn(Element.prototype, 'innerHTML', 'set');
    const createElement = vi.spyOn(document, 'createElement');
    try {
      vi.stubGlobal('fetch', mockFetch(registeredMeta, '<p>Static view</p><script>window.extensionRan = true</script><script src="/extension.js"></script><link rel="stylesheet" href="/wurk/ext-assets/demo_locks/app.css">'));
      renderAt('/ext/locks');
      await waitFor(() => expect(staticText('Static view')).toBeInTheDocument());
      expect(shadow().querySelectorAll('script')).toHaveLength(2);
      expect(shadow().querySelector('script[src]')).toHaveAttribute('src', '/extension.js');
      expect(shadow().querySelector('link')).toHaveAttribute('href', '/wurk/ext-assets/demo_locks/app.css');
      expect(document.querySelector('script[src="/extension.js"]')).toBeNull();
      expect(innerHTML.mock.calls.some(([value]) => String(value).includes('<script>'))).toBe(true);
      // Assert the insertion mechanism, not jsdom's script-execution behavior.
      expect(createElement.mock.calls.some(([tag]) => tag.toLowerCase() === 'script')).toBe(false);
    } finally {
      innerHTML.mockRestore();
      createElement.mockRestore();
    }
  });

  it.each(['GET', 'POST'])('intercepts a %s form within the shadow tree and replaces HTML', async (method) => {
    const fetchMock = mockFetch(registeredMeta, `<form method="${method}" action="/wurk/ext/demo_locks/locks/search"><input name="q" value="hello world"><button>Search</button></form>`);
    vi.stubGlobal('fetch', fetchMock);
    renderAt('/ext/locks');
    await waitFor(() => expect(shadow().querySelector('form')).toBeTruthy());
    const root = shadow();
    const baseline = root.querySelector('style');
    fetchMock.mockImplementation(async () => response('<p>Replacement</p>'));
    const event = new Event('submit', { bubbles: true, cancelable: true });
    root.querySelector('form')!.dispatchEvent(event);
    expect(event.defaultPrevented).toBe(true);
    await waitFor(() => expect(staticText('Replacement')).toBeInTheDocument());
    const call = fetchMock.mock.calls.at(-1)! as unknown as [string, RequestInit];
    if (method === 'GET') {
      expect(call[0]).toBe('/wurk/ext/demo_locks/locks/search?q=hello+world');
      expect(call[1].method).toBeUndefined();
    } else {
      expect(call[0]).toBe('/wurk/ext/demo_locks/locks/search');
      expect(call[1].method).toBe('POST');
      expect((call[1].body as FormData).get('q')).toBe('hello world');
    }
    expect(shadow()).toBe(root);
    expect(root.querySelector('form')).toBeNull();
    expect(root.querySelector('style')).toBe(baseline);
  });

  it('shows loading outside the shadow tree, then renders a 404 body', async () => {
    const pending = deferredResponse();
    const fetchMock = mockFetch(registeredMeta, '');
    fetchMock.mockImplementation(async (input) => String(input).includes('/api/meta')
      ? { ok: true, status: 200, json: async () => registeredMeta } as Response
      : pending.promise);
    vi.stubGlobal('fetch', fetchMock);
    renderAt('/ext/locks');
    await waitFor(() => expect(document.querySelector('.skeleton-stack')).toBeInTheDocument());
    expect(document.querySelector('[data-extension-view]')).toBeNull();
    pending.resolve(response('<p>No matching lock</p>', 404));
    await waitFor(() => expect(staticText('No matching lock')).toBeInTheDocument());
    expect(document.querySelector('.skeleton-stack')).toBeNull();
    expect(document.querySelector('.empty-state')).toBeNull();
  });

  it.each(['http', 'network'])('shows a %s error outside the shadow tree', async (failure) => {
    const fetchMock = mockFetch(registeredMeta, '');
    fetchMock.mockImplementation(async (input) => {
      if (String(input).includes('/api/meta')) return { ok: true, status: 200, json: async () => registeredMeta } as Response;
      if (failure === 'network') throw new TypeError('Network unavailable');
      return response('<p>Server detail</p>', 500);
    });
    vi.stubGlobal('fetch', fetchMock);
    renderAt('/ext/locks');
    await waitFor(() => expect(document.querySelector('.empty-state')).toBeInTheDocument());
    expect(document.querySelector('[data-extension-view]')).toBeNull();
    expect(document.querySelector('.skeleton-stack')).toBeNull();
    expect(screen.queryByText('Server detail')).toBeNull();
  });

  it('keeps the latest response when navigation resolves out of order and cleans listeners', async () => {
    const fetchMock = mockFetch(registeredMeta, '<a href="/wurk/ext/demo_locks/slow">Slow</a><a href="/wurk/ext/demo_locks/fast">Fast</a>');
    vi.stubGlobal('fetch', fetchMock);
    const { unmount } = renderAt('/ext/locks');
    await waitFor(() => expect(staticText('Slow')).toBeInTheDocument());
    const slow = deferredResponse();
    const fast = deferredResponse();
    fetchMock.mockImplementation(async (input) => String(input).endsWith('/slow') ? slow.promise : fast.promise);
    const oldLink = staticText('Slow');
    const root = shadow();
    const removeListener = vi.spyOn(root, 'removeEventListener');
    oldLink.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    staticText('Fast').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    fast.resolve(response('<p>Newest</p>'));
    await waitFor(() => expect(staticText('Newest')).toBeInTheDocument());
    slow.resolve(response('<p>Stale</p>'));
    await new Promise((done) => setTimeout(done, 0));
    expect(root.textContent).not.toContain('Stale');
    unmount();
    expect(removeListener).toHaveBeenCalledWith('click', expect.any(Function));
    expect(removeListener).toHaveBeenCalledWith('submit', expect.any(Function));
  });

  describe('link interception', () => {
    const meta = {
      read_only: false,
      read_only_message: null,
      custom_tabs: [{ name: 'Demo Locks', path: 'locks/', ext_name: 'demo_locks' }],
    };
    const html = '<a href="/wurk/ext/demo_locks/locks/abc">detail</a><a href="/wurk/ext/demo_locks/locks/x" target="_blank">ext</a>';

    async function setup() {
      const fetchMock = mockFetch(meta, html);
      vi.stubGlobal('fetch', fetchMock);
      renderAt('/ext/locks');
      await waitFor(() => expect(staticText('detail')).toBeInTheDocument());
      const extCalls = () => fetchMock.mock.calls.map((c) => String(c[0])).filter((u) => u.includes('/ext/'));
      return { extCalls };
    }

    // Records whether the SPA claimed the click, then cancels it at the window
    // so jsdom doesn't attempt (and log) a real navigation for the ones it left.
    function click(el: Element, init: MouseEventInit) {
      let defaultPrevented = false;
      const sink = (e: Event) => {
        defaultPrevented = e.defaultPrevented;
        e.preventDefault();
      };
      window.addEventListener('click', sink, { once: true });
      el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true, ...init }));
      return { defaultPrevented };
    }

    it('intercepts a plain primary click and loads in place', async () => {
      const { extCalls } = await setup();
      const ev = click(staticText('detail'), { button: 0 });
      expect(ev.defaultPrevented).toBe(true);
      await waitFor(() => expect(extCalls()).toContain('/wurk/ext/demo_locks/locks/abc'));
    });

    it.each([
      ['meta', { metaKey: true }],
      ['ctrl', { ctrlKey: true }],
      ['shift', { shiftKey: true }],
      ['alt', { altKey: true }],
      ['middle button', { button: 1 }],
    ])('leaves a %s click to the browser', async (_label, init) => {
      const { extCalls } = await setup();
      const before = extCalls().length;
      const ev = click(staticText('detail'), { button: 0, ...init });
      expect(ev.defaultPrevented).toBe(false);
      expect(extCalls().length).toBe(before);
    });

    it('leaves a target=_blank link to the browser', async () => {
      await setup();
      const ev = click(staticText('ext'), { button: 0 });
      expect(ev.defaultPrevented).toBe(false);
    });
  });
});

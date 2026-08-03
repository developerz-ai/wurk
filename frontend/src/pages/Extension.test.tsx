import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Extension from './Extension';

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
      '<h2>Demo Locks</h2><td>WelcomeEmailJob</td>',
    );
    vi.stubGlobal('fetch', fetchMock);

    renderAt('/ext/locks');

    await waitFor(() => expect(screen.getByText('WelcomeEmailJob')).toBeInTheDocument());
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
});

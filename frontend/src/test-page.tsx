import { vi } from 'vitest';
import { render } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import type { Component } from 'solid-js';
import { Toasts } from './toast';

// Shared harness for page tests: a fetch stub answering /api/meta itself, and
// one page mounted under a memory router with the toast stack beside it.

export type FetchHandler = (url: URL, init?: RequestInit) => unknown;

export function stubFetch(handler: FetchHandler, { readOnly = false } = {}) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input), 'http://x');
    const body = url.pathname.endsWith('/api/meta') ? { read_only: readOnly } : await handler(url, init);
    return { ok: true, status: 200, json: async () => body } as Response;
  });
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}

/** The URLs (with their methods) the page sent, minus /api/meta. */
export function requests(fetchMock: ReturnType<typeof stubFetch>) {
  return fetchMock.mock.calls
    .map(([input, init]) => ({ url: new URL(String(input), 'http://x'), method: init?.method ?? 'GET', init }))
    .filter(({ url }) => !url.pathname.endsWith('/api/meta'));
}

export function renderPage(path: string, routePath: string, page: Component) {
  const history = createMemoryHistory();
  history.set({ value: path, replace: true });
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path={routePath} component={page} />
      </MemoryRouter>
      <Toasts />
    </QueryClientProvider>
  ));
  return history;
}

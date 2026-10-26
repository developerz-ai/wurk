import { describe, it, expect, vi, afterEach } from 'vitest';
import { render } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import type { ParentProps } from 'solid-js';
import Nav from './Nav';
import { NAV_PANES, paneLabel } from '../navPanes';

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } });
}

function mockMeta() {
  return vi.fn((url: string) => {
    const body = url.includes('/api/meta') ? { read_only: false, custom_tabs: [] } : {};
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
  });
}

// The nav lives in the router's root, so its links render inside a route
// context — the same shape the app shell mounts it in.
function Shell(props: ParentProps) {
  return (
    <>
      <Nav open={false} onClose={() => {}} collapsed={false} onToggleCollapse={() => {}} />
      {props.children}
    </>
  );
}

describe('nav rail', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('renders exactly the pane inventory, in order', () => {
    vi.stubGlobal('fetch', mockMeta());
    const history = createMemoryHistory();
    history.set({ value: '/', replace: true });

    const { container } = render(() => (
      <QueryClientProvider client={client()}>
        <MemoryRouter history={history} root={Shell}>
          <Route path="*" component={() => <main>PAGE</main>} />
        </MemoryRouter>
      </QueryClientProvider>
    ));

    // The brand and GitHub links sit outside the list, and the extension tabs
    // are empty, so every link in the list is a shipped pane.
    const links = [...container.querySelectorAll('ul li a.wurk-navlink')] as HTMLAnchorElement[];

    expect(links.length).toBe(NAV_PANES.length);
    expect(links.map((link) => link.getAttribute('href'))).toEqual(NAV_PANES.map((pane) => pane.to));
    expect(links.map((link) => link.textContent?.trim())).toEqual(
      NAV_PANES.map((pane) => paneLabel(pane)),
    );
    expect(links.map((link) => link.getAttribute('title'))).toEqual(
      NAV_PANES.map((pane) => paneLabel(pane)),
    );
  });
});

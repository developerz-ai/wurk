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

  // Non-en strings arrive in a lazy chunk after the entry graph has run
  // (main.tsx renders once `ready` settles), so a label resolved at import
  // time would be stuck in English. The gate holds the German chunk until Nav
  // and everything it imports have evaluated — the order a browser runs them.
  it('labels the rail in a lazily loaded locale', async () => {
    vi.stubGlobal('fetch', mockMeta());
    localStorage.setItem('wurk.locale', 'de');
    const de = (await import('../i18n/de.json')).default;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    vi.doMock('../i18n/de.json', async () => {
      await gate;
      return { default: de };
    });
    try {
      vi.resetModules();
      const { render: renderFresh } = await import('@solidjs/testing-library');
      const router = await import('@solidjs/router');
      const query = await import('@tanstack/solid-query');
      const { default: FreshNav } = await import('./Nav');
      const i18n = await import('../i18n');
      release();
      await i18n.ready;

      const history = router.createMemoryHistory();
      history.set({ value: '/', replace: true });
      const { container } = renderFresh(() => (
        <query.QueryClientProvider client={new query.QueryClient()}>
          <router.MemoryRouter
            history={history}
            root={() => <FreshNav open={false} onClose={() => {}} collapsed={false} onToggleCollapse={() => {}} />}
          >
            <router.Route path="*" component={() => null} />
          </router.MemoryRouter>
        </query.QueryClientProvider>
      ));

      const labels = [...container.querySelectorAll('ul li a.wurk-navlink')].map((link) => link.textContent?.trim());
      expect(labels).toContain(de.nav.queues);
      expect(labels).not.toContain('Queues');
    } finally {
      vi.doUnmock('../i18n/de.json');
      localStorage.removeItem('wurk.locale');
    }
  });
});

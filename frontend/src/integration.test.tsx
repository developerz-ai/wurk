import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, within } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import type { ParentProps } from 'solid-js';
import Nav from './components/Nav';
import { ReadOnlyBanner } from './App';
import Retries from './pages/Retries';

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } });
}

describe('routing + nav', () => {
  afterEach(() => vi.unstubAllGlobals());

  function mockMeta() {
    return vi.fn((url: string) => {
      const body = url.includes('/api/meta') ? { read_only: false, custom_tabs: [] } : {};
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
    });
  }

  function Shell(props: ParentProps) {
    return (
      <>
        <Nav open={false} onClose={() => {}} collapsed={false} onToggleCollapse={() => {}} />
        {props.children}
      </>
    );
  }

  function renderApp() {
    const history = createMemoryHistory();
    history.set({ value: '/', replace: true });
    return render(() => (
      <QueryClientProvider client={client()}>
        <MemoryRouter history={history} root={Shell}>
          <Route path="/" component={() => <main>DASHBOARD PAGE</main>} />
          <Route path="/queues" component={() => <main>QUEUES PAGE</main>} />
          <Route path="/retries" component={() => <main>RETRIES PAGE</main>} />
        </MemoryRouter>
      </QueryClientProvider>
    ));
  }

  it('swaps the page and marks the nav link active on navigation', async () => {
    vi.stubGlobal('fetch', mockMeta());
    renderApp();

    expect(await screen.findByText('DASHBOARD PAGE')).toBeInTheDocument();
    const dashLink = screen.getByRole('link', { name: 'Wurk — dashboard home' });
    expect(dashLink).toHaveAttribute('aria-current', 'page');

    const queuesLink = screen.getByRole('link', { name: 'Queues' });
    fireEvent.click(queuesLink);

    expect(await screen.findByText('QUEUES PAGE')).toBeInTheDocument();
    expect(queuesLink).toHaveClass('active');
    expect(queuesLink).toHaveAttribute('aria-current', 'page');
    // The home link only matches "/" exactly, so it drops active off the root.
    expect(dashLink).not.toHaveAttribute('aria-current');
  });
});

describe('read-only banner', () => {
  afterEach(() => vi.unstubAllGlobals());

  function mockMeta(meta: unknown) {
    return vi.fn((url: string) => {
      const body = url.includes('/api/meta') ? meta : {};
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
    });
  }

  it('renders host-supplied copy when read_only is true', async () => {
    vi.stubGlobal('fetch', mockMeta({ read_only: true, read_only_message: 'Maintenance in progress' }));
    render(() => (
      <QueryClientProvider client={client()}>
        <ReadOnlyBanner />
      </QueryClientProvider>
    ));
    expect(await screen.findByText('Maintenance in progress')).toBeInTheDocument();
    expect(screen.getByRole('status')).toBeInTheDocument();
  });

  it('stays hidden when read_only is false', async () => {
    const fetchMock = mockMeta({ read_only: false, read_only_message: null });
    vi.stubGlobal('fetch', fetchMock);
    render(() => (
      <QueryClientProvider client={client()}>
        <ReadOnlyBanner />
      </QueryClientProvider>
    ));
    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    expect(screen.queryByRole('status')).toBeNull();
  });
});

describe('Retries bulk-action flow', () => {
  const NOW = Date.now() / 1000;
  const ENTRIES = [
    { jid: 'j1', klass: 'AlphaJob', args: [1], error_class: 'RuntimeError', error_message: 'boom', at: NOW + 60, retry_count: 1, score: 111.5 },
    { jid: 'j2', klass: 'BetaJob', args: [], error_class: 'ArgumentError', error_message: 'bad', at: NOW + 120, retry_count: 2, score: 222.25 },
  ];

  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    HTMLDialogElement.prototype.showModal = vi.fn();
    HTMLDialogElement.prototype.close = vi.fn();
    vi.stubGlobal('confirm', vi.fn(() => true));
    fetchMock = vi.fn((url: string, init?: RequestInit) => {
      let body: unknown = {};
      if (url.includes('/api/meta')) body = { read_only: false, custom_tabs: [] };
      else if (url.includes('/api/retries') && (!init || init.method !== 'POST'))
        body = { total: ENTRIES.length, page: 0, count: ENTRIES.length, entries: ENTRIES };
      else if (url.includes('/api/stats')) body = { processed: 0, failed: 0, latency: 0, processes: 0 };
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response);
    });
    vi.stubGlobal('fetch', fetchMock);
  });
  afterEach(() => vi.unstubAllGlobals());

  function renderRetries() {
    const history = createMemoryHistory();
    history.set({ value: '/retries', replace: true });
    const qc = client();
    const spy = vi.spyOn(qc, 'invalidateQueries');
    render(() => (
      <QueryClientProvider client={qc}>
        <MemoryRouter history={history}>
          <Route path="/retries" component={Retries} />
        </MemoryRouter>
      </QueryClientProvider>
    ));
    return { spy };
  }

  it('selects a row and POSTs a bulk retry, then re-fetches the set', async () => {
    const { spy } = renderRetries();

    // Wait for the rows to render.
    expect(await screen.findByText('AlphaJob')).toBeInTheDocument();

    // Select the first job row.
    const checkboxes = screen.getAllByLabelText('Select job');
    fireEvent.click(checkboxes[0]);
    expect((checkboxes[0] as HTMLInputElement).checked).toBe(true);

    // The bulk "Retry" button lives in the action bar (the "Retry All" button is
    // in the same bar but has a distinct accessible name).
    const bar = document.querySelector('.action-bar') as HTMLElement;
    const retryBtn = within(bar).getByRole('button', { name: 'Retry' });
    fireEvent.click(retryBtn);

    // The bulk endpoint is POSTed with the selected (score|jid) key.
    await waitFor(() => {
      const post = fetchMock.mock.calls.find(
        (c) => String(c[0]) === '/wurk/api/retries' && (c[1] as RequestInit)?.method === 'POST',
      );
      expect(post).toBeTruthy();
      expect(JSON.parse((post![1] as RequestInit).body as string)).toEqual({ keys: ['111.5|j1'], cmd: 'retry' });
    });

    // onSuccess re-fetches by invalidating the set's own query and the stats
    // badges that read from it.
    await waitFor(() => {
      expect(spy).toHaveBeenCalledWith({ queryKey: ['retries'] });
      expect(spy).toHaveBeenCalledWith({ queryKey: ['stats'] });
    });
    // Selection is cleared once the bulk action resolves.
    await waitFor(() => expect((checkboxes[0] as HTMLInputElement).checked).toBe(false));
  });
});

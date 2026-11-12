import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Retries from './Retries';
import { t } from '../i18n';
import { Toasts, dismissToast, toasts } from '../toast';
import { requests, stubFetch } from '../test-page';

const NOW = Math.floor(Date.now() / 1000);

function entry(i: number) {
  return {
    jid: `jid${i}`,
    klass: `Job${i}`,
    args: [i],
    error_class: 'RuntimeError',
    error_message: 'boom',
    at: NOW + 60,
    retry_count: 1,
    score: NOW + 60 + i,
  };
}

type Handler = (url: URL) => Promise<unknown> | unknown;

function stub(handler: Handler) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = new URL(String(input), 'http://x');
    const body = url.pathname.endsWith('/api/meta') ? { read_only: false } : await handler(url);
    return { ok: true, status: 200, json: async () => body } as Response;
  });
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}

function renderRetries(path = '/retries') {
  const history = createMemoryHistory();
  history.set({ value: path, replace: true });
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path="/retries" component={Retries} />
      </MemoryRouter>
      <Toasts />
    </QueryClientProvider>
  ));
  return history;
}

const retryRequests = (fetchMock: ReturnType<typeof stub>) =>
  fetchMock.mock.calls.map((c) => new URL(String(c[0]), 'http://x')).filter((u) => u.pathname.endsWith('/api/retries'));

afterEach(() => {
  vi.unstubAllGlobals();
  for (const toast of toasts()) dismissToast(toast.id);
});

describe('job-set filter (W4)', () => {
  it('keeps the filter input mounted and focused while the filtered page loads', async () => {
    const fetchMock = stub((url) => {
      // The filtered request never settles: the page sits in its loading state.
      if (url.searchParams.get('substr')) return new Promise(() => {});
      return { total: 2, page: 0, count: 25, entries: [entry(1), entry(2)] };
    });
    renderRetries();

    const input = (await screen.findByRole('searchbox')) as HTMLInputElement;
    input.focus();
    fireEvent.input(input, { target: { value: 'Job1' } });

    await waitFor(() => expect(retryRequests(fetchMock).some((u) => u.searchParams.get('substr') === 'Job1')).toBe(true));
    expect(screen.getByRole('searchbox')).toBe(input);
    expect(input.isConnected).toBe(true);
    expect(document.activeElement).toBe(input);
    expect(input.value).toBe('Job1');
  });
});

describe('job-set pagination (W5)', () => {
  it('adopts the page the server actually served when it clamps ?page=', async () => {
    const fetchMock = stub((url) => {
      const requested = Number(url.searchParams.get('page'));
      return { total: 1_000_000, page: Math.min(requested, 999), count: 25, max_page: 999, entries: [entry(1)] };
    });
    renderRetries('/retries?page=5001');

    await waitFor(() => expect(retryRequests(fetchMock).some((u) => u.searchParams.get('page') === '999')).toBe(true));
    expect(await screen.findByText(`${t('common.page')} 1000 ${t('common.of')} 1000`)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: t('actions.next') })).toBeDisabled();
  });
});

describe('job-set "all" actions under a filter (#101 W4)', () => {
  it('turns Retry/Kill/Delete All into actions over the matches and shows the matching count', async () => {
    stub((url) =>
      url.searchParams.get('substr')
        ? { total: 500, page: 0, count: 25, entries: [entry(1)], filtered_total: 20_000, filtered_total_exact: false }
        : { total: 500, page: 0, count: 25, entries: [entry(1), entry(2)] },
    );
    renderRetries();

    const allRetry = () => screen.getByRole('button', { name: `${t('actions.retry')} ${t('actions.all_suffix')}` });
    await waitFor(() => expect(allRetry()).not.toBeDisabled());

    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'Job1' } });

    const matchRetry = await screen.findByRole('button', { name: `${t('actions.retry')} ${t('actions.matching_suffix')}` });
    expect(matchRetry).not.toBeDisabled();
    expect(screen.getByRole('button', { name: `${t('actions.kill')} ${t('actions.matching_suffix')}` })).not.toBeDisabled();
    expect(screen.getByRole('button', { name: `${t('actions.delete')} ${t('actions.matching_suffix')}` })).not.toBeDisabled();
    expect(await screen.findByText(t('actions.matching', { n: '20,000+' }))).toBeInTheDocument();
    expect(screen.getByText(t('common.matching', { n: '20,000+' }))).toBeInTheDocument();
    // The whole-set badge still reports the unfiltered total.
    expect(screen.getByText('500')).toBeInTheDocument();
  });

  it('confirms, then follows the sweep cursor until the server reports done', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
    const fetchMock = stubFetch((url) => {
      if (url.pathname.endsWith('/all/retry')) {
        return url.searchParams.get('cursor') === '0'
          ? { ok: true, count: 1000, matched: 1000, done: false, cursor: 19000 }
          : { ok: true, count: 4, matched: 4, done: true, cursor: 25000 };
      }
      return { total: 500, page: 0, count: 25, entries: [entry(1)], filtered_total: 1004, filtered_total_exact: true };
    });
    renderRetries();

    await screen.findByText('Job1');
    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'boom' } });
    fireEvent.click(await screen.findByRole('button', { name: `${t('actions.retry')} ${t('actions.matching_suffix')}` }));

    expect(await screen.findByText(t('toast.swept', { n: 1004 }))).toBeInTheDocument();
    expect(confirm).toHaveBeenCalledOnce();
    const sweeps = requests(fetchMock).filter(({ url }) => url.pathname.endsWith('/api/retries/all/retry'));
    expect(sweeps.map(({ url }) => [url.searchParams.get('substr'), url.searchParams.get('cursor')])).toEqual([
      ['boom', '0'],
      ['boom', '19000'],
    ]);
    expect(sweeps.every(({ method }) => method === 'POST')).toBe(true);
    confirm.mockRestore();
  });

  async function startSweep(onSweep: (url: URL) => unknown) {
    const fetchMock = stubFetch((url) => {
      if (url.pathname.endsWith('/all/retry')) return onSweep(url);
      return { total: 500, page: 0, count: 25, entries: [entry(1)], filtered_total: 1004, filtered_total_exact: true };
    });
    renderRetries();
    await screen.findByText('Job1');
    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'boom' } });
    fireEvent.click(await screen.findByRole('button', { name: `${t('actions.retry')} ${t('actions.matching_suffix')}` }));
    return fetchMock;
  }

  const sweepsOf = (fetchMock: ReturnType<typeof stubFetch>) =>
    requests(fetchMock).filter(({ url }) => url.pathname.endsWith('/api/retries/all/retry'));
  const listReadsOf = (fetchMock: ReturnType<typeof stubFetch>) =>
    requests(fetchMock).filter(({ url, method }) => method === 'GET' && url.pathname.endsWith('/api/retries'));

  it('stops after 100 requests on a set that never ends and says there is more', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
    let cursor = 0;
    const fetchMock = await startSweep(() => ({ ok: true, count: 10, matched: 10, done: false, cursor: (cursor += 1000) }));

    expect(await screen.findByText(t('toast.swept_partial', { n: 1000 }))).toBeInTheDocument();
    expect(sweepsOf(fetchMock)).toHaveLength(100);
    confirm.mockRestore();
  });

  it('refreshes the list when a later sweep page fails after earlier ones applied', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
    const fetchMock = await startSweep((url) => {
      if (url.searchParams.get('cursor') === '0') return { ok: true, count: 1000, matched: 1000, done: false, cursor: 19000 };
      throw new TypeError('network down');
    });

    await waitFor(() => expect(sweepsOf(fetchMock)).toHaveLength(2));
    const readsAtFailure = listReadsOf(fetchMock).length;
    await waitFor(() => expect(listReadsOf(fetchMock).length).toBeGreaterThan(readsAtFailure));
    confirm.mockRestore();
  });
});

describe('job detail backtrace (07-A16)', () => {
  // jsdom has no <dialog> modality; Modal only needs the calls to exist.
  const dialog = Object.fromEntries(['showModal', 'close'].map((name) => [name, Object.getOwnPropertyDescriptor(HTMLDialogElement.prototype, name)]));
  beforeEach(() => {
    HTMLDialogElement.prototype.showModal = vi.fn();
    HTMLDialogElement.prototype.close = vi.fn();
  });
  afterEach(() => {
    for (const [name, descriptor] of Object.entries(dialog)) {
      if (descriptor) Object.defineProperty(HTMLDialogElement.prototype, name, descriptor);
      else delete (HTMLDialogElement.prototype as unknown as Record<string, unknown>)[name];
    }
  });

  it('reads the backtrace from the entry endpoint, since listing rows leave it out', async () => {
    const row = entry(1);
    const key = `${row.score}|${row.jid}`;
    const fetchMock = stub((url) =>
      url.pathname.endsWith('/api/retries')
        ? { total: 1, page: 0, count: 25, entries: [row] }
        : { ...row, error_backtrace: ['app/jobs/job1.rb:3:in perform'] },
    );
    renderRetries();

    fireEvent.click(await screen.findByText('Job1'));

    expect(await screen.findByText('app/jobs/job1.rb:3:in perform')).toBeInTheDocument();
    const detail = fetchMock.mock.calls.map((c) => new URL(String(c[0]), 'http://x')).find((u) => u.pathname.includes('/api/retries/'));
    expect(decodeURIComponent(detail!.pathname.split('/api/retries/')[1])).toBe(key);
  });
});

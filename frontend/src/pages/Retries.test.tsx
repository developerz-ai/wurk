import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import Retries from './Retries';
import { t } from '../i18n';

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
    </QueryClientProvider>
  ));
  return history;
}

const retryRequests = (fetchMock: ReturnType<typeof stub>) =>
  fetchMock.mock.calls.map((c) => new URL(String(c[0]), 'http://x')).filter((u) => u.pathname.endsWith('/api/retries'));

afterEach(() => vi.unstubAllGlobals());

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

describe('job-set "all" actions under a filter (W10)', () => {
  it('disables Retry/Kill/Delete All and shows the matching count while a filter is active', async () => {
    stub((url) =>
      url.searchParams.get('substr')
        ? { total: 500, page: 0, count: 25, entries: [entry(1)], filtered_total: 20_000, filtered_total_exact: false }
        : { total: 500, page: 0, count: 25, entries: [entry(1), entry(2)] },
    );
    renderRetries();

    const allRetry = () => screen.getByRole('button', { name: `${t('actions.retry')} ${t('actions.all_suffix')}` });
    await waitFor(() => expect(allRetry()).not.toBeDisabled());

    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'Job1' } });

    await waitFor(() => expect(allRetry()).toBeDisabled());
    expect(allRetry()).toHaveAttribute('title', t('actions.all_filtered_hint'));
    expect(screen.getByRole('button', { name: `${t('actions.kill')} ${t('actions.all_suffix')}` })).toBeDisabled();
    expect(screen.getByRole('button', { name: `${t('actions.delete')} ${t('actions.all_suffix')}` })).toBeDisabled();
    expect(await screen.findByText(t('actions.matching', { n: '20,000+' }))).toBeInTheDocument();
    expect(screen.getByText(t('common.matching', { n: '20,000+' }))).toBeInTheDocument();
    // The whole-set badge still reports the unfiltered total those buttons act on.
    expect(screen.getByText('500')).toBeInTheDocument();
  });
});

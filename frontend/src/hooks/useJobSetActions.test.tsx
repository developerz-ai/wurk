import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { entryKey, useJobSetActions, type JobSetName } from './useJobSetActions';
import { Toasts } from '../toast';
import { t } from '../i18n';

describe('entryKey', () => {
  it('joins score and jid with a pipe, mirroring Wurk::SortedEntry#id', () => {
    expect(entryKey({ score: 1689999999.5, jid: 'abc123' })).toBe('1689999999.5|abc123');
  });
});

function mockFetch(status: number) {
  return vi.fn((_url: string, _init?: RequestInit) => {
    if (status >= 200 && status < 300) {
      return Promise.resolve({ ok: true, status, json: () => Promise.resolve({}) } as Response);
    }
    return Promise.resolve({ ok: false, status, json: () => Promise.resolve({}) } as Response);
  });
}

// A minimal harness so single/bulk/all mutations run inside a real component
// tree — solid-query's useMutation needs a QueryClientProvider ancestor, and
// asserting the onError → notifyError → toast chain needs <Toasts /> mounted.
function Harness(props: { set: JobSetName }) {
  const actions = useJobSetActions(props.set);
  return (
    <div>
      <Toasts />
      <button onClick={() => actions.single.mutate({ key: entryKey({ score: 1, jid: 'j1' }), cmd: 'retry' })}>
        single
      </button>
      <button onClick={() => actions.bulk.mutate({ keys: [entryKey({ score: 1, jid: 'j1' })], cmd: 'retry' })}>
        bulk
      </button>
      <button onClick={() => actions.all.mutate('delete')}>all</button>
    </div>
  );
}

function renderHarness(set: JobSetName, status: number) {
  const fetchMock = mockFetch(status);
  vi.stubGlobal('fetch', fetchMock);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  const invalidateSpy = vi.spyOn(client, 'invalidateQueries');
  render(() => (
    <QueryClientProvider client={client}>
      <Harness set={set} />
    </QueryClientProvider>
  ));
  return { fetchMock, invalidateSpy };
}

describe('useJobSetActions', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('single.mutate POSTs to /api/<set>/<encoded key> with the cmd body', async () => {
    const { fetchMock } = renderHarness('retries', 200);
    fireEvent.click(screen.getByText('single'));

    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(`/wurk/api/retries/${encodeURIComponent(entryKey({ score: 1, jid: 'j1' }))}`);
    expect(init.method).toBe('POST');
    expect(JSON.parse(init.body as string)).toEqual({ cmd: 'retry' });
  });

  it('bulk.mutate POSTs keys + cmd to /api/<set>', async () => {
    const { fetchMock } = renderHarness('scheduled', 200);
    fireEvent.click(screen.getByText('bulk'));

    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('/wurk/api/scheduled');
    expect(JSON.parse(init.body as string)).toEqual({ keys: [entryKey({ score: 1, jid: 'j1' })], cmd: 'retry' });
  });

  it('all.mutate POSTs to /api/<set>/all/<cmd> with no body', async () => {
    const { fetchMock } = renderHarness('dead', 200);
    fireEvent.click(screen.getByText('all'));

    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('/wurk/api/dead/all/delete');
    expect(init.body).toBeUndefined();
  });

  it('invalidates both the set query and stats on success', async () => {
    const { invalidateSpy } = renderHarness('retries', 200);
    fireEvent.click(screen.getByText('single'));

    await waitFor(() =>
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['retries'] }),
    );
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['stats'] });
  });

  it('does not invalidate on a failed request', async () => {
    const { invalidateSpy } = renderHarness('retries', 500);
    fireEvent.click(screen.getByText('single'));

    await screen.findByText(t('toast.failed'));
    expect(invalidateSpy).not.toHaveBeenCalled();
  });

  it('surfaces a read-only toast when the mutation throws a 403', async () => {
    renderHarness('retries', 403);
    fireEvent.click(screen.getByText('single'));
    expect(await screen.findByText(t('toast.readonly'))).toBeInTheDocument();
  });

  it('surfaces the Redis-unavailable toast on a 503', async () => {
    renderHarness('dead', 503);
    fireEvent.click(screen.getByText('all'));
    expect(await screen.findByText(t('toast.unavailable'))).toBeInTheDocument();
  });
});

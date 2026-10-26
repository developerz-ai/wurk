import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { entryKey, useJobSetActions, type JobSetName } from './useJobSetActions';
import { Toasts, toasts, dismissToast } from '../toast';
import { t } from '../i18n';

describe('entryKey', () => {
  it('joins score and jid with a pipe, mirroring Wurk::SortedEntry#id', () => {
    expect(entryKey({ score: 1689999999.5, jid: 'abc123' })).toBe('1689999999.5|abc123');
  });
});

function mockFetch(status: number, body: unknown = {}) {
  return vi.fn((_url: string, _init?: RequestInit) => {
    if (status >= 200 && status < 300) {
      return Promise.resolve({ ok: true, status, json: () => Promise.resolve(body) } as Response);
    }
    return Promise.resolve({ ok: false, status, json: () => Promise.resolve(body) } as Response);
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

function renderHarness(set: JobSetName, status: number, body?: unknown) {
  const fetchMock = mockFetch(status, body);
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
  afterEach(() => {
    vi.unstubAllGlobals();
    // The toast list is module-global; a leftover from one case would satisfy
    // the next case's findByText before its own mutation settles.
    for (const toast of toasts()) dismissToast(toast.id);
  });

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

  it.each(['single', 'bulk', 'all'])('a 422 partial failure from %s toasts the counts and every diagnostic, and still refreshes the list', async (btn) => {
    const { invalidateSpy } = renderHarness('retries', 422, {
      ok: false,
      count: 3,
      failed: [{ key: '1|j1', error: 'RuntimeError: boom' }, { key: '2|j2', error: 'TypeError: invalid job' }],
    });
    fireEvent.click(screen.getByText(btn));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(t('toast.partial', { count: 3, failed: 2 }));
    expect(alert).toHaveTextContent('1|j1: RuntimeError: boom');
    expect(alert).toHaveTextContent('2|j2: TypeError: invalid job');
    expect(screen.getAllByRole('alert')).toHaveLength(1);
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['retries'] });
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['stats'] });
  });

  it.each(['single', 'bulk', 'all'])('keeps counts, valid fields and invalidations despite malformed diagnostics from %s', async (btn) => {
    const failed = [
      null, 'not an entry', 42, false, [], {},
      { key: null, error: null },
      { key: 'key-only' },
      { error: 'error-only' },
      { key: 'valid-key', error: { message: 'do not stringify' } },
      { key: { jid: 'do not stringify' }, error: 'valid-error' },
      { key: 123, error: false },
      { key: 'complete-key', error: 'complete-error' },
    ];
    const { invalidateSpy } = renderHarness('scheduled', 422, { count: 4, failed });
    fireEvent.click(screen.getByText(btn));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(t('toast.partial', { count: 4, failed: failed.length }));
    for (const diagnostic of ['key-only', 'error-only', 'valid-key', 'valid-error', 'complete-key: complete-error']) {
      expect(alert).toHaveTextContent(diagnostic);
    }
    for (const invalid of ['[object Object]', 'do not stringify', 'undefined', 'null', 'not an entry', '123', 'false']) {
      expect(alert).not.toHaveTextContent(invalid);
    }
    expect(screen.getAllByRole('alert')).toHaveLength(1);
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['scheduled'] });
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['stats'] });
  });

  it('keeps more than five failure diagnostics in one plain-text toast', async () => {
    const failed = Array.from({ length: 7 }, (_, index) => ({
      key: `${index}|job-${index}`,
      error: `<strong>failure-${index}</strong>`,
    }));
    const { invalidateSpy } = renderHarness('dead', 422, { count: 2, failed });
    fireEvent.click(screen.getByText('bulk'));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(t('toast.partial', { count: 2, failed: 7 }));
    for (const entry of failed) {
      expect(alert).toHaveTextContent(`${entry.key}: ${entry.error}`);
    }
    expect(alert.querySelector('strong')).toBeNull();
    expect(screen.getAllByRole('alert')).toHaveLength(1);
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['dead'] });
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['stats'] });
  });

  it('treats a 422 without the partial-failure shape as a plain failure', async () => {
    const { invalidateSpy } = renderHarness('retries', 422, { error: 'nope' });
    fireEvent.click(screen.getByText('bulk'));

    expect(await screen.findByText(t('toast.failed'))).toBeInTheDocument();
    expect(invalidateSpy).not.toHaveBeenCalled();
  });
});

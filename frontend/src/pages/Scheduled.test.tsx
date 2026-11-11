import { describe, it, expect, vi, afterEach } from 'vitest';
import { screen, fireEvent, waitFor } from '@solidjs/testing-library';
import Scheduled from './Scheduled';
import { t } from '../i18n';
import { dismissToast, toasts } from '../toast';
import { requests, renderPage, stubFetch } from '../test-page';

const NOW = Math.floor(Date.now() / 1000);

function entry(i: number) {
  return { jid: `jid${i}`, klass: `Later${i}`, args: [i], at: NOW + 3600, score: NOW + 3600 + i, queue: 'default' };
}

const page = (entries = [entry(1), entry(2)]) => ({ total: entries.length, page: 0, count: 25, entries });

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  for (const toast of toasts()) dismissToast(toast.id);
});

describe('Scheduled page', () => {
  it('lists each scheduled job', async () => {
    stubFetch(() => page());
    renderPage('/scheduled', '/scheduled', Scheduled);

    expect(await screen.findByText('Later1')).toBeInTheDocument();
    expect(screen.getByText('Later2')).toBeInTheDocument();
  });

  it('enqueues the selected jobs now with one bulk POST, no confirm', async () => {
    const confirm = vi.spyOn(window, 'confirm');
    const fetchMock = stubFetch((url) => (url.pathname.endsWith('/api/scheduled') ? page() : { ok: true, count: 1 }));
    renderPage('/scheduled', '/scheduled', Scheduled);

    await screen.findByText('Later1');
    fireEvent.click(screen.getAllByRole('checkbox', { name: t('table.select_row') })[0]);
    fireEvent.click(screen.getByRole('button', { name: t('actions.add_to_queue') }));

    await waitFor(() => expect(requests(fetchMock).some(({ method }) => method === 'POST')).toBe(true));
    expect(confirm).not.toHaveBeenCalled();
    const bulk = requests(fetchMock).find(({ method }) => method === 'POST')!;
    expect(bulk.url.pathname).toBe('/wurk/api/scheduled');
    expect(JSON.parse(String(bulk.init!.body)).cmd).toBe('add_to_queue');
    expect(JSON.parse(String(bulk.init!.body)).keys).toHaveLength(1);
  });

  it('surfaces a cross-origin refusal as its own toast', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const fetchMock = stubFetch(() => page());
    fetchMock.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), 'http://x');
      if (init?.method === 'POST') {
        return { ok: false, status: 403, json: async () => ({ error: 'cross_origin' }) } as Response;
      }
      const body = url.pathname.endsWith('/api/meta') ? { read_only: false } : page();
      return { ok: true, status: 200, json: async () => body } as Response;
    });
    renderPage('/scheduled', '/scheduled', Scheduled);

    await screen.findByText('Later1');
    fireEvent.click(screen.getByRole('button', { name: `${t('actions.delete')} ${t('actions.all_suffix')}` }));

    expect(await screen.findByText(t('toast.crossOrigin'))).toBeInTheDocument();
  });

  it('shows no actions in read-only mode', async () => {
    stubFetch(() => page(), { readOnly: true });
    renderPage('/scheduled', '/scheduled', Scheduled);

    await screen.findByText('Later1');
    await waitFor(() => expect(screen.queryByRole('checkbox')).toBeNull());
  });
});

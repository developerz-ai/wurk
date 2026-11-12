import { describe, it, expect, vi, afterEach } from 'vitest';
import { screen, fireEvent, waitFor } from '@solidjs/testing-library';
import Dead from './Dead';
import { t } from '../i18n';
import { dismissToast, toasts } from '../toast';
import { requests, renderPage, stubFetch } from '../test-page';

const NOW = Math.floor(Date.now() / 1000);

function entry(i: number) {
  return {
    jid: `jid${i}`,
    klass: `Job${i}`,
    args: [i],
    error_class: 'Net::ReadTimeout',
    error_message: `timed out ${i}`,
    at: NOW - 60,
    score: NOW - 60 + i,
  };
}

const page = (entries = [entry(1), entry(2)]) => ({ total: entries.length, page: 0, count: 25, entries });

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  for (const toast of toasts()) dismissToast(toast.id);
});

describe('Dead page', () => {
  it('lists each dead job with its error class and message', async () => {
    stubFetch(() => page());
    renderPage('/dead', '/dead', Dead);

    expect(await screen.findByText('Job1')).toBeInTheDocument();
    expect(screen.getAllByText('Net::ReadTimeout')).toHaveLength(2);
    expect(screen.getByText('timed out 2')).toBeInTheDocument();
  });

  it('filters by error or args through ?substr=', async () => {
    const fetchMock = stubFetch(() => page());
    renderPage('/dead', '/dead', Dead);

    const box = await screen.findByPlaceholderText(t('common.filter_placeholder_errors'));
    fireEvent.input(box, { target: { value: 'ReadTimeout' } });

    await waitFor(() =>
      expect(requests(fetchMock).some(({ url }) => url.searchParams.get('substr') === 'ReadTimeout')).toBe(true),
    );
  });

  it('deletes the selected rows in one bulk POST after a confirm', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
    const fetchMock = stubFetch((url) => (url.pathname.endsWith('/api/dead') ? page() : { ok: true, count: 2 }));
    renderPage('/dead', '/dead', Dead);

    await screen.findByText('Job1');
    fireEvent.click(screen.getByRole('checkbox', { name: t('table.select_all') }));
    fireEvent.click(screen.getByRole('button', { name: t('actions.delete') }));

    await waitFor(() => expect(requests(fetchMock).some(({ method }) => method === 'POST')).toBe(true));
    expect(confirm).toHaveBeenCalledOnce();
    const bulk = requests(fetchMock).find(({ method }) => method === 'POST')!;
    expect(bulk.url.pathname).toBe('/wurk/api/dead');
    expect(JSON.parse(String(bulk.init!.body))).toEqual({
      cmd: 'delete',
      keys: [`${entry(1).score}|jid1`, `${entry(2).score}|jid2`],
    });
  });

  it('shows no actions in read-only mode', async () => {
    stubFetch(() => page(), { readOnly: true });
    renderPage('/dead', '/dead', Dead);

    await screen.findByText('Job1');
    await waitFor(() => expect(screen.queryByRole('checkbox')).toBeNull());
    expect(screen.queryByRole('button', { name: `${t('actions.retry')} ${t('actions.all_suffix')}` })).toBeNull();
  });
});

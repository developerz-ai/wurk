import { describe, it, expect, vi, afterEach } from 'vitest';
import { screen, fireEvent, waitFor } from '@solidjs/testing-library';
import Batches from './Batches';
import { t } from '../i18n';
import { requests, renderPage, stubFetch } from '../test-page';

const NOW = Math.floor(Date.now() / 1000);

function batch(bid: string, extra: Record<string, unknown> = {}) {
  return {
    bid,
    description: `import ${bid}`,
    total: 10,
    pending: 4,
    failures: 1,
    complete: false,
    created_at: NOW - 60,
    complete_at: null,
    ...extra,
  };
}

const listing = (batches: ReturnType<typeof batch>[]) => ({ total: batches.length, page: 0, count: 25, batches });
const batchRequests = (fetchMock: ReturnType<typeof stubFetch>) =>
  requests(fetchMock).filter(({ url }) => url.pathname.endsWith('/api/batches'));

afterEach(() => vi.unstubAllGlobals());

describe('Batches page', () => {
  it('lists batches with their progress', async () => {
    stubFetch(() => listing([batch('b-live')]));
    renderPage('/batches', '/batches', Batches);

    expect(await screen.findByText('import b-live')).toBeInTheDocument();
    expect(screen.getByText('60%')).toBeInTheDocument();
  });

  it('switches to dead batches with ?dead=1, in the URL and the request', async () => {
    const fetchMock = stubFetch((url) =>
      url.searchParams.get('dead') === '1' ? listing([batch('b-dead')]) : listing([batch('b-live')]),
    );
    const history = renderPage('/batches', '/batches', Batches);

    await screen.findByText('import b-live');
    fireEvent.click(screen.getByRole('tab', { name: t('batches.dead') }));

    expect(await screen.findByText('import b-dead')).toBeInTheDocument();
    expect(screen.getByRole('tab', { name: t('batches.dead') })).toHaveAttribute('aria-selected', 'true');
    expect(history.get()).toContain('dead=1');
    expect(batchRequests(fetchMock).at(-1)!.url.searchParams.get('dead')).toBe('1');
  });

  it('opens on the dead tab from a ?dead=1 link', async () => {
    const fetchMock = stubFetch(() => listing([batch('b-dead')]));
    renderPage('/batches?dead=1', '/batches', Batches);

    await screen.findByText('import b-dead');
    expect(batchRequests(fetchMock)[0].url.searchParams.get('dead')).toBe('1');
  });

  it('filters by tag through ?tag= and keeps the input mounted while it loads', async () => {
    let resolveTagged: (v: unknown) => void = () => {};
    const fetchMock = stubFetch((url) =>
      url.searchParams.get('tag') ? new Promise((resolve) => (resolveTagged = resolve)) : listing([batch('b-live')]),
    );
    renderPage('/batches', '/batches', Batches);

    await screen.findByText('import b-live');
    const box = screen.getByPlaceholderText(t('batches.tag_placeholder'));
    box.focus();
    fireEvent.input(box, { target: { value: 'customer:1234' } });

    await waitFor(() => expect(batchRequests(fetchMock).some(({ url }) => url.searchParams.get('tag') === 'customer:1234')).toBe(true));
    expect(screen.getByPlaceholderText(t('batches.tag_placeholder'))).toBe(box);
    expect(document.activeElement).toBe(box);

    resolveTagged(listing([batch('b-tagged')]));
    expect(await screen.findByText('import b-tagged')).toBeInTheDocument();
  });
});

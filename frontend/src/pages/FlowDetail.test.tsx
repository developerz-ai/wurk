import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, waitFor } from '@solidjs/testing-library';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { MemoryRouter, Route, createMemoryHistory } from '@solidjs/router';
import FlowDetail, { layoutFlow } from './FlowDetail';
import { basePath } from '../basePath';

type Node = Parameters<typeof layoutFlow>[0][number];

function node(index: number, overrides: Partial<Node> = {}): Node {
  return {
    index,
    name: null,
    klass: `Job${index}`,
    queue: 'default',
    jid: `jid-${index}`,
    bid: `bid-${index}`,
    state: 'waiting',
    depends_on: [],
    dependents: [],
    remaining: 0,
    piped: false,
    error: null,
    ...overrides,
  };
}

// A, B → C. The graph every decision in slice 11 is argued over.
const DIAMOND: Node[] = [
  node(0, { klass: 'Alpha', state: 'succeeded', dependents: [2] }),
  node(1, { klass: 'Beta', state: 'succeeded', dependents: [2] }),
  node(2, { klass: 'Merge', name: 'merge', state: 'enqueued', depends_on: [0, 1], remaining: 0 }),
];

const FLOW = {
  fid: 'flow-abc',
  state: 'running',
  total: 3,
  pending: 1,
  succeeded: 2,
  depth: 2,
  width: 2,
  created_at: Date.now() / 1000 - 30,
  finished_at: null,
  failed_at: null,
  abandoned_at: null,
  dead_nodes: [],
  nodes: DIAMOND,
};

function mockFetch(flow: unknown, onPost?: (url: string) => void) {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (init?.method === 'POST') onPost?.(url);
    const body = url.includes('/api/meta') ? { read_only: false } : flow;
    return { ok: true, status: 200, json: async () => body } as Response;
  });
}

function renderFlow(flow: unknown = FLOW, onPost?: (url: string) => void) {
  vi.stubGlobal('fetch', mockFetch(flow, onPost));
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const history = createMemoryHistory();
  history.set({ value: '/flows/flow-abc', replace: true });
  return render(() => (
    <QueryClientProvider client={client}>
      <MemoryRouter history={history}>
        <Route path="/flows/:fid" component={FlowDetail} />
      </MemoryRouter>
    </QueryClientProvider>
  ));
}

describe('layoutFlow', () => {
  it('puts a node one column right of its deepest dependency', () => {
    const { placed } = layoutFlow(DIAMOND);
    const [a, b, c] = placed;

    expect(a.x).toBe(b.x);
    expect(c.x).toBeGreaterThan(a.x);
    // Siblings share a column and stack, in declaration order.
    expect(a.y).toBeLessThan(b.y);
  });

  // `depends_on:` accepts a name declared later in the block, so declaration
  // order is not topological order and a single index-order pass would put a
  // node to the left of something it waits for.
  it('places a forward-referenced dependency behind its dependent', () => {
    const nodes = [
      node(0, { klass: 'Merge', depends_on: [1, 2] }),
      node(1, { klass: 'Alpha', dependents: [0] }),
      node(2, { klass: 'Beta', dependents: [0] }),
    ];

    const { at } = layoutFlow(nodes);

    expect(at.get(0)!.x).toBeGreaterThan(at.get(1)!.x);
    expect(at.get(1)!.x).toBe(at.get(2)!.x);
  });

  it('grows a column per level of a chain', () => {
    const chain = [
      node(0, { dependents: [1] }),
      node(1, { depends_on: [0], dependents: [2] }),
      node(2, { depends_on: [1] }),
    ];

    const xs = layoutFlow(chain).placed.map((p) => p.x);

    expect(new Set(xs).size).toBe(3);
    expect(xs[0]).toBeLessThan(xs[1]);
    expect(xs[1]).toBeLessThan(xs[2]);
  });

  it('measures the canvas to the widest column and the tallest row stack', () => {
    const wide = layoutFlow(DIAMOND);
    const single = layoutFlow([node(0)]);

    expect(wide.width).toBeGreaterThan(single.width);
    expect(wide.height).toBeGreaterThan(single.height);
    expect(layoutFlow([]).width).toBe(0);
    expect(layoutFlow([]).height).toBe(0);
  });
});

describe('FlowDetail', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // Every node is drawn twice on purpose: once in the graph, once in the table
  // under it, which is the row that links out to the node's batch.
  it('renders the header and every node in both the graph and the table', async () => {
    renderFlow();

    expect(await screen.findByText('flow-abc')).toBeInTheDocument();
    expect(screen.getByRole('img', { name: 'Graph' })).toBeInTheDocument();
    expect(screen.getAllByText('Alpha')).toHaveLength(2);
    expect(screen.getAllByText('Beta')).toHaveLength(2);
    expect(screen.getAllByText('merge · #2')).toHaveLength(2);
    expect(screen.getByRole('link', { name: 'jid-2' })).toHaveAttribute('href', '/batches/bid-2');
  });

  it('badges each node with its own state', async () => {
    renderFlow();

    await screen.findByText('flow-abc');
    expect(screen.getAllByText('Succeeded').length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText('Enqueued')).toBeInTheDocument();
    expect(screen.getByText('Running')).toBeInTheDocument();
  });

  it('surfaces a broken link’s reason, which no job ran to report anywhere else', async () => {
    renderFlow({
      ...FLOW,
      state: 'failed',
      dead_nodes: [1],
      nodes: [
        node(0, { klass: 'Head', state: 'succeeded', dependents: [1] }),
        node(1, {
          klass: 'Tail',
          state: 'broken',
          depends_on: [0],
          piped: true,
          error: 'piped result was truncated at the stored-result cap',
        }),
      ],
    });

    expect(await screen.findByText(/piped result was truncated/)).toBeInTheDocument();
    expect(screen.getByText('Broken')).toBeInTheDocument();
    // The blocked-by field names the node the flow is failed because of.
    expect(screen.getAllByText('#1').length).toBeGreaterThanOrEqual(1);
  });

  it('says so rather than showing an empty table when the nodes were released', async () => {
    renderFlow({ ...FLOW, state: 'abandoned', abandoned_at: FLOW.created_at, nodes: [], pending: 3, succeeded: 0 });

    expect(await screen.findByText(/node records were released/)).toBeInTheDocument();
    expect(screen.queryByRole('img', { name: 'Graph' })).not.toBeInTheDocument();
  });

  // The Lua script claims on a live flow, so the button is offered exactly when
  // the call would do something.
  it('offers the kill switch while the flow can still move', async () => {
    renderFlow();

    expect(await screen.findByRole('button', { name: 'Abandon' })).toBeInTheDocument();
  });

  it('withholds the kill switch once the flow is terminal', async () => {
    renderFlow({ ...FLOW, state: 'succeeded', pending: 0, succeeded: 3, finished_at: FLOW.created_at });

    await screen.findByText('flow-abc');
    expect(screen.queryByRole('button', { name: 'Abandon' })).not.toBeInTheDocument();
  });

  it('posts the abandon call once the confirm is accepted', async () => {
    const posted: string[] = [];
    renderFlow(FLOW, (url) => posted.push(url));
    const button = await screen.findByRole('button', { name: 'Abandon' });
    vi.stubGlobal('confirm', vi.fn(() => true));

    button.click();

    await waitFor(() => expect(posted).toEqual([`${basePath()}/api/flows/flow-abc/abandon`]));
  });

  // Waited out rather than asserted synchronously: `mutate` reaches the network
  // a tick later, so an immediate `toEqual([])` would pass even with the guard
  // gone.
  it('does not reach the network when the confirm is refused', async () => {
    const posted: string[] = [];
    renderFlow(FLOW, (url) => posted.push(url));
    const button = await screen.findByRole('button', { name: 'Abandon' });
    vi.stubGlobal('confirm', vi.fn(() => false));

    button.click();
    await new Promise((resolve) => setTimeout(resolve, 25));

    expect(posted).toEqual([]);
  });
});

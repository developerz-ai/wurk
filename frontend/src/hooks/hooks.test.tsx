import { describe, it, expect, afterEach, vi } from 'vitest';
import { renderHook, waitFor } from '@solidjs/testing-library';
import { MemoryRouter, Route, createMemoryHistory, useLocation } from '@solidjs/router';
import type { JSX } from 'solid-js';
import { useSort, type Accessors } from './useSort';
import { useSelection } from './useSelection';
import { useCountUp } from './useCountUp';
import { usePageParam } from './usePageParam';

interface Row {
  name: string;
  n: number;
  opt: number | null;
}

const DATA: Row[] = [
  { name: 'banana', n: 10, opt: 5 },
  { name: 'apple', n: 2, opt: null },
  { name: 'cherry', n: 1, opt: 3 },
];

const ACC: Accessors<Row> = {
  name: (r) => r.name,
  n: (r) => r.n,
  opt: (r) => r.opt,
};

describe('useSort', () => {
  it('starts unsorted, then toggles asc → desc on the active column', () => {
    const { result } = renderHook(() => useSort(() => DATA, ACC));
    // No key selected: rows pass through in source order.
    expect(result.sorted().map((r) => r.name)).toEqual(['banana', 'apple', 'cherry']);

    result.toggle('n');
    expect(result.sort()).toEqual({ key: 'n', dir: 'asc' });
    expect(result.sorted().map((r) => r.n)).toEqual([1, 2, 10]); // numeric, not lexicographic

    result.toggle('n');
    expect(result.sort()).toEqual({ key: 'n', dir: 'desc' });
    expect(result.sorted().map((r) => r.n)).toEqual([10, 2, 1]);
  });

  it('sorts strings and keeps nulls last regardless of direction', () => {
    const { result } = renderHook(() => useSort(() => DATA, ACC));

    result.toggle('name');
    expect(result.sorted().map((r) => r.name)).toEqual(['apple', 'banana', 'cherry']);

    result.toggle('opt'); // asc: 3, 5, null
    expect(result.sorted().map((r) => r.opt)).toEqual([3, 5, null]);

    result.toggle('opt'); // desc: 5, 3, null — null stays last
    expect(result.sorted().map((r) => r.opt)).toEqual([5, 3, null]);
  });
});

describe('useSelection', () => {
  it('toggles a single key on and off', () => {
    const { result } = renderHook(() => useSelection());
    expect(result.count()).toBe(0);

    result.toggle('a');
    expect(result.count()).toBe(1);
    expect(result.selected().has('a')).toBe(true);

    result.toggle('a');
    expect(result.count()).toBe(0);
  });

  it('toggleAll selects the page, then clears when everything is already on', () => {
    const { result } = renderHook(() => useSelection());
    const keys = ['a', 'b', 'c'];

    result.toggleAll(keys);
    expect(result.count()).toBe(3);

    result.toggleAll(keys); // all on → clear
    expect(result.count()).toBe(0);

    // Partial selection is not "all on", so toggleAll fills the rest in.
    result.toggle('a');
    result.toggleAll(keys);
    expect(result.count()).toBe(3);

    result.clear();
    expect(result.count()).toBe(0);
  });
});

describe('useCountUp', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('snaps straight to the target under prefers-reduced-motion', async () => {
    vi.stubGlobal(
      'matchMedia',
      vi.fn().mockReturnValue({
        matches: true,
        addEventListener: () => {},
        removeEventListener: () => {},
      }),
    );
    const { result } = renderHook(() => useCountUp(() => 42));
    await waitFor(() => expect(result()).toBe(42));
  });

  it('snaps (never animates) when the target is non-finite', async () => {
    // No matchMedia stub → prefers-reduced-motion is false, so the finite guard
    // is what short-circuits the rAF tween.
    const { result } = renderHook(() => useCountUp(() => Number.POSITIVE_INFINITY));
    await waitFor(() => expect(result()).toBe(Number.POSITIVE_INFINITY));
  });
});

function routerWrapper(path: string) {
  return (props: { children: JSX.Element }) => {
    const history = createMemoryHistory();
    history.set({ value: path, replace: true });
    // Router primitives (useSearchParams/useLocation) require a matched Route,
    // not just the Router context — mount the hook harness inside a wildcard one.
    return (
      <MemoryRouter history={history}>
        <Route path="*" component={() => <>{props.children}</>} />
      </MemoryRouter>
    );
  };
}

describe('usePageParam', () => {
  it('reads ?page from the URL', () => {
    const { result } = renderHook(() => usePageParam(), { wrapper: routerWrapper('/dead?page=3') });
    expect(result[0]()).toBe(3);
  });

  it('clamps invalid or out-of-range pages to 1', () => {
    const nan = renderHook(() => usePageParam(), { wrapper: routerWrapper('/dead?page=abc') });
    expect(nan.result[0]()).toBe(1);

    const neg = renderHook(() => usePageParam(), { wrapper: routerWrapper('/dead?page=-2') });
    expect(neg.result[0]()).toBe(1);
  });

  it('writes higher pages to the URL and drops page=1 to keep it clean', async () => {
    const { result } = renderHook(
      () => {
        const [page, setPage] = usePageParam();
        const loc = useLocation();
        return { page, setPage, loc };
      },
      { wrapper: routerWrapper('/dead?page=3') },
    );

    result.setPage(5);
    await waitFor(() => expect(result.loc.search).toContain('page=5'));

    result.setPage(1);
    await waitFor(() => expect(result.loc.search).not.toContain('page'));
  });
});

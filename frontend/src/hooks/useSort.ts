import { createMemo, createSignal, type Accessor } from 'solid-js';

export type SortDir = 'asc' | 'desc';
export interface SortState {
  key: string | null;
  dir: SortDir;
}

type SortValue = string | number | null | undefined;
export type Accessors<T> = Record<string, (row: T) => SortValue>;

// Client-side column sorting for a table's currently-loaded rows.
//
// `rows` is an accessor (e.g. `() => query.data ?? []`) so the sort tracks the
// live data. Define `accessors` as a module-level constant (one entry per
// sortable column). For server-paginated tables this sorts the visible page
// only — which matches how the dashboard's job lists load.
export function useSort<T>(
  rows: Accessor<T[]>,
  accessors: Accessors<T>,
  initial?: SortState,
): { sorted: Accessor<T[]>; sort: Accessor<SortState>; toggle: (key: string) => void } {
  const [sort, setSort] = createSignal<SortState>(initial ?? { key: null, dir: 'asc' });

  const sorted = createMemo(() => {
    const s = sort();
    const acc = s.key ? accessors[s.key] : undefined;
    const data = rows();
    if (!acc) return data;
    const copy = [...data];
    copy.sort((a, b) => {
      const va = acc(a);
      const vb = acc(b);
      // Nulls always sort last regardless of direction.
      if (va == null && vb == null) return 0;
      if (va == null) return 1;
      if (vb == null) return -1;
      const cmp =
        typeof va === 'number' && typeof vb === 'number'
          ? va - vb
          : String(va).localeCompare(String(vb), undefined, { numeric: true, sensitivity: 'base' });
      return s.dir === 'asc' ? cmp : -cmp;
    });
    return copy;
  });

  // First click on a column sorts ascending; clicking the active column flips direction.
  const toggle = (key: string) =>
    setSort((s) => (s.key === key ? { key, dir: s.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: 'asc' }));

  return { sorted, sort, toggle };
}

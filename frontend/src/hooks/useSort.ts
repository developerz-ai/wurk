import { useMemo, useState } from 'react';

export type SortDir = 'asc' | 'desc';
export interface SortState {
  key: string | null;
  dir: SortDir;
}

type SortValue = string | number | null | undefined;
export type Accessors<T> = Record<string, (row: T) => SortValue>;

// Client-side column sorting for a table's currently-loaded rows.
//
// Define `accessors` as a module-level constant (one entry per sortable column)
// so its identity is stable across renders. For server-paginated tables this
// sorts the visible page only — which matches how the dashboard's job lists load.
export function useSort<T>(rows: T[], accessors: Accessors<T>, initial?: SortState) {
  const [sort, setSort] = useState<SortState>(initial ?? { key: null, dir: 'asc' });

  const sorted = useMemo(() => {
    const acc = sort.key ? accessors[sort.key] : undefined;
    if (!acc) return rows;
    const copy = [...rows];
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
      return sort.dir === 'asc' ? cmp : -cmp;
    });
    return copy;
  }, [rows, sort, accessors]);

  // First click on a column sorts ascending; clicking the active column flips direction.
  const toggle = (key: string) =>
    setSort((s) => (s.key === key ? { key, dir: s.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: 'asc' }));

  return { sorted, sort, toggle };
}

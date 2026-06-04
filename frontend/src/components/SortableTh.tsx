import { type CSSProperties, type ReactNode } from 'react';
import type { SortState } from '../hooks/useSort';

interface SortableThProps {
  label: ReactNode;
  /** Must match a key in the page's `useSort` accessors map. */
  sortKey: string;
  sort: SortState;
  onSort: (key: string) => void;
  style?: CSSProperties;
}

// A sortable table header. The clickable target is a real <button> so it is
// keyboard-focusable and operable (Enter/Space); the <th> keeps `aria-sort`
// for assistive tech. Shows a neutral sort glyph until active, then an up/down
// arrow for the current direction.
export function SortableTh({ label, sortKey, sort, onSort, style }: SortableThProps) {
  const active = sort.key === sortKey;
  const icon = !active ? 'fa-sort' : sort.dir === 'asc' ? 'fa-arrow-up-short-wide' : 'fa-arrow-down-wide-short';

  return (
    <th
      className="th-sortable"
      aria-sort={active ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none'}
      style={style}
    >
      <button type="button" className="th-sortable__btn" onClick={() => onSort(sortKey)}>
        {label}
        <i className={`fa-solid ${icon} th-sortable__icon${active ? ' is-active' : ''}`} aria-hidden="true" />
      </button>
    </th>
  );
}

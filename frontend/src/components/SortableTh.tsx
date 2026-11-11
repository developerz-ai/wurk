import { type JSX } from 'solid-js';
import type { SortState } from '../hooks/useSort';
import type { IconName } from '../icons';
import Icon from './Icon';

interface SortableThProps {
  label: JSX.Element;
  /** Must match a key in the page's `useSort` accessors map. */
  sortKey: string;
  // The current sort value (pages pass `sort={sort()}`); Solid's fine-grained
  // bindings re-read it reactively at the call site, so a plain value is enough.
  sort: SortState;
  onSort: (key: string) => void;
  style?: JSX.CSSProperties;
}

// A sortable table header. The clickable target is a real <button> so it is
// keyboard-focusable and operable (Enter/Space); the <th> keeps `aria-sort`
// for assistive tech. Shows a neutral sort glyph until active, then an up/down
// arrow for the current direction.
export function SortableTh(props: SortableThProps) {
  const active = () => props.sort.key === props.sortKey;
  const icon = (): IconName =>
    !active() ? 'sort' : props.sort.dir === 'asc' ? 'arrow-up-short-wide' : 'arrow-down-wide-short';

  return (
    <th
      class="th-sortable"
      aria-sort={active() ? (props.sort.dir === 'asc' ? 'ascending' : 'descending') : 'none'}
      style={props.style}
    >
      <button type="button" class="th-sortable__btn" onClick={() => props.onSort(props.sortKey)}>
        {props.label}
        <Icon name={icon()} class={`th-sortable__icon${active() ? ' is-active' : ''}`} />
      </button>
    </th>
  );
}

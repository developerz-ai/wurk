import { createSignal, type Accessor } from 'solid-js';

// Row-selection state for the bulk-action tables (retries/scheduled/dead).
// Keyed by the entry's composite key (see entryKey) so a selection survives
// re-sorting; `toggleAll` works against the currently visible page's keys.
// `selected` and `count` are signal accessors — call them (`count()`) to read.
export function useSelection(): {
  selected: Accessor<Set<string>>;
  toggle: (key: string) => void;
  toggleAll: (keys: string[]) => void;
  clear: () => void;
  count: Accessor<number>;
} {
  const [selected, setSelected] = createSignal<Set<string>>(new Set());

  const toggle = (key: string) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });

  const toggleAll = (keys: string[]) =>
    setSelected((prev) => {
      const allOn = keys.length > 0 && keys.every((k) => prev.has(k));
      return allOn ? new Set<string>() : new Set(keys);
    });

  const clear = () => setSelected(new Set<string>());
  const count = () => selected().size;

  return { selected, toggle, toggleAll, clear, count };
}

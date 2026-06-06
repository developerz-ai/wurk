import { useCallback, useMemo, useState } from 'react';

// Row-selection state for the bulk-action tables (retries/scheduled/dead).
// Keyed by the entry's composite key (see entryKey) so a selection survives
// re-sorting; `toggleAll` works against the currently visible page's keys.
export function useSelection() {
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const toggle = useCallback((key: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }, []);

  const toggleAll = useCallback((keys: string[]) => {
    setSelected((prev) => {
      const allOn = keys.length > 0 && keys.every((k) => prev.has(k));
      return allOn ? new Set() : new Set(keys);
    });
  }, []);

  const clear = useCallback(() => setSelected(new Set()), []);

  return useMemo(
    () => ({ selected, toggle, toggleAll, clear, count: selected.size }),
    [selected, toggle, toggleAll, clear]
  );
}

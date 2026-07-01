import { useSearchParams } from '@solidjs/router';
import type { Accessor } from 'solid-js';

// Pagination state that lives in the URL (`?page=N`) instead of component state,
// so a page is shareable, bookmarkable, and survives back/forward navigation.
// Page 1 is the canonical default and is kept out of the URL to stay clean.
// Returns `[page, setPage]` where `page` is a reactive accessor — read `page()`.
export function usePageParam(): [Accessor<number>, (p: number) => void] {
  const [params, setParams] = useSearchParams();

  const page = () => {
    const raw = parseInt((params.page as string) ?? '1', 10);
    return Number.isFinite(raw) && raw > 0 ? raw : 1;
  };

  // Setting a param to undefined removes it from the URL; the router merges the
  // rest, so page 1 stays clean while other query params are preserved.
  const setPage = (p: number) => setParams({ page: p <= 1 ? undefined : String(p) });

  return [page, setPage];
}

import { useSearchParams } from 'react-router-dom';

// Pagination state that lives in the URL (`?page=N`) instead of component state,
// so a page is shareable, bookmarkable, and survives back/forward navigation.
// Page 1 is the canonical default and is kept out of the URL to stay clean.
export function usePageParam(): [number, (p: number) => void] {
  const [params, setParams] = useSearchParams();
  const raw = parseInt(params.get('page') ?? '1', 10);
  const page = Number.isFinite(raw) && raw > 0 ? raw : 1;

  const setPage = (p: number) => {
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        if (p <= 1) next.delete('page');
        else next.set('page', String(p));
        return next;
      },
      { replace: false },
    );
  };

  return [page, setPage];
}

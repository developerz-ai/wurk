import { createEffect } from 'solid-js';

// A paginated `?page=N` can go stale — the last item on the final page gets
// retried/deleted, or a filter narrows the result set — leaving the fetched
// page empty while the URL still points past the end. Bounce back to page 1
// rather than showing a permanently blank table the user can't "Prev" out of
// without noticing why. `ready` gates on the query actually having data, so a
// mid-load empty array doesn't cause a spurious bounce before the real page
// of results arrives.
export function useResetPageOnEmpty(
  page: () => number,
  setPage: (p: number) => void,
  ready: () => boolean,
  empty: () => boolean,
) {
  createEffect(() => {
    if (page() > 1 && ready() && empty()) setPage(1);
  });
}

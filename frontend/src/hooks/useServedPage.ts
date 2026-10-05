import { createEffect } from 'solid-js';

// Listing endpoints clamp `?page=` to their `max_page` and echo the page they
// actually served (0-indexed). Follow it so the URL, the "Page X" label and any
// bulk selection all name the rows on screen. Only ever downward —
// useResetPageOnEmpty also moves the page, and two effects chasing each other
// would loop. `stale` skips placeholder data still carrying the previous key's
// page.
export function useServedPage(
  page: () => number,
  setPage: (p: number) => void,
  data: () => { page?: number } | undefined,
  stale: () => boolean = () => false,
) {
  createEffect(() => {
    const served = data()?.page;
    if (typeof served !== 'number' || stale()) return;
    if (served + 1 < page()) setPage(served + 1);
  });
}

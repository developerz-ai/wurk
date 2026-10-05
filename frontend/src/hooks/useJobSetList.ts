import { useQuery, keepPreviousData } from '@tanstack/solid-query';
import { createSignal } from 'solid-js';
import { basePath } from '../basePath';
import { getJSON } from '../http';
import { formatNumber } from '../utils';
import { maxPageOf } from '../components/Pagination';
import { usePageParam } from './usePageParam';
import { useResetPageOnEmpty } from './useResetPageOnEmpty';
import { useServedPage } from './useServedPage';
import type { JobSetName } from './useJobSetActions';

// GET /api/<set> (ApiController#render_sorted_set). `page` is the page the
// server actually served and `max_page` the deepest it will serve, both
// 0-indexed like the request's `?page=`. Under `?substr=` the server adds
// `filtered_total`, a lower bound when `filtered_total_exact` is false (the
// filter scan hit its budget). `total` is always the whole set. Every optional
// field is read defensively so an older server degrades to the unfiltered
// total.
export interface JobSetResponse<E> {
  total: number;
  page: number;
  count: number;
  entries: E[];
  max_page?: number;
  filtered_total?: number;
  filtered_total_exact?: boolean;
}

export const JOB_SET_PAGE_SIZE = 25;

// Query + paging + filter state shared by the Retries / Scheduled / Dead
// tables.
export function useJobSetList<E>(set: JobSetName, initialFilter = '') {
  const [page, setPage] = usePageParam();
  const [filter, setFilter] = createSignal(initialFilter);

  // Filter narrows the server-side substr scan (klass/jid), so a new term can
  // easily leave the current page past the end of the filtered set — reset to
  // page 1 whenever it changes.
  const onFilterChange = (v: string) => {
    setFilter(v);
    setPage(1);
  };

  // keepPreviousData: a new page/filter key would otherwise drop the query
  // back to pending and blank the table on every keystroke.
  const query = useQuery<JobSetResponse<E>>(() => ({
    queryKey: [set, page(), filter()],
    queryFn: () =>
      getJSON<JobSetResponse<E>>(
        `${basePath()}/api/${set}?page=${page() - 1}&count=${JOB_SET_PAGE_SIZE}&substr=${encodeURIComponent(filter())}`,
      ),
    placeholderData: keepPreviousData,
  }));

  useResetPageOnEmpty(page, setPage, () => !!query.data && !query.isPlaceholderData, () => (query.data?.entries.length ?? 0) === 0);

  useServedPage(page, setPage, () => query.data, () => query.isPlaceholderData);

  const filtered = () => filter() !== '';
  const inexact = () => query.data?.filtered_total_exact === false;

  // Display label for the rows matching the active filter ("1,204" or, past
  // the server's scan budget, "20,000+"); undefined when unfiltered or the
  // server doesn't report it.
  const matching = (): string | undefined => {
    const n = query.data?.filtered_total;
    if (!filtered() || typeof n !== 'number') return undefined;
    return `${formatNumber(n)}${inexact() ? '+' : ''}`;
  };

  // Total the pager divides into pages. Under a filter without
  // `filtered_total`, a short page proves it is the last one; otherwise the
  // unfiltered total is the only (upper) bound available.
  const pagerTotal = (): number => {
    const data = query.data;
    if (!data) return 0;
    if (!filtered()) return data.total;
    const full = data.entries.length >= JOB_SET_PAGE_SIZE;
    if (typeof data.filtered_total === 'number') {
      // A lower bound must still leave "Next" open while pages come back full.
      return inexact() && full ? Math.max(data.filtered_total, page() * JOB_SET_PAGE_SIZE + 1) : data.filtered_total;
    }
    if (!full) return (page() - 1) * JOB_SET_PAGE_SIZE + data.entries.length;
    return data.total;
  };

  const maxPage = () => maxPageOf(query.data);

  return { page, setPage, filter, onFilterChange, query, filtered, matching, pagerTotal, maxPage };
}

// `/retries/:key` style deep links (Sidekiq's "<score>-<jid>", or Wurk's own
// "<score>|<jid>") open the list filtered to that jid.
export function jidFromKey(key: string | undefined): string {
  if (!key) return '';
  return decodeURIComponent(key).split(/[|-]/).pop() ?? '';
}

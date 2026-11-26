import type { QueryClient, QueryKey } from '@tanstack/solid-query';
import { basePath } from './basePath';
import { getJSON } from './http';

// The first query each list page runs, shared by the page and by the nav's
// hover prefetch so both hit one cache entry: hovering "Retries" warms the
// exact key the page will read, and the page then renders rows, not a skeleton.
interface RouteQuery {
  queryKey: QueryKey;
  queryFn: () => Promise<unknown>;
}

export const JOB_SET_PAGE_SIZE = 25;

export function jobSetQuery(set: 'retries' | 'scheduled' | 'dead', page: number, filter: string): RouteQuery {
  return {
    queryKey: [set, page, filter],
    queryFn: () =>
      getJSON(`${basePath()}/api/${set}?page=${page - 1}&count=${JOB_SET_PAGE_SIZE}&substr=${encodeURIComponent(filter)}`),
  };
}

export const processesQuery = (): RouteQuery => ({ queryKey: ['processes'], queryFn: () => getJSON(`${basePath()}/api/processes`) });
export const queuesQuery = (): RouteQuery => ({ queryKey: ['queues'], queryFn: () => getJSON(`${basePath()}/api/queues`) });

const BY_PATH: Record<string, () => RouteQuery> = {
  '/retries': () => jobSetQuery('retries', 1, ''),
  '/scheduled': () => jobSetQuery('scheduled', 1, ''),
  '/dead': () => jobSetQuery('dead', 1, ''),
  '/busy': processesQuery,
  '/queues': queuesQuery,
};

// No-op for a path with no entry, and while the cached copy is fresh.
export function prefetchRoute(client: QueryClient, path: string) {
  const q = BY_PATH[path];
  if (q) void client.prefetchQuery({ ...q(), staleTime: 5000 });
}

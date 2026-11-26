import { batch, createComputed, createMemo, createSignal, on, onCleanup } from 'solid-js';
import { createStore } from 'solid-js/store';
import {
  QueryObserver,
  useQueryClient,
  type DefaultError,
  type QueryClient,
  type QueryKey,
  type QueryObserverResult,
  type UseQueryOptions,
  type UseQueryResult,
} from '@tanstack/solid-query';

// useQuery without Suspense. @tanstack/solid-query backs `data` with a
// createResource, so reading `data` before the first response suspends the
// nearest <Suspense>: the route boundary in App.tsx. That swapped the whole
// page for its skeleton (and detached any open <dialog>, which came back
// non-modal) whenever a modal read a query that had not loaded yet, and it held
// navigation on the old page until the new page's data arrived. Every page
// already draws its own skeleton from `isPending`, so here `data` is a plain
// signal: undefined until the first response, never a suspension.
//
// Same observer, cache and options as solid-query's hook.
export function useQuery<TQueryFnData = unknown, TError = DefaultError, TData = TQueryFnData, TQueryKey extends QueryKey = QueryKey>(
  options: UseQueryOptions<TQueryFnData, TError, TData, TQueryKey>,
): UseQueryResult<TData, TError> {
  const client = useQueryClient();
  const defaulted = createMemo(() => {
    const o = client.defaultQueryOptions(options());
    o._optimisticResults = 'optimistic';
    return o;
  });
  const observer = new QueryObserver<TQueryFnData, TError, TData, TQueryFnData, TQueryKey>(client, defaulted());
  const initial = observer.getOptimisticResult(defaulted());
  const [state, setState] = createStore<QueryObserverResult<TData, TError>>({ ...initial, data: undefined } as QueryObserverResult<TData, TError>);
  // `data` lives in a signal holding the query cache's own object, not in the
  // store: a store merges a new object into the one it holds, which would
  // write into the cache's previous data (the data a rollback snapshot in
  // optimistic.ts keeps). The cache never edits data in place and shares
  // structure, so a row that did not change is the same object on the next
  // poll and a <For> keeps its DOM.
  const [data, setData] = createSignal<TData | undefined>(initial.data);

  const apply = (result: QueryObserverResult<TData, TError>) => {
    const { data: next, ...rest } = result;
    batch(() => {
      setState(rest as Partial<QueryObserverResult<TData, TError>>);
      setData(() => next);
    });
  };

  const unsubscribe = observer.subscribe(apply);
  onCleanup(unsubscribe);

  createComputed(
    on(
      defaulted,
      (o) => {
        observer.setOptions(o);
        apply(observer.getOptimisticResult(o));
      },
      { defer: true },
    ),
  );

  return new Proxy(state, {
    get: (target, prop) => (prop === 'data' ? data() : Reflect.get(target, prop)),
  }) as UseQueryResult<TData, TError>;
}

// Warm the cache for a query a click is about to need (a row's detail on
// hover). A no-op while fresh data is cached.
export function prefetch(client: QueryClient, queryKey: QueryKey, queryFn: () => Promise<unknown>, staleTime = 30_000) {
  void client.prefetchQuery({ queryKey, queryFn, staleTime });
}

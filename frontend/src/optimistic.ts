import type { QueryClient, QueryKey } from '@tanstack/solid-query';

// One cache edit an action makes before its request returns: every cached
// query under `queryKey` (a prefix: all pages and filters of a list) gets
// `update` applied to its data.
export interface Patch {
  queryKey: QueryKey;
  update: (old: any) => any; // eslint-disable-line @typescript-eslint/no-explicit-any
}

export interface OptimisticContext {
  snapshot: Array<[QueryKey, unknown]>;
}

// Mutation lifecycle for an optimistic action. onMutate cancels the in-flight
// polls of the patched queries (a response sent before the action would
// otherwise land after it and put the row back), keeps their data, then
// applies the patches, so the row leaves or the badge flips on click.
// `rollback` restores the kept data when the request fails; the caller still
// raises its toast. onSettled refetches `refresh`, so the next server state
// replaces the guess, success or failure.
export function optimistic<V>(qc: QueryClient, patches: (vars: V) => Patch[], refresh: QueryKey[]) {
  return {
    onMutate: async (vars: V): Promise<OptimisticContext> => {
      const ps = patches(vars);
      await Promise.all(ps.map((p) => qc.cancelQueries({ queryKey: p.queryKey })));
      const snapshot = ps.flatMap((p) => qc.getQueriesData({ queryKey: p.queryKey }));
      for (const p of ps) {
        qc.setQueriesData({ queryKey: p.queryKey }, (old: unknown) => (old === undefined ? old : p.update(old)));
      }
      return { snapshot };
    },
    rollback: (ctx: OptimisticContext | undefined) => {
      for (const [key, data] of ctx?.snapshot ?? []) qc.setQueryData(key, data);
    },
    onSettled: () => {
      for (const key of refresh) void qc.invalidateQueries({ queryKey: key });
    },
  };
}

// `counts` adds to the matching numeric fields of /api/stats (the nav badges
// and dashboard tiles), never below zero.
export function statsPatch(counts: Record<string, number>): Patch {
  return {
    queryKey: ['stats'],
    update: (old: Record<string, unknown>) => {
      const next = { ...old };
      for (const [field, delta] of Object.entries(counts)) {
        if (typeof next[field] === 'number') next[field] = Math.max(0, (next[field] as number) + delta);
      }
      return next;
    },
  };
}

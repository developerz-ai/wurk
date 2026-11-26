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
  release: () => void;
}

// Mutation lifecycle for an optimistic action. onMutate cancels the in-flight
// polls of the patched queries (a response sent before the action would
// otherwise land after it and put the row back), keeps their data, then
// applies the patches, so the row leaves or the badge flips on click.
// `rollback` restores the kept data when the request fails; the caller still
// raises its toast. onSettled refetches `refresh`, so the next server state
// replaces the guess, success or failure.
//
// Until the request settles, a poll that answers in the meantime (sent after
// the click, read before the server applied it) gets the patches applied to
// its data too, so the row does not come back and leave again; two actions in
// flight each keep their own edit on top.
export function optimistic<V>(qc: QueryClient, patches: (vars: V) => Patch[], refresh: QueryKey[]) {
  return {
    onMutate: async (vars: V): Promise<OptimisticContext> => {
      const ps = patches(vars);
      await Promise.all(ps.map((p) => qc.cancelQueries({ queryKey: p.queryKey })));
      const snapshot = ps.flatMap((p) => qc.getQueriesData({ queryKey: p.queryKey }));
      for (const p of ps) {
        qc.setQueriesData({ queryKey: p.queryKey }, (old: unknown) => (old === undefined ? old : p.update(old)));
      }
      const release = qc.getQueryCache().subscribe((event) => {
        if (event.type !== 'updated' || event.action.type !== 'success' || event.action.manual) return;
        const p = ps.find((patch) => startsWith(event.query.queryKey, patch.queryKey));
        const data = event.query.state.data;
        if (p && data !== undefined) qc.setQueryData(event.query.queryKey, p.update(data));
      });
      return { snapshot, release };
    },
    rollback: (ctx: OptimisticContext | undefined) => {
      ctx?.release();
      for (const [key, data] of ctx?.snapshot ?? []) qc.setQueryData(key, data);
    },
    onSettled: (_data: unknown, _error: unknown, _vars: unknown, ctx: OptimisticContext | undefined) => {
      ctx?.release();
      for (const key of refresh) void qc.invalidateQueries({ queryKey: key });
    },
  };
}

function startsWith(key: QueryKey, prefix: QueryKey): boolean {
  return prefix.every((part, i) => JSON.stringify(part) === JSON.stringify(key[i]));
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

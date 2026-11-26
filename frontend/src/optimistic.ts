import { createSignal } from 'solid-js';
import type { QueryClient, QueryKey } from '@tanstack/solid-query';

// One edit an action makes to what the page shows before its request returns,
// to every cached query under `queryKey` (a prefix: all pages and filters of a
// list).
//
// By default the edit is a view over the cached data: useQuery (query.ts)
// applies it to whatever the cache holds, including a poll that answers
// while the action is in flight, so a removed row never comes back on screen,
// not even for a frame. Such an edit must be idempotent against data that
// already reflects the action (drop rows by key, set a flag), since the poll
// after the server applied it passes through it too.
//
// A `oneShot` edit is written into the cache once instead, for counters that
// cannot be stated idempotently (/api/stats): a later poll replaces it with
// the server's count, which is right either way.
export interface Patch {
  queryKey: QueryKey;
  update: (old: any) => any; // eslint-disable-line @typescript-eslint/no-explicit-any
  oneShot?: boolean;
}

export interface OptimisticContext {
  id: number;
  snapshot: Array<[QueryKey, unknown]>;
  written: Array<[QueryKey, unknown]>;
  startedAt: number;
  patches: Patch[];
}

const active = new Map<number, Patch[]>();
const [version, setVersion] = createSignal(0);
let nextId = 0;

function setActive(id: number, patches: Patch[] | null) {
  if (patches) active.set(id, patches);
  else active.delete(id);
  setVersion((v) => v + 1);
}

function startsWith(key: QueryKey, prefix: QueryKey): boolean {
  return prefix.every((part, i) => JSON.stringify(part) === JSON.stringify(key[i]));
}

// The in-flight view edits for `queryKey`, applied in the order the actions
// were taken. Read reactively: useQuery re-selects when an action starts or
// ends.
export function applyPending<T>(queryKey: QueryKey, data: T): T {
  version();
  let out = data;
  for (const patches of active.values()) {
    for (const p of patches) {
      if (!p.oneShot && out !== undefined && startsWith(queryKey, p.queryKey)) out = p.update(out);
    }
  }
  return out;
}

// Tests: drop every in-flight edit, as a page reload would.
export function resetOptimistic() {
  active.clear();
  setVersion((v) => v + 1);
}

export function pendingVersion() {
  return version();
}

// Mutation lifecycle for an optimistic action. onMutate cancels in-flight
// polls of the edited queries, writes the one-shot edits (keeping what they
// replace) and turns the view edits on. On failure `rollback` turns them off
// and restores the one-shot data where the cache still holds what the edit
// wrote (a newer poll stays); the caller still raises its toast. On settle the
// edited queries refetch, and the view edits stay on until every edited
// query has a successful fetch from after the action: a failed refetch
// would otherwise hand back the stale list with the row in it.
export function optimistic<V>(qc: QueryClient, patches: (vars: V) => Patch[], refresh: QueryKey[]) {
  return {
    onMutate: async (vars: V): Promise<OptimisticContext> => {
      const ps = patches(vars);
      await Promise.all(ps.map((p) => qc.cancelQueries({ queryKey: p.queryKey })));
      const oneShot = ps.filter((p) => p.oneShot);
      const snapshot = oneShot.flatMap((p) => qc.getQueriesData({ queryKey: p.queryKey }));
      const written: Array<[QueryKey, unknown]> = [];
      for (const p of oneShot) {
        for (const [key, old] of qc.getQueriesData({ queryKey: p.queryKey })) {
          if (old !== undefined) written.push([key, qc.setQueryData(key, p.update(old))]);
        }
      }
      const id = (nextId += 1);
      setActive(id, ps);
      return { id, snapshot, written, startedAt: Date.now(), patches: ps };
    },
    rollback: (ctx: OptimisticContext | undefined) => {
      if (!ctx) return;
      setActive(ctx.id, null);
      for (const [key, data] of ctx.snapshot) {
        const ours = ctx.written.find(([k]) => JSON.stringify(k) === JSON.stringify(key))?.[1];
        if (qc.getQueryData(key) === ours) qc.setQueryData(key, data);
      }
    },
    onSettled: async (_data: unknown, error: unknown, _vars: unknown, ctx: OptimisticContext | undefined) => {
      await Promise.all(refresh.map((key) => qc.invalidateQueries({ queryKey: key }))).catch(() => undefined);
      if (!ctx || error) {
        if (ctx) setActive(ctx.id, null);
        return;
      }
      const stale = () =>
        ctx.patches.some((p) =>
          qc.getQueryCache().findAll({ queryKey: p.queryKey }).some((q) => q.state.dataUpdatedAt < ctx.startedAt),
        );
      if (!stale()) return setActive(ctx.id, null);
      const release = qc.getQueryCache().subscribe(() => {
        if (stale()) return;
        release();
        setActive(ctx.id, null);
      });
    },
  };
}

// `counts` adds to the matching numeric fields of /api/stats (the nav badges
// and dashboard tiles), never below zero. One-shot: a count cannot tell
// whether the server already applied the action.
export function statsPatch(counts: Record<string, number>): Patch {
  return {
    queryKey: ['stats'],
    oneShot: true,
    update: (old: Record<string, unknown>) => {
      const next = { ...old };
      for (const [field, delta] of Object.entries(counts)) {
        if (typeof next[field] === 'number') next[field] = Math.max(0, (next[field] as number) + delta);
      }
      return next;
    },
  };
}

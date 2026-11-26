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
  // Each one-shot write's query and its dataUpdateCount right after it.
  written: Array<[QueryKey, number]>;
}

interface Entry {
  patches: Patch[];
  // Queries (by hash) that have had a successful fetch started after the
  // request completed: the server's own state, which the edit no longer
  // touches.
  fresh: Set<string>;
}

const active = new Map<number, Entry>();
const [version, setVersion] = createSignal(0);
let nextId = 0;
const bump = () => setVersion((v) => v + 1);

const hash = (key: QueryKey) => JSON.stringify(key);

function startsWith(key: QueryKey, prefix: QueryKey): boolean {
  return prefix.every((part, i) => JSON.stringify(part) === JSON.stringify(key[i]));
}

// The in-flight view edits for `queryKey`, applied in the order the actions
// were taken. Read reactively: useQuery re-selects when an action starts or
// ends, or when one of its queries gets a fetch of its own.
export function applyPending<T>(queryKey: QueryKey, data: T): T {
  version();
  const h = hash(queryKey);
  let out = data;
  for (const entry of active.values()) {
    if (entry.fresh.has(h)) continue;
    for (const p of entry.patches) {
      if (!p.oneShot && out !== undefined && startsWith(queryKey, p.queryKey)) out = p.update(out);
    }
  }
  return out;
}

// Tests: drop every in-flight edit, as a page reload would.
export function resetOptimistic() {
  active.clear();
  bump();
}

export function pendingVersion() {
  return version();
}

// Mutation lifecycle for an optimistic action. onMutate cancels in-flight
// polls of the edited queries, writes the one-shot edits (keeping what they
// replace) and turns the view edits on. On failure `rollback` turns them off
// and restores each one-shot write no later fetch has replaced (a newer poll
// stays); the caller still raises its toast. On success the view edit stays
// on, per query, until that query has a successful fetch started after the
// request completed: a poll read before the server applied the action, or a
// failed refetch, never brings the row back, and a query that is not on
// screen keeps the edit until it is fetched again.
export function optimistic<V>(qc: QueryClient, patches: (vars: V) => Patch[], refresh: QueryKey[]) {
  const cache = qc.getQueryCache();
  return {
    onMutate: async (vars: V): Promise<OptimisticContext> => {
      const ps = patches(vars);
      await Promise.all(ps.map((p) => qc.cancelQueries({ queryKey: p.queryKey })));
      const oneShot = ps.filter((p) => p.oneShot);
      const snapshot = oneShot.flatMap((p) => qc.getQueriesData({ queryKey: p.queryKey }));
      const written: Array<[QueryKey, number]> = [];
      for (const p of oneShot) {
        for (const [key, old] of qc.getQueriesData({ queryKey: p.queryKey })) {
          if (old === undefined) continue;
          qc.setQueryData(key, p.update(old));
          written.push([key, qc.getQueryState(key)?.dataUpdateCount ?? -1]);
        }
      }
      const id = (nextId += 1);
      active.set(id, { patches: ps, fresh: new Set() });
      bump();
      return { id, snapshot, written };
    },
    rollback: (ctx: OptimisticContext | undefined) => {
      if (!ctx) return;
      active.delete(ctx.id);
      bump();
      for (const [key, data] of ctx.snapshot) {
        const ours = ctx.written.find(([k]) => hash(k) === hash(key))?.[1];
        if (qc.getQueryState(key)?.dataUpdateCount === ours) qc.setQueryData(key, data);
      }
    },
    onSettled: (_data: unknown, error: unknown, _vars: unknown, ctx: OptimisticContext | undefined) => {
      const entry = ctx && !error ? active.get(ctx.id) : undefined;
      if (ctx && entry) {
        // A fetch counts only if it started after this point: one already in
        // flight may have read the server before the action applied.
        const after = new Set<string>();
        const release = cache.subscribe((event) => {
          if (!active.has(ctx.id)) return release();
          const q = event.query;
          if (!entry.patches.some((p) => startsWith(q.queryKey, p.queryKey))) return;
          if (event.type === 'updated' && event.action.type === 'fetch') after.add(q.queryHash);
          if (event.type === 'updated' && event.action.type === 'success' && !event.action.manual && after.has(q.queryHash)) {
            entry.fresh.add(hash(q.queryKey));
            bump();
          }
          const left = entry.patches.some((p) => cache.findAll({ queryKey: p.queryKey }).some((x) => !entry.fresh.has(hash(x.queryKey))));
          if (!left) {
            release();
            active.delete(ctx.id);
            bump();
          }
        });
      }
      for (const key of refresh) void qc.invalidateQueries({ queryKey: key });
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

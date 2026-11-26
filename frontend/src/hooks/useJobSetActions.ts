import { useMutation, useQueryClient } from '@tanstack/solid-query';
import { createSignal } from 'solid-js';
import { basePath } from '../basePath';
import { partialFailure, post } from '../http';
import { notifyError, pushToast } from '../toast';
import { t } from '../i18n';
import { optimistic, statsPatch, type OptimisticContext, type Patch } from '../optimistic';

// The three mutable sorted-set views. The string doubles as the API path
// segment (`<mount>/api/<set>`) and the query key the pages cache under.
export type JobSetName = 'retries' | 'scheduled' | 'dead';

// One page of a filtered `<set>/all/:cmd?substr=` sweep (ApiController#sweep_matching).
interface SweepResponse {
  ok: boolean;
  count: number;
  matched: number;
  done: boolean;
  cursor: number;
}

// A sweep stops after this many requests (up to 1,000 entries each) and says
// so, rather than holding the page in a loop on a set that keeps growing.
const SWEEP_MAX_REQUESTS = 100;

// Re-targets the exact (score, jid) pair server-side. Mirrors
// Wurk::SortedEntry#id ("<score>|<jid>"); the controller splits it back apart
// and resolves via JobSet#fetch, so float→string round-tripping never matters.
export function entryKey(e: { score: number; jid: string }): string {
  return `${e.score}|${e.jid}`;
}

// Single/bulk/all mutations for one job set. Each invalidates both the set's
// own query and `stats` (the nav badges + dashboard counts read from it) so
// the UI reflects the change without a manual refresh. `post` throws on a
// non-2xx (read-only 403, gone 404, Redis-down 503), so `notifyError` raises a
// status-aware toast for every call site without each page wiring its own.
// A 422 is a partial failure — some entries DID apply — so it gets its own
// count-bearing toast and still refreshes the list.
// solid-query's useMutation takes an options accessor; call `single.mutate(...)`.
// Where an entry goes when an action moves it out of `set`, for the stats
// badges: a retried/enqueued entry joins a queue, a killed one the dead set.
function movedTo(cmd: string): string | null {
  if (cmd === 'kill') return 'dead';
  if (cmd === 'retry' || cmd === 'add_to_queue') return 'enqueued';
  return null;
}

interface ListPage {
  total: number;
  count?: number;
  entries: Array<{ score: number; jid: string }>;
  filtered_total?: number;
}

export function useJobSetActions(set: JobSetName) {
  const qc = useQueryClient();
  const invalidate = () => {
    qc.invalidateQueries({ queryKey: [set] });
    qc.invalidateQueries({ queryKey: ['stats'] });
  };

  const onError = (err: unknown) => {
    const partial = partialFailure(err);
    if (!partial) return notifyError(err);
    const summary = t('toast.partial', { count: partial.count, failed: partial.failed.length });
    // The response guard validates the array, not the individual diagnostics.
    const diagnostics = partial.failed.flatMap((entry: unknown) => {
      if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return [];
      const { key, error } = entry as Record<string, unknown>;
      const fields = [key, error].filter((field): field is string => typeof field === 'string');
      return fields.length ? [fields.join(': ')] : [];
    });
    pushToast([summary, ...diagnostics].join('\n'), 'error');
    invalidate();
  };

  // The rows leave every cached page of the set at once, and the counters
  // move with them, before the request returns.
  const removeKeys = (keys: Set<string> | 'all', cmd: string): Patch[] => {
    const list: Patch = {
      queryKey: [set],
      update: (old: ListPage) => {
        if (!old || !Array.isArray(old.entries)) return old;
        const entries = keys === 'all' ? [] : old.entries.filter((e) => !keys.has(entryKey(e)));
        const gone = old.entries.length - entries.length;
        const total = keys === 'all' ? 0 : Math.max(0, old.total - gone);
        const next: ListPage = { ...old, entries, total, count: entries.length };
        if (typeof old.filtered_total === 'number') next.filtered_total = keys === 'all' ? 0 : Math.max(0, old.filtered_total - gone);
        return next;
      },
    };
    const n = keys === 'all' ? Number.MAX_SAFE_INTEGER : keys.size;
    const counts: Record<string, number> = { [set === 'scheduled' ? 'scheduled' : set === 'dead' ? 'dead' : 'retries']: -n };
    const to = movedTo(cmd);
    if (to && keys !== 'all') counts[to] = n;
    return [list, statsPatch(counts)];
  };

  const single = useMutation(() => {
    const o = optimistic(qc, ({ key, cmd }: { key: string; cmd: string }) => removeKeys(new Set([key]), cmd), [[set], ['stats']]);
    return {
      mutationFn: ({ key, cmd }: { key: string; cmd: string }) =>
        post(`${basePath()}/api/${set}/${encodeURIComponent(key)}`, { cmd }),
      onMutate: o.onMutate,
      onError: (err: unknown, _v: { key: string; cmd: string }, ctx: OptimisticContext | undefined) => {
        o.rollback(ctx);
        onError(err);
      },
      onSettled: o.onSettled,
    };
  });

  const bulk = useMutation(() => {
    const o = optimistic(qc, ({ keys, cmd }: { keys: string[]; cmd: string }) => removeKeys(new Set(keys), cmd), [[set], ['stats']]);
    return {
      mutationFn: ({ keys, cmd }: { keys: string[]; cmd: string }) => post(`${basePath()}/api/${set}`, { keys, cmd }),
      onMutate: o.onMutate,
      onError: (err: unknown, _v: { keys: string[]; cmd: string }, ctx: OptimisticContext | undefined) => {
        o.rollback(ctx);
        onError(err);
      },
      onSettled: o.onSettled,
    };
  });

  const all = useMutation(() => {
    const o = optimistic(qc, (cmd: string) => removeKeys('all', cmd), [[set], ['stats']]);
    return {
      mutationFn: (cmd: string) => post(`${basePath()}/api/${set}/all/${cmd}`),
      onMutate: o.onMutate,
      onError: (err: unknown, _v: string, ctx: OptimisticContext | undefined) => {
        o.rollback(ctx);
        onError(err);
      },
      onSettled: o.onSettled,
    };
  });

  // `cmd` over every entry the filter matches: each POST applies at most
  // 1,000 matches within the server's scan budget and hands back a cursor, so
  // the sweep follows it until the server reports the end of the set.
  // `swept` is the running count for the action bar while it goes.
  const [swept, setSwept] = createSignal<number | null>(null);
  const sweep = useMutation(() => ({
    mutationFn: async ({ cmd, substr }: { cmd: string; substr: string }) => {
      let applied = 0;
      let cursor = 0;
      setSwept(0);
      for (let i = 0; i < SWEEP_MAX_REQUESTS; i += 1) {
        const url = `${basePath()}/api/${set}/all/${cmd}?substr=${encodeURIComponent(substr)}&cursor=${cursor}`;
        const body = (await (await post(url)).json()) as SweepResponse;
        applied += body.count;
        setSwept(applied);
        if (body.done) return { applied, done: true };
        cursor = body.cursor;
      }
      return { applied, done: false };
    },
    onSuccess: ({ applied, done }: { applied: number; done: boolean }) => {
      pushToast(t(done ? 'toast.swept' : 'toast.swept_partial', { n: applied }), 'success');
      invalidate();
    },
    // Earlier pages may already have applied before a later one failed, so
    // the list is stale either way.
    onError: (err: unknown) => {
      onError(err);
      invalidate();
    },
    onSettled: () => setSwept(null),
  }));

  return { single, bulk, all, sweep, swept };
}

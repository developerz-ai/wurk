import { useMutation, useQueryClient } from '@tanstack/solid-query';
import { createSignal } from 'solid-js';
import { basePath } from '../basePath';
import { partialFailure, post } from '../http';
import { notifyError, pushToast } from '../toast';
import { t } from '../i18n';

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

  const single = useMutation(() => ({
    mutationFn: ({ key, cmd }: { key: string; cmd: string }) =>
      post(`${basePath()}/api/${set}/${encodeURIComponent(key)}`, { cmd }),
    onSuccess: invalidate,
    onError,
  }));

  const bulk = useMutation(() => ({
    mutationFn: ({ keys, cmd }: { keys: string[]; cmd: string }) =>
      post(`${basePath()}/api/${set}`, { keys, cmd }),
    onSuccess: invalidate,
    onError,
  }));

  const all = useMutation(() => ({
    mutationFn: (cmd: string) => post(`${basePath()}/api/${set}/all/${cmd}`),
    onSuccess: invalidate,
    onError,
  }));

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
    onError,
    onSettled: () => setSwept(null),
  }));

  return { single, bulk, all, sweep, swept };
}

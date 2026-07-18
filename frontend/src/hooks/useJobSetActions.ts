import { useMutation, useQueryClient } from '@tanstack/solid-query';
import { basePath } from '../basePath';
import { post } from '../http';
import { notifyError } from '../toast';

// The three mutable sorted-set views. The string doubles as the API path
// segment (`<mount>/api/<set>`) and the query key the pages cache under.
export type JobSetName = 'retries' | 'scheduled' | 'dead';

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
// solid-query's useMutation takes an options accessor; call `single.mutate(...)`.
export function useJobSetActions(set: JobSetName) {
  const qc = useQueryClient();
  const invalidate = () => {
    qc.invalidateQueries({ queryKey: [set] });
    qc.invalidateQueries({ queryKey: ['stats'] });
  };

  const single = useMutation(() => ({
    mutationFn: ({ key, cmd }: { key: string; cmd: string }) =>
      post(`${basePath()}/api/${set}/${encodeURIComponent(key)}`, { cmd }),
    onSuccess: invalidate,
    onError: notifyError,
  }));

  const bulk = useMutation(() => ({
    mutationFn: ({ keys, cmd }: { keys: string[]; cmd: string }) =>
      post(`${basePath()}/api/${set}`, { keys, cmd }),
    onSuccess: invalidate,
    onError: notifyError,
  }));

  const all = useMutation(() => ({
    mutationFn: (cmd: string) => post(`${basePath()}/api/${set}/all/${cmd}`),
    onSuccess: invalidate,
    onError: notifyError,
  }));

  return { single, bulk, all };
}

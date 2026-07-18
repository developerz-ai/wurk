import { useMutation, useQueryClient } from '@tanstack/solid-query';
import { basePath } from '../basePath';

// The three mutable sorted-set views. The string doubles as the API path
// segment (`<mount>/api/<set>`) and the query key the pages cache under.
export type JobSetName = 'retries' | 'scheduled' | 'dead';

// Re-targets the exact (score, jid) pair server-side. Mirrors
// Wurk::SortedEntry#id ("<score>|<jid>"); the controller splits it back apart
// and resolves via JobSet#fetch, so float→string round-tripping never matters.
export function entryKey(e: { score: number; jid: string }): string {
  return `${e.score}|${e.jid}`;
}

async function postJSON(url: string, body?: unknown): Promise<Response> {
  const res = await fetch(url, {
    method: 'POST',
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  // fetch only rejects on network failure; a 4xx/5xx still resolves. Throw so
  // the mutation's onError fires (and onSuccess/cache-invalidation does not)
  // when the server rejects the action (e.g. 403 in read-only, 400/404).
  if (!res.ok) throw new Error(`Request failed (${res.status})`);
  return res;
}

// Single/bulk/all mutations for one job set. Each invalidates both the set's
// own query and `stats` (the nav badges + dashboard counts read from it) so
// the UI reflects the change without a manual refresh. solid-query's
// useMutation takes an options accessor; call `single.mutate({ key, cmd })`.
export function useJobSetActions(set: JobSetName) {
  const qc = useQueryClient();
  const invalidate = () => {
    qc.invalidateQueries({ queryKey: [set] });
    qc.invalidateQueries({ queryKey: ['stats'] });
  };

  const single = useMutation(() => ({
    mutationFn: ({ key, cmd }: { key: string; cmd: string }) =>
      postJSON(`${basePath()}/api/${set}/${encodeURIComponent(key)}`, { cmd }),
    onSuccess: invalidate,
  }));

  const bulk = useMutation(() => ({
    mutationFn: ({ keys, cmd }: { keys: string[]; cmd: string }) =>
      postJSON(`${basePath()}/api/${set}`, { keys, cmd }),
    onSuccess: invalidate,
  }));

  const all = useMutation(() => ({
    mutationFn: (cmd: string) => postJSON(`${basePath()}/api/${set}/all/${cmd}`),
    onSuccess: invalidate,
  }));

  return { single, bulk, all };
}

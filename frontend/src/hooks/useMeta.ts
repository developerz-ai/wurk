import { useQuery } from '@tanstack/react-query';

export interface Meta {
  read_only: boolean;
  // Optional host-supplied banner copy; null → SPA uses its localized default.
  read_only_message: string | null;
}

// Boot-time dashboard flags. Fetched once and cached forever — these only
// change on a server restart, so there's no point re-polling.
export function useMeta() {
  return useQuery<Meta>({
    queryKey: ['meta'],
    queryFn: () => fetch('/wurk/api/meta').then((r) => r.json() as Promise<Meta>),
    staleTime: Infinity,
  });
}

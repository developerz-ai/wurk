import { useQuery } from '@tanstack/react-query';

// A dashboard tab registered by a third-party gem via
// Sidekiq::Web.register_extension. wurk surfaces it in the nav as a link to its
// path; the extension's own server-rendered view is not injected into the SPA.
export interface CustomTab {
  name: string;
  path: string;
}

export interface Meta {
  read_only: boolean;
  // Optional host-supplied banner copy; null → SPA uses its localized default.
  read_only_message: string | null;
  // Tabs registered by third-party extensions (empty/absent when none).
  custom_tabs?: CustomTab[];
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

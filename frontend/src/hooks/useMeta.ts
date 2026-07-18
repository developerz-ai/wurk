import { useQuery } from '@tanstack/solid-query';
import { basePath } from '../basePath';

// A dashboard tab registered by a third-party gem via
// Sidekiq::Web.register_extension. When ext_name is present, the Extension page
// fetches the extension's server-rendered view from <mount>/ext/<ext_name>/* and
// embeds it natively; tabs added by bare `tabs[]=` mutation have no extension
// to render (ext_name null) and fall back to an iframe of their own path.
export interface CustomTab {
  name: string;
  path: string;
  ext_name?: string | null;
}

export interface Meta {
  // Gem version (e.g. "1.1.0"), shown next to the wordmark in the nav.
  version?: string;
  read_only: boolean;
  // Optional host-supplied banner copy; null → SPA uses its localized default.
  read_only_message: string | null;
  // Tabs registered by third-party extensions (empty/absent when none).
  custom_tabs?: CustomTab[];
}

// Boot-time dashboard flags. Fetched once and cached forever — these only
// change on a server restart, so there's no point re-polling. Returns the
// solid-query result store; read `query.data?.read_only` reactively (never
// destructure it — that severs the store's reactivity).
export function useMeta() {
  return useQuery<Meta>(() => ({
    queryKey: ['meta'],
    queryFn: () => fetch(`${basePath()}/api/meta`).then((r) => r.json() as Promise<Meta>),
    staleTime: Infinity,
  }));
}

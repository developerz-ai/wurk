// The dashboard engine can be mounted at any path — Sidekiq's convention is
// /sidekiq, Wurk's dummy uses /wurk, a host app might pick /admin/jobs. The
// Rails DashboardController injects the real mount prefix into the served
// index.html as `window.__WURK_BASE__`, so the SPA derives every API URL and
// its router base from that instead of a compiled-in literal. The Vite dev
// server ships the shell with no Rails layer to inject it, so we fall back to
// the /wurk mount `bin/rake frontend:dev` (and the dummy app) uses.
//
// Any trailing slash is stripped so callers concatenate directly:
// `basePath() + '/api/meta'`. A root mount yields '' → '/api/meta'.
declare global {
  interface Window {
    __WURK_BASE__?: string;
  }
}

export function basePath(): string {
  const injected = typeof window !== 'undefined' ? window.__WURK_BASE__ : undefined;
  return (injected ?? '/wurk').replace(/\/+$/, '');
}

// Page chunks by nav path, registered by App.tsx where the lazy pages are
// declared. A click on a page whose chunk is not loaded yet leaves the old page
// up (the router waits for it) with RouteProgress showing; a hover or focus on
// the link fetches the chunk first, and every chunk loads once the browser is
// idle, so that wait is rare.
interface Chunk {
  preload: () => Promise<unknown>;
}

let byPath: Record<string, Chunk> = {};
let all: Chunk[] = [];

export function registerPages(paths: Record<string, Chunk>, others: Chunk[] = []) {
  byPath = paths;
  all = [...Object.values(paths), ...others];
}

export function preloadPage(path: string) {
  const page = path.startsWith('/ext/') ? byPath['/ext/'] : byPath[path];
  if (page) void page.preload();
}

export function preloadPages() {
  const run = () => all.forEach((p) => void p.preload());
  if (typeof window === 'undefined') return;
  if ('requestIdleCallback' in window) window.requestIdleCallback(run, { timeout: 3000 });
  else setTimeout(run, 1500);
}

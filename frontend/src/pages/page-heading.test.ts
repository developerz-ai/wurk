import { describe, it, expect } from 'vitest';

/**
 * Every routed page owns the document's `<h1>`.
 *
 * `PageHeader` renders it, and eleven of the thirteen pages used it — the dashboard
 * and the metrics page did not, so those two documents began at `<h2>` and a screen
 * reader landed in a page with no title. Nothing caught it: axe reports no violation
 * for a missing `h1` (it is a structural convention, not a WCAG rule), and neither
 * page had a render test.
 *
 * Sources are read through Vite's own `?raw` glob rather than `node:fs`, so this needs
 * no `@types/node` and type-checks under the app's tsconfig like any other module.
 */
const PAGE_SOURCES = import.meta.glob('./*.tsx', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const APP = Object.entries(
  import.meta.glob('../App.tsx', { query: '?raw', import: 'default', eager: true }) as Record<
    string,
    string
  >,
)[0]?.[1];

/** The page modules the router actually mounts, read from App.tsx's lazy imports. */
function routedPages(): string[] {
  const mounted = new Set<string>();
  for (const [, component] of (APP ?? '').matchAll(/<Route[^>]*component=\{(\w+)\}/g)) {
    mounted.add(component);
  }
  const files: string[] = [];
  for (const [, name, path] of (APP ?? '').matchAll(
    /const (\w+) = lazy\(\(\) => import\('\.\/pages\/(\w+)'\)\)/g,
  )) {
    if (mounted.has(name)) files.push(`./${path}.tsx`);
  }
  return files;
}

describe('routed pages', () => {
  const pages = routedPages();

  it('finds every page the router mounts', () => {
    // A rename that broke the parse would otherwise leave this file asserting nothing.
    expect(APP).toBeDefined();
    expect(pages.length).toBeGreaterThanOrEqual(13);
    for (const page of pages) expect(Object.keys(PAGE_SOURCES)).toContain(page);
  });

  for (const page of pages) {
    it(`${page} renders the page heading`, () => {
      const source = PAGE_SOURCES[page] ?? '';
      const hasHeading = source.includes('<PageHeader') || source.includes('<h1');
      expect(hasHeading, `${page} renders no <h1>: use <PageHeader>, as the other pages do`).toBe(
        true,
      );
    });
  }
});

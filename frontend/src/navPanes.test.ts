import { describe, it, expect } from 'vitest';
import { NAV_PANES } from './navPanes';

/**
 * The inventory is the repo's only list of the dashboard's shipped tabs, so it
 * has to agree with the two other things it describes: the paths the router
 * mounts, and the locale bundles that translate the labels. A pane pointing
 * nowhere, missing its label in one locale or doubling up fails here instead
 * of shipping a dead tab.
 *
 * Sources are read through Vite's own `?raw` glob rather than node:fs, so this
 * needs no `@types/node` and type-checks like any other module.
 */
const APP = Object.entries(
  import.meta.glob('./App.tsx', { query: '?raw', import: 'default', eager: true }) as Record<
    string,
    string
  >,
)[0]?.[1];

/** Every shipped locale bundle, discovered rather than listed, so a new bundle is covered too. */
const LOCALE_BUNDLES = import.meta.glob('./i18n/*.json', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

/** Every path the router mounts, parsed out of App.tsx's route table. */
function routedPaths(): string[] {
  return [...(APP ?? '').matchAll(/<Route[^>]*\spath="([^"]+)"/g)].map(([, path]) => path);
}

/** A dotted key path into a translation bundle, e.g. "nav.queues". */
function translate(bundle: unknown, key: string): unknown {
  let node: unknown = bundle;
  for (const part of key.split('.')) {
    if (!node || typeof node !== 'object') return undefined;
    node = (node as Record<string, unknown>)[part];
  }
  return node;
}

describe('nav pane inventory', () => {
  it('holds exactly the shipped panes', () => {
    expect(NAV_PANES.length).toBe(13);
  });

  it('points every pane at a path the router mounts', () => {
    const routes = routedPaths();
    // A route table that stopped parsing would leave this empty, and every pane
    // would then "pass" by being absent from it.
    expect(APP).toBeDefined();
    expect(routes.length).toBeGreaterThan(NAV_PANES.length);
    expect(NAV_PANES.filter((pane) => !routes.includes(pane.to)).map((pane) => pane.to)).toEqual([]);
  });

  it('keeps destinations unique', () => {
    const destinations = NAV_PANES.map((pane) => pane.to);
    expect(new Set(destinations).size).toBe(destinations.length);
  });

  it('marks the dashboard link as the only exact match', () => {
    expect(NAV_PANES.filter((pane) => pane.end).map((pane) => pane.to)).toEqual(['/']);
    for (const pane of NAV_PANES) expect(pane.end).toBe(pane.to === '/');
  });

  it('gives every pane a Font Awesome solid icon', () => {
    expect(
      NAV_PANES.filter((pane) => !/^fa-[a-z0-9-]+$/.test(pane.icon)).map((pane) => pane.icon),
    ).toEqual([]);
  });

  it('translates every pane label in every shipped locale', () => {
    const bundles = Object.entries(LOCALE_BUNDLES);
    expect(bundles.map(([name]) => name).some((name) => name.endsWith('/en.json'))).toBe(true);

    const broken: string[] = [];
    for (const [name, source] of bundles) {
      const bundle = JSON.parse(source) as unknown;
      for (const pane of NAV_PANES) {
        const value = translate(bundle, pane.labelKey);
        if (typeof value !== 'string' || value.trim() === '') broken.push(`${name}: ${pane.labelKey}`);
      }
    }
    expect(broken).toEqual([]);
  });
});

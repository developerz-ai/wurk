import { describe, it, expect, afterEach, beforeEach, vi } from 'vitest';
import {
  t,
  directionFor,
  bundleFor,
  detectLocale,
  applyLocale,
  setLocale,
  availableLocales,
} from './index';
import en from './en.json';
import es from './es.json';
import fr from './fr.json';
import de from './de.json';
import ptBR from './pt-BR.json';
import ja from './ja.json';
import zhCN from './zh-CN.json';
import ar from './ar.json';

describe('t()', () => {
  it('resolves a nested key path', () => {
    expect(t('nav.dashboard')).toBe('Dashboard');
    expect(t('busy.heartbeat')).toBe('Heartbeat');
  });

  it('interpolates {var} placeholders', () => {
    expect(t('busy.hosts', { n: 3 })).toBe('3 hosts');
    expect(t('actions.selected', { n: 7 })).toBe('7 selected');
    expect(t('actions.confirm', { action: 'Retry', scope: 'this job' })).toBe(
      'Retry this job? This cannot be undone.',
    );
  });

  it('leaves placeholders untouched when no vars are given', () => {
    expect(t('busy.hosts')).toBe('{n} hosts');
  });

  it('returns the path when the key is missing', () => {
    expect(t('nope.not.here')).toBe('nope.not.here');
    // A path that resolves to an object (not a leaf string) also falls back.
    expect(t('nav')).toBe('nav');
  });
});

describe('directionFor()', () => {
  it('flips RTL languages', () => {
    expect(directionFor('ar')).toBe('rtl');
    expect(directionFor('he')).toBe('rtl');
    expect(directionFor('fa')).toBe('rtl');
    // The base subtag drives direction, so region-tagged locales still flip.
    expect(directionFor('ar-EG')).toBe('rtl');
  });

  it('leaves LTR languages alone', () => {
    expect(directionFor('en')).toBe('ltr');
    expect(directionFor('de')).toBe('ltr');
    expect(directionFor('zh-CN')).toBe('ltr');
  });
});

// Flattens a nested translation bundle into dotted leaf paths, e.g.
// { nav: { dashboard: 'x' } } -> { 'nav.dashboard': 'x' }.
function flatten(obj: unknown, prefix = ''): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
    const path = prefix ? `${prefix}.${k}` : k;
    if (v && typeof v === 'object') {
      Object.assign(out, flatten(v, path));
    } else {
      out[path] = String(v);
    }
  }
  return out;
}

// Every {var} placeholder referenced in a translation, e.g. "{n} hosts" -> ['n'].
function placeholders(s: string): string[] {
  return Array.from(s.matchAll(/\{(\w+)\}/g), (m) => m[1]).sort();
}

// Locale-parity guard: every bundle must translate exactly the keys en.json
// defines (no missing coverage, no orphaned keys left over from a rename) and
// preserve the same {var} placeholders so interpolation never breaks for a
// translated locale. This is what keeps "fill in the missing keys" honest —
// a PR that adds an en.json key without touching every locale fails here.
describe('locale parity', () => {
  const baseline = flatten(en);
  const locales: Record<string, unknown> = { es, fr, de, 'pt-BR': ptBR, ja, 'zh-CN': zhCN, ar };

  for (const [name, bundle] of Object.entries(locales)) {
    describe(name, () => {
      const flat = flatten(bundle);

      it('has no missing keys', () => {
        const missing = Object.keys(baseline).filter((k) => !(k in flat));
        expect(missing).toEqual([]);
      });

      it('has no orphaned keys absent from en.json', () => {
        const orphaned = Object.keys(flat).filter((k) => !(k in baseline));
        expect(orphaned).toEqual([]);
      });

      it('preserves every {var} placeholder from en.json', () => {
        const mismatched = Object.keys(baseline).filter((k) => {
          if (!(k in flat)) return false;
          const enVars = placeholders(baseline[k]);
          return JSON.stringify(placeholders(flat[k])) !== JSON.stringify(enVars);
        });
        expect(mismatched).toEqual([]);
      });
    });
  }
});

describe('bundleFor()', () => {
  it('matches an exact key, case-insensitively', () => {
    expect(bundleFor('de')).toBe('de');
    expect(bundleFor('pt-BR')).toBe('pt-BR');
    expect(bundleFor('PT-br')).toBe('pt-BR');
  });

  it('falls back to the base subtag', () => {
    expect(bundleFor('es-419')).toBe('es');
    expect(bundleFor('en-GB')).toBe('en');
    expect(bundleFor('ar-EG')).toBe('ar');
  });

  // The previous `locale.startsWith(key)` match was backwards for regional
  // bundles — "pt".startsWith("pt-BR") is false, so a browser set to plain
  // Portuguese silently rendered English.
  it('promotes a bare subtag to its regional bundle', () => {
    expect(bundleFor('pt')).toBe('pt-BR');
    expect(bundleFor('zh')).toBe('zh-CN');
    expect(bundleFor('pt-PT')).toBe('pt-BR');
    expect(bundleFor('zh-Hant-TW')).toBe('zh-CN');
  });

  it('reports nothing for a locale this build does not ship', () => {
    expect(bundleFor('he')).toBeUndefined();
    expect(bundleFor('fa-IR')).toBeUndefined();
  });

  it('resolves every advertised locale to itself', () => {
    expect(availableLocales.length).toBeGreaterThan(0);
    for (const code of availableLocales) expect(bundleFor(code)).toBe(code);
  });
});

// Every locale source lives on a global, so each test owns the whole
// environment and hands it back clean.
function clearLocaleEnvironment(): void {
  history.replaceState({}, '', '/');
  localStorage.clear();
  document.getElementById('wurk-root')?.remove();
  // Drops the own-property stub, revealing jsdom's real prototype getter.
  delete (navigator as unknown as Record<string, unknown>).languages;
  delete (navigator as unknown as Record<string, unknown>).language;
  document.documentElement.removeAttribute('lang');
  document.documentElement.removeAttribute('dir');
}

function stubLanguages(langs: string[]): void {
  Object.defineProperty(navigator, 'languages', { value: langs, configurable: true });
  Object.defineProperty(navigator, 'language', { value: langs[0] ?? '', configurable: true });
}

function mountRoot(dataLocale?: string): HTMLElement {
  const el = document.createElement('div');
  el.id = 'wurk-root';
  if (dataLocale !== undefined) el.dataset.locale = dataLocale;
  document.body.appendChild(el);
  return el;
}

describe('detectLocale()', () => {
  beforeEach(clearLocaleEnvironment);
  afterEach(clearLocaleEnvironment);

  it('prefers ?locale= over every persisted or detected source', () => {
    history.replaceState({}, '', '/?locale=fr');
    localStorage.setItem('wurk.locale', 'de');
    mountRoot('ja');
    stubLanguages(['es']);
    expect(detectLocale()).toBe('fr');
  });

  it('prefers the stored pick over the server hint', () => {
    localStorage.setItem('wurk.locale', 'de');
    mountRoot('ja');
    stubLanguages(['es']);
    expect(detectLocale()).toBe('de');
  });

  it('prefers the server hint over browser preferences', () => {
    mountRoot('ja');
    stubLanguages(['es']);
    expect(detectLocale()).toBe('ja');
  });

  it('walks navigator.languages in order', () => {
    stubLanguages(['zh-CN', 'es']);
    expect(detectLocale()).toBe('zh-CN');
  });

  // A passive browser preference we ship nothing for is skipped rather than
  // honoured, so a Hebrew browser doesn't get an RTL board of English strings.
  it('skips browser preferences with no bundle', () => {
    stubLanguages(['he', 'de']);
    expect(detectLocale()).toBe('de');
  });

  it('honours an explicit pick with no bundle', () => {
    localStorage.setItem('wurk.locale', 'he');
    stubLanguages(['de']);
    expect(detectLocale()).toBe('he');
  });

  it('ends at en', () => {
    stubLanguages([]);
    expect(detectLocale()).toBe('en');
  });

  it('ignores malformed tags from every source', () => {
    history.replaceState({}, '', '/?locale=%3Cscript%3E');
    localStorage.setItem('wurk.locale', 'not a locale');
    mountRoot('');
    stubLanguages(['de']);
    expect(detectLocale()).toBe('de');
  });
});

describe('applyLocale()', () => {
  beforeEach(clearLocaleEnvironment);
  afterEach(clearLocaleEnvironment);

  it('mirrors lang and dir onto the document and the root node', () => {
    const root = mountRoot();
    applyLocale('ar-EG');
    expect(document.documentElement.lang).toBe('ar-EG');
    expect(document.documentElement.dir).toBe('rtl');
    expect(root.dir).toBe('rtl');
  });

  it('is a no-op on the root node when it is absent', () => {
    applyLocale('de');
    expect(document.documentElement.dir).toBe('ltr');
  });
});

describe('setLocale()', () => {
  beforeEach(clearLocaleEnvironment);
  afterEach(clearLocaleEnvironment);

  // jsdom's Location is unforgeable, so `reload`/`assign` can't be stubbed and
  // the reload itself is out of reach here (it logs "Not implemented" and is a
  // no-op). What's pinned is the observable contract: the pick is persisted and
  // mirrored before the page turns over.
  it('persists the pick and mirrors it onto the document', () => {
    const root = mountRoot();
    setLocale('ar');
    expect(localStorage.getItem('wurk.locale')).toBe('ar');
    expect(document.documentElement.lang).toBe('ar');
    expect(document.documentElement.dir).toBe('rtl');
    expect(root.dir).toBe('rtl');
  });

  it('rejects a malformed tag instead of persisting it', () => {
    setLocale('not a locale');
    expect(localStorage.getItem('wurk.locale')).toBeNull();
    expect(document.documentElement.hasAttribute('lang')).toBe(false);
  });
});

describe('resolved bundle', () => {
  beforeEach(clearLocaleEnvironment);
  afterEach(() => {
    clearLocaleEnvironment();
    vi.resetModules();
  });

  it('serves the regional bundle for a bare subtag', async () => {
    mountRoot('pt');
    vi.resetModules();
    const mod = await import('./index');
    expect(mod.locale).toBe('pt');
    expect(mod.t('nav.dashboard')).toBe('Painel');
  });

  it('serves the base bundle for an unshipped region', async () => {
    mountRoot('es-419');
    vi.resetModules();
    const mod = await import('./index');
    expect(mod.t('nav.dashboard')).toBe('Panel');
  });

  // Deliberate: a bundle-less locale still flips direction and falls back to en
  // strings, so a host can override copy without shipping a translation file.
  it('flips RTL with English strings when nothing ships for the locale', async () => {
    mountRoot('he');
    vi.resetModules();
    const mod = await import('./index');
    expect(mod.locale).toBe('he');
    expect(mod.dir).toBe('rtl');
    expect(mod.t('nav.dashboard')).toBe('Dashboard');
  });
});

describe('host overrides', () => {
  afterEach(() => {
    document.getElementById('wurk-i18n')?.remove();
    vi.resetModules();
  });

  it('deep-merges a #wurk-i18n script tag over the base bundle', async () => {
    const el = document.createElement('script');
    el.id = 'wurk-i18n';
    el.type = 'application/json';
    // Override one leaf; siblings and untouched branches must survive the merge.
    el.textContent = JSON.stringify({ nav: { dashboard: 'Control Center' } });
    document.head.appendChild(el);

    // The bundle reads the override at module-eval time, so re-evaluate it with
    // the script tag present.
    vi.resetModules();
    const mod = await import('./index');
    expect(mod.t('nav.dashboard')).toBe('Control Center');
    expect(mod.t('nav.queues')).toBe('Queues');
  });
});

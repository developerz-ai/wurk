import { describe, it, expect, afterEach, vi } from 'vitest';
import { t, directionFor } from './index';
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

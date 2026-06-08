import en from './en.json';
import es from './es.json';
import fr from './fr.json';
import de from './de.json';
import ptBR from './pt-BR.json';
import ja from './ja.json';
import zhCN from './zh-CN.json';
import ar from './ar.json';

type Translations = typeof en;
type DeepPartial<T> = { [K in keyof T]?: T[K] extends object ? DeepPartial<T[K]> : T[K] };

const LOCALES: Record<string, DeepPartial<Translations>> = {
  en,
  es,
  fr,
  de,
  'pt-BR': ptBR,
  ja,
  'zh-CN': zhCN,
  ar,
};

// Languages written right-to-left. The detected locale's base subtag (e.g. the
// "ar" of "ar-EG") drives both `dir` and the matched bundle below. Bundles are
// optional: a locale with no bundle still flips to RTL and falls back to en
// strings, so a host can override copy without re-shipping a translation file.
const RTL_LANGS = ['ar', 'he', 'fa'];

export function directionFor(loc: string): 'rtl' | 'ltr' {
  return RTL_LANGS.includes(loc.toLowerCase().split('-')[0]) ? 'rtl' : 'ltr';
}

function loadHostOverrides(): DeepPartial<Translations> {
  try {
    const el = document.getElementById('wurk-i18n');
    return el ? (JSON.parse(el.textContent ?? '{}') as DeepPartial<Translations>) : {};
  } catch {
    return {};
  }
}

function detectLocale(): string {
  const el = document.getElementById('wurk-root');
  if (el?.dataset.locale) return el.dataset.locale;
  return navigator.language || 'en';
}

function deepMerge<T extends object>(base: T, override: DeepPartial<T>): T {
  const out = { ...base } as Record<string, unknown>;
  for (const k of Object.keys(override) as (keyof T)[]) {
    const ov = override[k];
    const bv = base[k];
    if (
      ov &&
      typeof ov === 'object' &&
      !Array.isArray(ov) &&
      bv &&
      typeof bv === 'object'
    ) {
      out[k as string] = deepMerge(bv as object, ov as DeepPartial<typeof bv>);
    } else if (ov !== undefined) {
      out[k as string] = ov;
    }
  }
  return out as T;
}

export const locale = detectLocale();
export const dir = directionFor(locale);
const langKey = Object.keys(LOCALES).find((k) => locale.startsWith(k)) ?? 'en';
const base = deepMerge(en, (LOCALES[langKey] ?? {}) as DeepPartial<typeof en>);
const merged = deepMerge(base, loadHostOverrides());

export function t(path: string, vars?: Record<string, string | number>): string {
  const parts = path.split('.');
  let node: unknown = merged;
  for (const p of parts) {
    if (node && typeof node === 'object') {
      node = (node as Record<string, unknown>)[p];
    } else {
      return path;
    }
  }
  if (typeof node !== 'string') return path;
  if (!vars) return node;
  return node.replace(/\{(\w+)\}/g, (_, k: string) => String(vars[k] ?? k));
}

export default merged;

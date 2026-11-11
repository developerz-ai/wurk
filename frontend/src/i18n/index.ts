import en from './en.json';

type Translations = typeof en;
type DeepPartial<T> = { [K in keyof T]?: T[K] extends object ? DeepPartial<T[K]> : T[K] };
type Bundle = DeepPartial<Translations>;

// en is the fallback under every bundle, so it ships in the entry chunk; every
// other bundle is its own chunk, fetched only by a visitor who renders it.
//
// Declaration order is load-bearing: a locale naming only a base subtag ("pt",
// "zh") resolves to the first bundle declared for that base, so shipping a
// second regional bundle for an existing base changes what the bare subtag
// picks. Order deliberately, don't append blindly.
const LOCALES: Record<string, () => Promise<{ default: Bundle }>> = {
  en: () => Promise.resolve({ default: en }),
  es: () => import('./es.json'),
  fr: () => import('./fr.json'),
  de: () => import('./de.json'),
  'pt-BR': () => import('./pt-BR.json'),
  ja: () => import('./ja.json'),
  'zh-CN': () => import('./zh-CN.json'),
  ar: () => import('./ar.json'),
};

/** Locale codes with a bundle in this build, in declaration (menu) order. */
export const availableLocales: readonly string[] = Object.freeze(Object.keys(LOCALES));

const STORAGE_KEY = 'wurk.locale';
const QUERY_KEY = 'locale';

// Languages written right-to-left. The detected locale's base subtag (e.g. the
// "ar" of "ar-EG") drives both `dir` and the matched bundle below. Bundles are
// optional: a locale with no bundle still flips to RTL and falls back to en
// strings, so a host can override copy without re-shipping a translation file.
const RTL_LANGS = ['ar', 'he', 'fa'];

export function directionFor(loc: string): 'rtl' | 'ltr' {
  return RTL_LANGS.includes(loc.toLowerCase().split('-')[0]) ? 'rtl' : 'ltr';
}

// Every locale source is untrusted input — a query param, a localStorage value
// a previous build wrote, or a server-rendered attribute. Reject anything that
// isn't BCP-47-shaped rather than letting it reach `documentElement.lang`.
const TAG_RE = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/;

function normalizeTag(raw: string | null | undefined): string | undefined {
  const tag = raw?.trim();
  return tag && TAG_RE.test(tag) ? tag : undefined;
}

/**
 * The key in `keys` serving `loc`, or undefined when none does: exact match
 * (case-insensitively), then the base subtag ("es-419" -> "es"), then the first
 * regional key sharing that base ("pt" -> "pt-BR"). Wurk::Web::LocaleNegotiator
 * walks the same three rungs server-side — they have to agree, or the hint the
 * engine emits resolves to a bundle it didn't intend.
 */
function matchTag(keys: readonly string[], loc: string): string | undefined {
  const lower = loc.toLowerCase();
  const base = lower.split('-')[0];
  return (
    keys.find((k) => k.toLowerCase() === lower) ??
    keys.find((k) => k.toLowerCase() === base) ??
    keys.find((k) => k.toLowerCase().split('-')[0] === base)
  );
}

/** The bundle key serving `loc`, or undefined when this build ships nothing for it. */
export function bundleFor(loc: string): string | undefined {
  return matchTag(availableLocales, loc);
}

function fromQuery(): string | undefined {
  return normalizeTag(new URLSearchParams(window.location.search).get(QUERY_KEY));
}

function fromStorage(): string | undefined {
  // localStorage throws SecurityError / QuotaExceededError in private mode and
  // sandboxed iframes — same guard the nav-collapsed preference uses.
  try {
    return normalizeTag(localStorage.getItem(STORAGE_KEY));
  } catch {
    return undefined;
  }
}

function fromRoot(): string | undefined {
  return normalizeTag(document.getElementById('wurk-root')?.dataset.locale);
}

// Browser preferences are a passive signal, not a choice, so only a locale we
// actually ship counts here. Honouring an unshipped one would flip a Hebrew
// browser's board to RTL with English strings for a user who never asked; the
// explicit sources above are taken verbatim precisely so that stays possible.
function fromNavigator(): string | undefined {
  const prefs = navigator.languages?.length ? navigator.languages : [navigator.language];
  for (const pref of prefs) {
    const tag = normalizeTag(pref);
    if (tag && bundleFor(tag)) return tag;
  }
  return undefined;
}

/** Highest-precedence locale source that yields a usable tag. */
export function detectLocale(): string {
  return fromQuery() ?? fromStorage() ?? fromRoot() ?? fromNavigator() ?? 'en';
}

/** Mirror a locale onto the document: `lang`, and `dir` on both html and root. */
export function applyLocale(loc: string): void {
  const direction = directionFor(loc);
  document.documentElement.lang = loc;
  document.documentElement.dir = direction;
  const root = document.getElementById('wurk-root');
  if (root) root.dir = direction;
}

/**
 * Record an explicit locale pick and reload into it. The reload is deliberate:
 * the strings resolve once per page load by design, so no consumer of `t()`
 * has to become reactive to a language change.
 */
export function setLocale(loc: string): void {
  const tag = normalizeTag(loc);
  if (!tag) return;

  let persisted = false;
  try {
    localStorage.setItem(STORAGE_KEY, tag);
    persisted = true;
  } catch {
    // Storage disabled — the query param below carries the pick instead.
  }

  applyLocale(tag);

  const url = new URL(window.location.href);
  // A leftover ?locale= from a support link out-ranks storage, so it has to go
  // once the pick is persisted; when it couldn't be, it becomes the carrier.
  if (persisted) url.searchParams.delete(QUERY_KEY);
  else url.searchParams.set(QUERY_KEY, tag);

  if (url.href === window.location.href) window.location.reload();
  else window.location.assign(url.href);
}

/**
 * Host copy overrides for `loc`, from the `#wurk-i18n` block the engine emits
 * out of `Wurk::Web.config.translations`. That payload is keyed by locale
 * rather than flat because the server's `data-locale` hint is not the last
 * word — a `?locale=` link or a stored pick outranks it — so the entry has to
 * be selected here, against the locale actually rendered, using the same match
 * that chose the bundle underneath it.
 */
function loadHostOverrides(loc: string): Bundle {
  try {
    const el = document.getElementById('wurk-i18n');
    if (!el) return {};
    const byLocale = JSON.parse(el.textContent ?? '{}') as Record<string, Bundle>;
    const key = matchTag(Object.keys(byLocale), loc);
    return key ? (byLocale[key] ?? {}) : {};
  } catch {
    return {};
  }
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
const overrides = loadHostOverrides(locale);
let merged: Translations = deepMerge(en, overrides);

async function loadBundle(): Promise<void> {
  const key = bundleFor(locale) ?? 'en';
  try {
    const { default: bundle } = await LOCALES[key]();
    merged = deepMerge(deepMerge(en, bundle), overrides);
  } catch (err) {
    // A failed chunk fetch (a deploy swapped the bundle mid-session, a proxy
    // dropped it) must not blank the dashboard: render in English instead.
    console.error(`wurk: could not load the "${key}" translations, falling back to English`, err);
  }
}

/**
 * Settles once the rendered locale's strings are in place. Never rejects.
 * main.tsx renders after it, so no visitor sees a key path or an English
 * string flash before their own language arrives.
 */
export const ready: Promise<void> = loadBundle();

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


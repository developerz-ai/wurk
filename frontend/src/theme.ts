// The theme is an attribute on <html>, never a media query: an explicit choice
// has to beat the OS preference, which is why `styles/abstracts/_tokens.scss`
// keys the light palette off `:root[data-theme='light']` and leaves dark on
// bare `:root`. This module owns the three-state preference behind that
// attribute — resolving it, persisting it, and keeping it live while the OS
// flips underneath a visitor who asked to follow the OS.
//
// The resolution is duplicated exactly once, by the pre-paint script in
// index.html: it has to run before this bundle exists, or every dark-mode
// visitor gets a white flash on every load. Change one, change the other.

const STORAGE_KEY = 'wurk.theme';

/** The two palettes `_tokens.scss` ships. `data-theme` is never anything else. */
export type Theme = 'light' | 'dark';

/** What a visitor picks. `system` defers to the OS, and is the default. */
export type ThemePreference = Theme | 'system';

declare global {
  interface Window {
    /** Host-configured default theme, injected by DashboardController. */
    __WURK_THEME__?: string;
  }
}

// Every preference source is untrusted — storage holds whatever a previous
// build or a devtools session wrote, and the injected global is host config.
// Anything unrecognized is treated as absent so the next source gets a say.
function normalize(raw: string | null | undefined): ThemePreference | undefined {
  return raw === 'light' || raw === 'dark' || raw === 'system' ? raw : undefined;
}

// The pick made during this page's life. Storage is the durable copy, but it
// can refuse the write (private mode, sandboxed iframe) and the toggle still
// has to hold for the rest of the session.
let chosen: ThemePreference | undefined;

/** The persisted pick, or undefined when there has never been one. */
export function storedPreference(): ThemePreference | undefined {
  try {
    return normalize(localStorage.getItem(STORAGE_KEY));
  } catch {
    // localStorage throws SecurityError in private mode and sandboxed iframes —
    // same guard the stored locale and zone use.
    return undefined;
  }
}

/** The host app's `Wurk::Web.config.default_theme`, when it set one. */
export function hostPreference(): ThemePreference | undefined {
  return normalize(window.__WURK_THEME__);
}

/** Highest-precedence preference source that yields one. */
export function themePreference(): ThemePreference {
  return chosen ?? storedPreference() ?? hostPreference() ?? 'system';
}

/**
 * What the OS asks for. Queried as `light` rather than `dark` so every fallback
 * — no matchMedia, no preference expressed — lands on dark, the palette that
 * lives on bare `:root`.
 */
export function systemTheme(): Theme {
  return window.matchMedia?.('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
}

/** The palette `preference` means right now. Never returns `'system'`. */
export function resolveTheme(preference: ThemePreference): Theme {
  return preference === 'system' ? systemTheme() : preference;
}

/** The palette on screen. */
export function resolvedTheme(): Theme {
  return resolveTheme(themePreference());
}

function stamp(theme: Theme): void {
  document.documentElement.dataset.theme = theme;
  // Mobile browser chrome tracks the canvas. Read back off the token rather
  // than mapped here, so each palette stays the only place its canvas is
  // named. Empty before the stylesheet loads (the pre-paint script covers that
  // window with a literal) — leave the shipped value alone rather than blank it.
  const meta = document.querySelector('meta[name="theme-color"]');
  const canvas = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
  if (meta && canvas) meta.setAttribute('content', canvas);
}

/** Paints `preference` onto the document, and reports what it resolved to. */
export function applyTheme(preference: ThemePreference = themePreference()): Theme {
  const theme = resolveTheme(preference);
  stamp(theme);
  return theme;
}

/**
 * Records an explicit pick and repaints into it. No reload, unlike the locale
 * and timezone pickers: the palette is CSS custom properties, so re-stamping
 * the attribute is the entire switch.
 */
export function setThemePreference(preference: ThemePreference): void {
  chosen = preference;
  try {
    localStorage.setItem(STORAGE_KEY, preference);
  } catch {
    // Storage disabled — `chosen` carries the pick for this page's lifetime.
  }
  applyTheme(preference);
}

let watched: MediaQueryList | undefined;

// Re-resolves rather than flipping to the OS value: under an explicit pick this
// is a no-op, which is what makes one listener safe to leave attached.
const onSystemChange = () => {
  applyTheme();
};

/**
 * Paints the current theme and keeps it live for the document's lifetime. The
 * OS listener is what makes `system` mean "follow the OS" instead of "whatever
 * the OS said at boot" — a resolve at startup alone leaves a visitor on the
 * wrong palette the moment their machine crosses sunset.
 */
export function startTheme(): void {
  applyTheme();
  if (watched) return;

  watched = window.matchMedia?.('(prefers-color-scheme: light)');
  watched?.addEventListener('change', onSystemChange);
}

// Test-only: the session pick and the OS listener are module state that
// outlives a single test case. Mirrors `__resetTick` in tick.ts.
export function __resetTheme(): void {
  watched?.removeEventListener('change', onSystemChange);
  watched = undefined;
  chosen = undefined;
}

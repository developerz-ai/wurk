const STORAGE_KEY = 'wurk.tz';

/**
 * `zone` as Intl names it, or undefined when Intl can't format in it. Every
 * zone reaching this module is untrusted — storage holds whatever a previous
 * build, another tab, or a devtools session wrote — and `Intl` throws a
 * RangeError on a name it doesn't know, out of every formatted cell on the
 * page. Resolving through a formatter both validates the name and hands back
 * the spelling Intl itself uses, so a stored `utc` still matches the `UTC`
 * entry the picker lists.
 */
function usableZone(zone: string | null | undefined): string | undefined {
  if (!zone) return undefined;
  try {
    return Intl.DateTimeFormat(undefined, { timeZone: zone }).resolvedOptions().timeZone;
  } catch {
    return undefined;
  }
}

/** The zone the runtime reports, or UTC when it won't name a usable one. */
export function browserZone(): string {
  return usableZone(Intl.DateTimeFormat().resolvedOptions().timeZone) ?? 'UTC';
}

/** The user's explicit pick, or undefined when they've never made one. */
export function storedZone(): string | undefined {
  try {
    return usableZone(localStorage.getItem(STORAGE_KEY));
  } catch {
    // localStorage throws SecurityError in private mode and sandboxed iframes —
    // same guard the stored locale uses in `i18n/index.ts`.
    return undefined;
  }
}

/** Highest-precedence zone source that yields one Intl can format in. */
export function detectTimeZone(): string {
  return storedZone() ?? browserZone();
}

/**
 * The zone every absolute timestamp renders in. Resolved once, like `locale`:
 * a change arrives by reload, so no consumer of the formatters has to become
 * reactive to it.
 */
export const timeZone = detectTimeZone();

/**
 * Record an explicit zone — or drop the override with `null`, falling back to
 * the browser's — and reload into it.
 */
export function setTimeZone(zone: string | null): void {
  const next = zone === null ? null : usableZone(zone);
  if (next === undefined) return;

  try {
    if (next === null) localStorage.removeItem(STORAGE_KEY);
    else localStorage.setItem(STORAGE_KEY, next);
  } catch {
    // Storage is disabled. Unlike a locale, a zone has no `?tz=` carrier to
    // fall back on, so the pick can't survive a reload — don't run one and
    // pretend it did.
    return;
  }
  window.location.reload();
}

let zones: readonly string[] | undefined;

/**
 * Every zone the picker offers, `UTC` first. UTC is prepended rather than
 * sorted in: `Intl.supportedValuesOf` lists canonical IANA zones only, which
 * excludes it, and it's the zone ops staff reach for when reading these times
 * against server logs.
 */
export function supportedZones(): readonly string[] {
  if (!zones) {
    // supportedValuesOf is ES2022. Where it's missing there's no way to
    // enumerate zones at all, so the picker offers the two that always resolve.
    const named =
      typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : [browserZone()];
    zones = Object.freeze(['UTC', ...named.filter((zone) => zone !== 'UTC')]);
  }
  return zones;
}

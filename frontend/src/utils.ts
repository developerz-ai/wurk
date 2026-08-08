import { locale } from './i18n';

// Intl constructors throw a RangeError on a tag they cannot parse, and the
// locale can arrive from an untrusted `?locale=` link — i18n only checks
// BCP-47 *shape*, which still admits tags Intl rejects (a repeated variant
// subtag, for one). Resolving once here keeps a bad link from throwing out of
// every formatted cell on the page.
function usableLocale(tag: string): string {
  try {
    Intl.getCanonicalLocales(tag);
    return tag;
  } catch {
    return 'en';
  }
}

const LOCALE = usableLocale(locale);

const relative = new Intl.RelativeTimeFormat(LOCALE, { numeric: 'auto' });

// How many of each unit make the next one up. The week -> month rung is the
// usual 365.2425 / 12 / 7 approximation; these numbers only pick which noun
// Intl renders, no date math downstream depends on them.
const RELATIVE_LADDER: readonly (readonly [Intl.RelativeTimeFormatUnit, number])[] = [
  ['second', 60],
  ['minute', 60],
  ['hour', 24],
  ['day', 7],
  ['week', 4.34524],
  ['month', 12],
];

export function relativeTime(epochSeconds: number): string {
  // Sorted-set entries can arrive without a usable timestamp; guard so a bad
  // value renders a dash instead of "NaNs ago".
  if (!Number.isFinite(epochSeconds)) return '—';

  // Intl's sign convention: the past is negative, the future positive.
  let value = epochSeconds - Date.now() / 1000;
  for (const [unit, perNextUnit] of RELATIVE_LADDER) {
    // Round before comparing, not after: at 59.6s the rounded value is already
    // 60, and that has to read "1 minute ago", not "60 seconds ago".
    if (Math.round(Math.abs(value)) < perNextUnit) return relative.format(Math.round(value), unit);
    value /= perNextUnit;
  }
  return relative.format(Math.round(value), 'year');
}

const dateFormatters = new Map<string, Intl.DateTimeFormat>();

function dateFormat(timeZone: string | undefined): Intl.DateTimeFormat {
  const key = timeZone ?? '';
  let formatter = dateFormatters.get(key);
  if (!formatter) {
    // An omitted `timeZone` means the runtime's own zone, which is what a
    // browser user reads clocks in.
    formatter = new Intl.DateTimeFormat(LOCALE, { timeZone, dateStyle: 'medium', timeStyle: 'medium' });
    dateFormatters.set(key, formatter);
  }
  return formatter;
}

// Both absolute renderings go through this. `new Date(NaN).toISOString()` and
// `Intl.DateTimeFormat#format(NaN)` each throw a RangeError that unmounts the
// whole table, so a missing or non-numeric epoch never reaches either.
function millis(epochSeconds: number): number | undefined {
  const ms = epochSeconds * 1000;
  return Number.isFinite(ms) ? ms : undefined;
}

/** Localized absolute timestamp, in `timeZone` or the runtime's zone. */
export function absoluteTime(epochSeconds: number, timeZone?: string): string {
  const ms = millis(epochSeconds);
  return ms === undefined ? '' : dateFormat(timeZone).format(ms);
}

/**
 * Hover-title timestamp: the localized rendering plus the UTC ISO one. Ops
 * correlate these cells against server logs, which are UTC, so trading the ISO
 * form for a localized one would be a regression — the title carries both.
 */
export function hoverTime(epochSeconds: number, timeZone?: string): string {
  const ms = millis(epochSeconds);
  return ms === undefined ? '' : `${dateFormat(timeZone).format(ms)} · ${new Date(ms).toISOString()}`;
}

const bucketFormatters = new Map<string, Intl.DateTimeFormat>();

function bucketFormat(dated: boolean, timeZone: string | undefined): Intl.DateTimeFormat {
  const key = `${dated}|${timeZone ?? ''}`;
  let formatter = bucketFormatters.get(key);
  if (!formatter) {
    // `dated` buckets (hourly rollups) need the date to disambiguate across
    // midnight; finer rollups fit a whole chart axis in HH:MM alone.
    formatter = dated
      ? new Intl.DateTimeFormat(LOCALE, { timeZone, month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false })
      : new Intl.DateTimeFormat(LOCALE, { timeZone, hour: '2-digit', minute: '2-digit', hour12: false });
    bucketFormatters.set(key, formatter);
  }
  return formatter;
}

/** Chart-axis / table bucket label, in `timeZone` or the runtime's zone. */
export function formatBucket(epochSeconds: number, bucket: string, timeZone?: string): string {
  const ms = millis(epochSeconds);
  return ms === undefined ? '' : bucketFormat(bucket === '1h', timeZone).format(ms);
}

const numberFormatter = new Intl.NumberFormat(LOCALE);

/** Locale-aware thousands grouping for a plain count. */
export function formatNumber(n: number): string {
  return numberFormatter.format(n);
}

/** Current time in epoch seconds — one call site for every `Date.now()/1000`. */
export function nowSeconds(): number {
  return Date.now() / 1000;
}

const unitFormatters = new Map<string, Intl.NumberFormat>();

function unit(name: string, value: number, unitDisplay: 'narrow' | 'short', digits = 0): string {
  const key = `${name}|${unitDisplay}|${digits}`;
  let formatter = unitFormatters.get(key);
  if (!formatter) {
    formatter = new Intl.NumberFormat(LOCALE, {
      style: 'unit',
      unit: name,
      unitDisplay,
      minimumFractionDigits: digits,
      maximumFractionDigits: digits,
    });
    unitFormatters.set(key, formatter);
  }
  return formatter.format(value);
}

// Human-readable duration from float seconds: "850ms", "4.2s", "21m 49s",
// "2h 5m", "3d 4h". Used for queue latency, which the API reports in seconds.
// Narrow units keep the two-part forms short enough for a table cell; Intl has
// no composite duration, so each part is formatted on its own and joined —
// never spelled with raw letters, which would stay English in all 8 locales.
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds)) return '—';
  const s = Math.abs(seconds);
  if (s < 1) return unit('millisecond', Math.round(s * 1000), 'narrow');
  if (s < 10) return unit('second', s, 'narrow', 1);
  const total = Math.round(s);
  if (total < 60) return unit('second', total, 'narrow');
  if (total < 3600) {
    return `${unit('minute', Math.floor(total / 60), 'narrow')} ${unit('second', total % 60, 'narrow')}`;
  }
  if (total < 86400) {
    return `${unit('hour', Math.floor(total / 3600), 'narrow')} ${unit('minute', Math.floor((total % 3600) / 60), 'narrow')}`;
  }
  return `${unit('day', Math.floor(total / 86400), 'narrow')} ${unit('hour', Math.floor((total % 86400) / 3600), 'narrow')}`;
}

// RSS and total memory arrive from the heartbeat as kilobytes. Short units
// here, not narrow: a size reads as "512 MB", and narrow drops the space.
export function formatKb(kb: number): string {
  if (!Number.isFinite(kb) || kb <= 0) return '—';
  if (kb < 1024) return unit('kilobyte', Math.round(kb), 'short');
  const mb = kb / 1024;
  if (mb < 1024) return unit('megabyte', Math.round(mb), 'short');
  return unit('gigabyte', mb / 1024, 'short', 1);
}

export function truncate(s: string | null | undefined, max = 80): string {
  if (s == null) return '';
  if (s.length <= max) return s;
  return s.slice(0, max) + '…';
}

export function formatArgs(args: unknown): string {
  try {
    return JSON.stringify(args);
  } catch {
    return String(args);
  }
}

export function usePageTitle(title: string) {
  document.title = `${title} — Wurk`;
}

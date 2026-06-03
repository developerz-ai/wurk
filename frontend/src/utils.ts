export function relativeTime(epochSeconds: number): string {
  // Sorted-set entries can arrive without a usable timestamp; guard so a bad
  // value renders a dash instead of "NaNs ago".
  if (!Number.isFinite(epochSeconds)) return '—';

  const now = Date.now() / 1000;
  const diff = now - epochSeconds;
  const absDiff = Math.abs(diff);
  const future = diff < 0;

  let value: string;
  if (absDiff < 60) {
    value = `${Math.round(absDiff)}s`;
  } else if (absDiff < 3600) {
    value = `${Math.round(absDiff / 60)}m`;
  } else if (absDiff < 86400) {
    value = `${Math.round(absDiff / 3600)}h`;
  } else {
    value = `${Math.round(absDiff / 86400)}d`;
  }

  return future ? `${value} from now` : `${value} ago`;
}

// ISO timestamp for hover titles. `new Date(NaN).toISOString()` throws a
// RangeError that unmounts the whole table; returning '' keeps the cell safe
// when the epoch is missing or non-numeric.
export function isoTime(epochSeconds: number): string {
  const ms = epochSeconds * 1000;
  if (!Number.isFinite(ms)) return '';
  return new Date(ms).toISOString();
}

export function truncate(s: string, max = 80): string {
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

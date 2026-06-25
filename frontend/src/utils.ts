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

// Human-readable duration from float seconds: "850ms", "4.2s", "21m 49s",
// "2h 5m", "3d 4h". Used for queue latency, which the API reports in seconds.
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds)) return '—';
  const s = Math.abs(seconds);
  if (s < 1) return `${Math.round(s * 1000)}ms`;
  if (s < 10) return `${s.toFixed(1)}s`;
  const total = Math.round(s);
  if (total < 60) return `${total}s`;
  if (total < 3600) return `${Math.floor(total / 60)}m ${total % 60}s`;
  if (total < 86400) return `${Math.floor(total / 3600)}h ${Math.floor((total % 3600) / 60)}m`;
  return `${Math.floor(total / 86400)}d ${Math.floor((total % 86400) / 3600)}h`;
}

// RSS and total memory arrive from the heartbeat as kilobytes.
export function formatKb(kb: number): string {
  if (!Number.isFinite(kb) || kb <= 0) return '—';
  if (kb < 1024) return `${Math.round(kb)} KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${Math.round(mb)} MB`;
  return `${(mb / 1024).toFixed(1)} GB`;
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

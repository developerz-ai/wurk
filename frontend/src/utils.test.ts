import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { relativeTime, absoluteTime, hoverTime, formatDuration, formatKb, truncate } from './utils';

// Fixed instant so every ladder rung lands on a deterministic value; jsdom
// resolves navigator.language to en-US, so unqualified expectations are English.
const NOW = new Date('2026-08-08T12:00:00Z');
const EPOCH = NOW.getTime() / 1000;

describe('relativeTime', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
  });
  afterEach(() => vi.useRealTimers());

  const ago = (seconds: number) => relativeTime(EPOCH - seconds);
  const ahead = (seconds: number) => relativeTime(EPOCH + seconds);

  it('guards a timestamp that never arrived', () => {
    expect(relativeTime(NaN)).toBe('—');
    expect(relativeTime(Infinity)).toBe('—');
  });

  it('walks the ladder from seconds to years', () => {
    expect(ago(0)).toBe('now');
    expect(ago(45)).toBe('45 seconds ago');
    expect(ago(170)).toBe('3 minutes ago');
    expect(ago(3 * 3600)).toBe('3 hours ago');
    expect(ago(2 * 86400)).toBe('2 days ago');
    expect(ago(21 * 86400)).toBe('3 weeks ago');
    expect(ago(100 * 86400)).toBe('3 months ago');
    expect(ago(800 * 86400)).toBe('2 years ago');
  });

  // The whole point of the ladder: the old formatter stopped at days, so a dead
  // job from last spring read "400d ago".
  it('never reports a year-old job in days', () => {
    expect(ago(400 * 86400)).toBe('last year');
  });

  it('reads the future forwards', () => {
    expect(ahead(150)).toBe('in 3 minutes');
    expect(ahead(86400)).toBe('tomorrow');
    expect(ahead(3 * 86400)).toBe('in 3 days');
  });

  // Rounding happens before the unit is chosen, so the top of a rung rolls into
  // the next one instead of rendering "60 seconds ago".
  it('rolls a rounded value up to the next unit', () => {
    expect(ago(59.4)).toBe('59 seconds ago');
    expect(ago(59.6)).toBe('1 minute ago');
    expect(ago(3599.6)).toBe('1 hour ago');
  });
});

// The formatters resolve their locale once at module scope, the same way the
// bundle does, so a locale-specific expectation needs a fresh module registry.
async function utilsIn(loc: string) {
  const root = document.createElement('div');
  root.id = 'wurk-root';
  root.dataset.locale = loc;
  document.body.appendChild(root);
  vi.resetModules();
  return import('./utils');
}

describe('locale-aware formatting', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
  });
  afterEach(() => {
    vi.useRealTimers();
    document.getElementById('wurk-root')?.remove();
    vi.resetModules();
  });

  it('translates relative time instead of appending English " ago"', async () => {
    const de = await utilsIn('de');
    expect(de.relativeTime(EPOCH - 3 * 3600)).toBe('vor 3 Stunden');
    expect(de.relativeTime(EPOCH + 86400)).toBe('morgen');
  });

  it('renders a locale with different grammar entirely', async () => {
    const ja = await utilsIn('ja');
    expect(ja.relativeTime(EPOCH - 3 * 3600)).toBe('3 時間前');
    expect(ja.relativeTime(EPOCH - 86400)).toBe('昨日');
  });

  // Digit shape is engine-dependent for Arabic (JavaScriptCore renders
  // Arabic-Indic, V8 Latin), so this pins the words, not the numerals.
  it('renders RTL copy for an RTL locale', async () => {
    const ar = await utilsIn('ar');
    expect(ar.relativeTime(EPOCH - 3 * 3600)).toContain('ساعات');
    expect(ar.relativeTime(EPOCH - 86400)).toBe('أمس');
  });

  it('localizes duration and size units', async () => {
    const de = await utilsIn('de');
    expect(de.formatDuration(1309.324)).toBe('21 Min. 49 Sek.');
    // German separates value from unit with a no-break space, hence the \s.
    expect(de.formatKb(16777216)).toMatch(/^16,0\sGB$/);
  });

  it('formats dates in the locale, not just the zone', async () => {
    const ja = await utilsIn('ja');
    expect(ja.absoluteTime(Date.UTC(2026, 1, 2, 2, 40) / 1000, 'Asia/Tokyo')).toBe('2026/02/02 11:40:00');
  });

  // i18n only validates BCP-47 shape, and `?locale=` is untrusted: this tag is
  // shape-valid but Intl rejects it (repeated variant subtag). Falling back
  // beats throwing out of every formatted cell on the page.
  it('falls back to English for a tag Intl refuses', async () => {
    const bogus = await utilsIn('en-aaaaa-aaaaa');
    expect(bogus.relativeTime(EPOCH - 3 * 3600)).toBe('3 hours ago');
    expect(bogus.formatDuration(1309.324)).toBe('21m 49s');
  });
});

describe('absoluteTime', () => {
  // 2026-02-02T02:40:00Z — the same instant is the previous evening in New York
  // and the same morning in Tokyo.
  const AT = Date.UTC(2026, 1, 2, 2, 40) / 1000;

  it('guards a timestamp that never arrived', () => {
    expect(absoluteTime(NaN)).toBe('');
    expect(absoluteTime(Infinity)).toBe('');
  });

  it('renders the requested zone', () => {
    expect(absoluteTime(AT, 'UTC')).toMatch(/^Feb 2, 2026, 2:40:00\sAM$/);
    expect(absoluteTime(AT, 'America/New_York')).toMatch(/^Feb 1, 2026, 9:40:00\sPM$/);
    expect(absoluteTime(AT, 'Asia/Tokyo')).toMatch(/^Feb 2, 2026, 11:40:00\sAM$/);
  });

  it('defaults to the runtime zone', () => {
    expect(absoluteTime(AT)).toBe(absoluteTime(AT, Intl.DateTimeFormat().resolvedOptions().timeZone));
  });

  // 05:30 UTC on 2026-11-01 is inside the hour New York repeats when DST ends.
  it('formats an ambiguous DST hour without throwing', () => {
    expect(absoluteTime(Date.UTC(2026, 10, 1, 5, 30) / 1000, 'America/New_York')).toMatch(
      /^Nov 1, 2026, 1:30:00\sAM$/,
    );
  });
});

describe('hoverTime', () => {
  const AT = Date.UTC(2026, 1, 2, 2, 40) / 1000;

  // `new Date(NaN).toISOString()` throws a RangeError, which unmounted the
  // whole table when a sorted-set entry arrived without a score.
  it('guards a timestamp that never arrived', () => {
    expect(hoverTime(NaN)).toBe('');
    expect(hoverTime(Infinity)).toBe('');
  });

  // Ops read these titles against UTC server logs, so the ISO form has to
  // survive alongside the localized one.
  it('carries the local rendering and the UTC ISO string', () => {
    const title = hoverTime(AT, 'America/New_York');
    expect(title).toMatch(/^Feb 1, 2026, 9:40:00\sPM · 2026-02-02T02:40:00\.000Z$/);
  });
});

describe('formatDuration', () => {
  it('guards non-finite input', () => {
    expect(formatDuration(NaN)).toBe('—');
    expect(formatDuration(Infinity)).toBe('—');
  });

  it('renders sub-second latencies as milliseconds', () => {
    expect(formatDuration(0.024)).toBe('24ms');
    expect(formatDuration(0.5)).toBe('500ms');
  });

  it('keeps one decimal under ten seconds', () => {
    expect(formatDuration(4.25)).toBe('4.3s');
  });

  it('renders whole seconds under a minute', () => {
    expect(formatDuration(42.4)).toBe('42s');
  });

  it('renders minutes and seconds', () => {
    expect(formatDuration(1309.324)).toBe('21m 49s');
  });

  it('rolls 59.7s in a minute branch without showing 60s', () => {
    expect(formatDuration(1319.7)).toBe('22m 0s');
  });

  it('renders hours and minutes', () => {
    expect(formatDuration(7500)).toBe('2h 5m');
  });

  it('renders days and hours', () => {
    expect(formatDuration(200000)).toBe('2d 7h');
  });
});

describe('formatKb', () => {
  it('dashes missing or zero values', () => {
    expect(formatKb(0)).toBe('—');
    expect(formatKb(NaN)).toBe('—');
  });

  // "kB" is CLDR's English kilobyte symbol — the unit comes from Intl now, not
  // from a hand-written letter.
  it('scales KB → MB → GB', () => {
    expect(formatKb(500)).toBe('500 kB');
    expect(formatKb(524288)).toBe('512 MB');
    expect(formatKb(16777216)).toBe('16.0 GB');
  });
});

describe('truncate', () => {
  // Killed/migrated dead jobs carry null error_class/error_message; the dead-row
  // map fed those straight in and null.length white-screened /dead (issue #272).
  it('renders null/undefined as empty string instead of throwing', () => {
    expect(truncate(null)).toBe('');
    expect(truncate(undefined)).toBe('');
  });

  it('passes short strings through and ellipsizes long ones', () => {
    expect(truncate('short', 25)).toBe('short');
    expect(truncate('x'.repeat(30), 25)).toBe(`${'x'.repeat(25)}…`);
  });
});

import { describe, it, expect } from 'vitest';
import { formatDuration, formatKb, truncate } from './utils';

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

  it('scales KB → MB → GB', () => {
    expect(formatKb(500)).toBe('500 KB');
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

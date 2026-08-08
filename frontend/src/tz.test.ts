import { describe, it, expect, vi, afterEach } from 'vitest';
import { browserZone, detectTimeZone, setTimeZone, storedZone, supportedZones } from './tz';

const KEY = 'wurk.tz';
// Whatever zone the test runner boots in — asserted against rather than pinned,
// so the suite reads the same on a laptop in Berlin and on a UTC CI runner.
const RUNTIME_ZONE = Intl.DateTimeFormat().resolvedOptions().timeZone;

// jsdom's Location is unforgeable, so the reload `setTimeZone` ends on can't be
// stubbed or observed here; these assert what it persists on the way there.
afterEach(() => {
  localStorage.clear();
  vi.restoreAllMocks();
});

describe('browserZone', () => {
  it('reports the zone the runtime resolves', () => {
    expect(browserZone()).toBe(RUNTIME_ZONE);
  });

  it('falls back to UTC when the runtime names no zone', () => {
    vi.spyOn(Intl, 'DateTimeFormat').mockReturnValue({
      resolvedOptions: () => ({ timeZone: undefined }),
    } as unknown as Intl.DateTimeFormat);

    expect(browserZone()).toBe('UTC');
  });
});

describe('storedZone', () => {
  it('returns the persisted pick', () => {
    localStorage.setItem(KEY, 'Asia/Tokyo');
    expect(storedZone()).toBe('Asia/Tokyo');
  });

  it('returns the spelling Intl uses, so a stored alias still matches the list', () => {
    localStorage.setItem(KEY, 'utc');
    expect(storedZone()).toBe('UTC');
  });

  it('ignores a zone Intl cannot format in rather than throwing out of it', () => {
    localStorage.setItem(KEY, 'Not/AZone');
    expect(() => storedZone()).not.toThrow();
    expect(storedZone()).toBeUndefined();
  });

  it('ignores storage that refuses to be read', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new DOMException('denied', 'SecurityError');
    });

    expect(storedZone()).toBeUndefined();
  });
});

describe('detectTimeZone', () => {
  it('prefers the stored pick over the browser zone', () => {
    localStorage.setItem(KEY, 'America/New_York');
    expect(detectTimeZone()).toBe('America/New_York');
  });

  it('falls back to the browser zone when nothing is stored', () => {
    expect(detectTimeZone()).toBe(RUNTIME_ZONE);
  });

  it('falls back to the browser zone when the stored one is unusable', () => {
    localStorage.setItem(KEY, 'Mars/Olympus_Mons');
    expect(detectTimeZone()).toBe(RUNTIME_ZONE);
  });

  it('resolves the module-scope zone from the stored pick', async () => {
    localStorage.setItem(KEY, 'Asia/Tokyo');
    vi.resetModules();

    const mod = await import('./tz');
    expect(mod.timeZone).toBe('Asia/Tokyo');
  });
});

describe('setTimeZone', () => {
  it('persists an explicit pick', () => {
    setTimeZone('Europe/Berlin');
    expect(localStorage.getItem(KEY)).toBe('Europe/Berlin');
  });

  it('drops the override when cleared, falling back to the browser zone', () => {
    localStorage.setItem(KEY, 'Europe/Berlin');
    setTimeZone(null);

    expect(localStorage.getItem(KEY)).toBeNull();
    expect(detectTimeZone()).toBe(RUNTIME_ZONE);
  });

  it('refuses a zone Intl cannot format in, leaving the current pick alone', () => {
    localStorage.setItem(KEY, 'Europe/Berlin');
    setTimeZone('Not/AZone');

    expect(localStorage.getItem(KEY)).toBe('Europe/Berlin');
  });

  it('gives up quietly when storage refuses the write', () => {
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new DOMException('quota', 'QuotaExceededError');
    });

    expect(() => setTimeZone('Europe/Berlin')).not.toThrow();
  });
});

describe('supportedZones', () => {
  it('offers UTC first — Intl does not list it, and ops read logs in it', () => {
    expect(supportedZones()[0]).toBe('UTC');
    expect(supportedZones().filter((zone) => zone === 'UTC')).toHaveLength(1);
  });

  it('offers the IANA zones Intl knows', () => {
    expect(supportedZones()).toContain('America/New_York');
    expect(supportedZones()).toContain('Asia/Tokyo');
  });

  it('builds the list once', () => {
    expect(supportedZones()).toBe(supportedZones());
  });

  it('degrades to the zones that always resolve where Intl cannot enumerate', async () => {
    const supported = Intl.supportedValuesOf;
    // @ts-expect-error modelling a runtime older than ES2022 (Safari < 15.4).
    delete Intl.supportedValuesOf;
    vi.resetModules();

    try {
      const mod = await import('./tz');
      expect(mod.supportedZones()).toEqual(['UTC', RUNTIME_ZONE].filter((z, i, a) => a.indexOf(z) === i));
    } finally {
      Intl.supportedValuesOf = supported;
    }
  });
});

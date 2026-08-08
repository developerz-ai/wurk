import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  __resetTheme,
  applyTheme,
  hostPreference,
  resolveTheme,
  resolvedTheme,
  setThemePreference,
  startTheme,
  storedPreference,
  systemTheme,
  themePreference,
} from './theme';

const KEY = 'wurk.theme';

/** A `prefers-color-scheme: light` query the test drives, listeners and all. */
function stubSystemLight(matches: boolean) {
  const handlers = new Set<() => void>();
  const mq = {
    matches,
    addEventListener: (_: string, fn: () => void) => handlers.add(fn),
    removeEventListener: (_: string, fn: () => void) => handlers.delete(fn),
  };
  vi.stubGlobal('matchMedia', vi.fn().mockReturnValue(mq));
  return {
    /** Flip the OS preference the way an OS sunset schedule does. */
    flip(next: boolean) {
      mq.matches = next;
      handlers.forEach((fn) => fn());
    },
    get listeners() {
      return handlers.size;
    },
  };
}

afterEach(() => {
  __resetTheme();
  localStorage.clear();
  delete window.__WURK_THEME__;
  delete document.documentElement.dataset.theme;
  document.head.innerHTML = '';
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('themePreference', () => {
  it('defaults to system', () => {
    expect(themePreference()).toBe('system');
  });

  it('prefers the stored pick over the host default', () => {
    window.__WURK_THEME__ = 'light';
    localStorage.setItem(KEY, 'dark');

    expect(themePreference()).toBe('dark');
  });

  it('prefers the host default over the system fallback', () => {
    window.__WURK_THEME__ = 'light';

    expect(themePreference()).toBe('light');
  });

  it('ignores a stored value it does not recognise', () => {
    localStorage.setItem(KEY, 'obsidian');

    expect(storedPreference()).toBeUndefined();
    expect(themePreference()).toBe('system');
  });

  it('ignores a host default it does not recognise', () => {
    window.__WURK_THEME__ = 'auto';

    expect(hostPreference()).toBeUndefined();
    expect(themePreference()).toBe('system');
  });

  it('ignores storage that refuses to be read', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new DOMException('denied', 'SecurityError');
    });

    expect(themePreference()).toBe('system');
  });
});

describe('systemTheme', () => {
  it('reads light off the OS preference', () => {
    stubSystemLight(true);

    expect(systemTheme()).toBe('light');
  });

  it('falls back to dark — the palette on bare :root — when the OS asks for nothing', () => {
    stubSystemLight(false);

    expect(systemTheme()).toBe('dark');
  });

  it('falls back to dark where matchMedia does not exist', () => {
    vi.stubGlobal('matchMedia', undefined);

    expect(systemTheme()).toBe('dark');
  });
});

describe('resolveTheme', () => {
  it('never yields system', () => {
    stubSystemLight(true);

    expect(resolveTheme('system')).toBe('light');
    expect(resolveTheme('dark')).toBe('dark');
    expect(resolveTheme('light')).toBe('light');
  });

  it('leaves an explicit pick alone whatever the OS asks for', () => {
    stubSystemLight(true);
    localStorage.setItem(KEY, 'dark');

    expect(resolvedTheme()).toBe('dark');
  });
});

describe('applyTheme', () => {
  it('stamps the resolved theme, never the preference', () => {
    stubSystemLight(true);

    expect(applyTheme('system')).toBe('light');
    expect(document.documentElement.dataset.theme).toBe('light');
  });

  it('tracks the canvas token onto theme-color for the browser chrome', () => {
    document.head.innerHTML = '<meta name="theme-color" content="#09090b">';
    vi.spyOn(window, 'getComputedStyle').mockReturnValue({
      getPropertyValue: () => ' #fafafa ',
    } as unknown as CSSStyleDeclaration);

    applyTheme('light');

    expect(document.querySelector('meta[name="theme-color"]')?.getAttribute('content')).toBe('#fafafa');
  });

  it('leaves theme-color alone when the stylesheet has no value to read', () => {
    document.head.innerHTML = '<meta name="theme-color" content="#09090b">';

    applyTheme('light');

    expect(document.querySelector('meta[name="theme-color"]')?.getAttribute('content')).toBe('#09090b');
  });
});

describe('setThemePreference', () => {
  it('persists the pick and repaints into it', () => {
    setThemePreference('light');

    expect(localStorage.getItem(KEY)).toBe('light');
    expect(document.documentElement.dataset.theme).toBe('light');
    expect(themePreference()).toBe('light');
  });

  it('holds the pick for the session when storage refuses the write', () => {
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new DOMException('quota', 'QuotaExceededError');
    });

    setThemePreference('light');

    expect(themePreference()).toBe('light');
    expect(document.documentElement.dataset.theme).toBe('light');
  });
});

describe('startTheme', () => {
  it('paints the resolved theme up front', () => {
    stubSystemLight(true);
    startTheme();

    expect(document.documentElement.dataset.theme).toBe('light');
  });

  it('follows the OS live, not only at boot', () => {
    const os = stubSystemLight(false);
    startTheme();
    expect(document.documentElement.dataset.theme).toBe('dark');

    os.flip(true);

    expect(document.documentElement.dataset.theme).toBe('light');
  });

  it('leaves an explicit pick alone when the OS flips', () => {
    const os = stubSystemLight(false);
    setThemePreference('dark');
    startTheme();

    os.flip(true);

    expect(document.documentElement.dataset.theme).toBe('dark');
  });

  it('subscribes once however often it is called', () => {
    const os = stubSystemLight(false);
    startTheme();
    startTheme();

    expect(os.listeners).toBe(1);
  });
});

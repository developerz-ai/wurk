import { describe, it, expect, afterEach, vi } from 'vitest';
import { t, directionFor } from './index';

describe('t()', () => {
  it('resolves a nested key path', () => {
    expect(t('nav.dashboard')).toBe('Dashboard');
    expect(t('busy.heartbeat')).toBe('Heartbeat');
  });

  it('interpolates {var} placeholders', () => {
    expect(t('busy.hosts', { n: 3 })).toBe('3 hosts');
    expect(t('actions.selected', { n: 7 })).toBe('7 selected');
    expect(t('actions.confirm', { action: 'Retry', scope: 'this job' })).toBe(
      'Retry this job? This cannot be undone.',
    );
  });

  it('leaves placeholders untouched when no vars are given', () => {
    expect(t('busy.hosts')).toBe('{n} hosts');
  });

  it('returns the path when the key is missing', () => {
    expect(t('nope.not.here')).toBe('nope.not.here');
    // A path that resolves to an object (not a leaf string) also falls back.
    expect(t('nav')).toBe('nav');
  });
});

describe('directionFor()', () => {
  it('flips RTL languages', () => {
    expect(directionFor('ar')).toBe('rtl');
    expect(directionFor('he')).toBe('rtl');
    expect(directionFor('fa')).toBe('rtl');
    // The base subtag drives direction, so region-tagged locales still flip.
    expect(directionFor('ar-EG')).toBe('rtl');
  });

  it('leaves LTR languages alone', () => {
    expect(directionFor('en')).toBe('ltr');
    expect(directionFor('de')).toBe('ltr');
    expect(directionFor('zh-CN')).toBe('ltr');
  });
});

describe('host overrides', () => {
  afterEach(() => {
    document.getElementById('wurk-i18n')?.remove();
    vi.resetModules();
  });

  it('deep-merges a #wurk-i18n script tag over the base bundle', async () => {
    const el = document.createElement('script');
    el.id = 'wurk-i18n';
    el.type = 'application/json';
    // Override one leaf; siblings and untouched branches must survive the merge.
    el.textContent = JSON.stringify({ nav: { dashboard: 'Control Center' } });
    document.head.appendChild(el);

    // The bundle reads the override at module-eval time, so re-evaluate it with
    // the script tag present.
    vi.resetModules();
    const mod = await import('./index');
    expect(mod.t('nav.dashboard')).toBe('Control Center');
    expect(mod.t('nav.queues')).toBe('Queues');
  });
});

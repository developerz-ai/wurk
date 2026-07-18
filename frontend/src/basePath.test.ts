import { describe, it, expect, afterEach } from 'vitest';
import { basePath } from './basePath';

describe('basePath', () => {
  afterEach(() => {
    delete window.__WURK_BASE__;
  });

  it('falls back to /wurk when the server injected nothing (Vite dev)', () => {
    expect(basePath()).toBe('/wurk');
  });

  it('reads the injected mount prefix', () => {
    window.__WURK_BASE__ = '/sidekiq';
    expect(basePath()).toBe('/sidekiq');
  });

  it('supports a nested mount path', () => {
    window.__WURK_BASE__ = '/admin/jobs';
    expect(basePath()).toBe('/admin/jobs');
  });

  it('strips a trailing slash so callers can concatenate', () => {
    window.__WURK_BASE__ = '/sidekiq/';
    expect(basePath()).toBe('/sidekiq');
  });

  it('returns "" for a root mount so URLs stay absolute', () => {
    window.__WURK_BASE__ = '';
    expect(basePath()).toBe('');
  });
});

import { describe, it, expect } from 'vitest';
import { healthNotices, type NoticeProcess, type NoticeQueue } from './HealthNotices';
import { t } from '../i18n';

const wurk = (identity: string, extra: Partial<NoticeProcess> = {}): NoticeProcess => ({
  identity,
  version: '1.14.0',
  cores: 8,
  embedded: false,
  ...extra,
});
const queue = (name: string, extra: Partial<NoticeQueue> = {}): NoticeQueue => ({
  name,
  size: 5,
  paused: false,
  consumers: 1,
  ...extra,
});

describe('healthNotices', () => {
  it('is silent for a healthy fleet', () => {
    expect(healthNotices([wurk('a'), wurk('b')], [queue('default'), queue('idle', { size: 0, consumers: 0 })])).toEqual([]);
  });

  it('is silent with no processes at all (the dashboard already shows zero)', () => {
    expect(healthNotices([], [queue('default', { consumers: 0 })])).toEqual([]);
  });

  it('flags queues holding jobs that no live process consumes, unless paused', () => {
    const notices = healthNotices(
      [wurk('a')],
      [queue('orphan', { consumers: 0 }), queue('paused', { consumers: 0, paused: true }), queue('default')],
    );
    expect(notices).toEqual([
      { key: 'unconsumed', level: 'warning', href: '/queues', message: t('notices.unconsumed', { names: 'orphan' }) },
    ]);
  });

  it('flags a Sidekiq process by its missing `cores`, the rule wurk verify uses', () => {
    const notices = healthNotices([wurk('a'), { identity: 'sk:1', version: '7.3.0' }], [queue('default')]);
    expect(notices.map((n) => n.key)).toEqual(['foreign']);
    expect(notices[0].message).toBe(t('notices.foreign', { names: 'sk:1' }));
  });

  it('flags a mixed Wurk fleet, ignoring foreign versions', () => {
    const notices = healthNotices([wurk('a'), wurk('b', { version: '1.13.0' })], [queue('default')]);
    expect(notices.map((n) => n.key)).toEqual(['mixed']);
    expect(notices[0].message).toBe(t('notices.mixed', { versions: '1.13.0, 1.14.0' }));
  });

  it('notes embedded processes as info', () => {
    const notices = healthNotices([wurk('a', { embedded: true }), wurk('b', { embedded: true })], [queue('default')]);
    expect(notices).toEqual([
      { key: 'embedded', level: 'info', href: '/busy', message: t('notices.embedded', { n: 2 }) },
    ]);
  });

  it('caps a long name list', () => {
    const queues = Array.from({ length: 7 }, (_, i) => queue(`q${i}`, { consumers: 0 }));
    expect(healthNotices([wurk('a')], queues)[0].message).toBe(
      t('notices.unconsumed', { names: 'q0, q1, q2, q3, q4 +2' }),
    );
  });
});

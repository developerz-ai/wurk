import { useQuery } from '@tanstack/solid-query';
import { For, Show } from 'solid-js';
import { A } from '@solidjs/router';
import { basePath } from '../basePath';
import { getJSON } from '../http';
import { t } from '../i18n';
import Icon from './Icon';

// The fields of GET /api/processes and GET /api/queues these checks read.
export interface NoticeProcess {
  identity: string;
  version?: string;
  // Only Wurk's heartbeat carries `cores`; `wurk verify` tells a Wurk process
  // from a real Sidekiq one the same way (lib/wurk/preflight/owners.rb).
  cores?: number | null;
  embedded?: boolean;
}

export interface NoticeQueue {
  name: string;
  size: number;
  paused: boolean;
  consumers?: number;
}

export interface HealthNotice {
  key: string;
  level: 'warning' | 'info';
  message: string;
  href?: string;
}

const LIST_MAX = 5;
const list = (names: string[]) =>
  names.length > LIST_MAX ? `${names.slice(0, LIST_MAX).join(', ')} +${names.length - LIST_MAX}` : names.join(', ');

// The fleet conditions `wurk verify` warns about that a dashboard can see from
// data it already serves: jobs no live process will ever fetch, Sidekiq
// processes still sharing the Redis, a fleet on more than one version, and
// workers running inside a web server.
export function healthNotices(processes: NoticeProcess[], queues: NoticeQueue[]): HealthNotice[] {
  const notices: HealthNotice[] = [];
  if (processes.length === 0) return notices;

  const unconsumed = queues.filter((q) => q.size > 0 && !q.paused && q.consumers === 0).map((q) => q.name);
  if (unconsumed.length > 0) {
    notices.push({ key: 'unconsumed', level: 'warning', href: '/queues', message: t('notices.unconsumed', { names: list(unconsumed) }) });
  }

  const foreign = processes.filter((p) => p.cores == null).map((p) => p.identity);
  if (foreign.length > 0) {
    notices.push({ key: 'foreign', level: 'warning', href: '/busy', message: t('notices.foreign', { names: list(foreign) }) });
  }

  const versions = [...new Set(processes.filter((p) => p.cores != null && p.version).map((p) => p.version!))].sort();
  if (versions.length > 1) {
    notices.push({ key: 'mixed', level: 'warning', href: '/busy', message: t('notices.mixed', { versions: versions.join(', ') }) });
  }

  const embedded = processes.filter((p) => p.embedded).length;
  if (embedded > 0) {
    notices.push({ key: 'embedded', level: 'info', href: '/busy', message: t('notices.embedded', { n: embedded }) });
  }
  return notices;
}

const REFRESH_MS = 30_000;

// The Dashboard's "Health notices" strip. Renders nothing while all is well.
export function HealthNotices() {
  const processes = useQuery(() => ({
    queryKey: ['processes'],
    queryFn: () => getJSON<NoticeProcess[]>(`${basePath()}/api/processes`),
    refetchInterval: REFRESH_MS,
  }));
  const queues = useQuery(() => ({
    queryKey: ['queues'],
    queryFn: () => getJSON<NoticeQueue[]>(`${basePath()}/api/queues`),
    refetchInterval: REFRESH_MS,
  }));
  const notices = () =>
    Array.isArray(processes.data) && Array.isArray(queues.data) ? healthNotices(processes.data, queues.data) : [];

  return (
    <Show when={notices().length > 0}>
      <section class="health-notices" aria-label={t('notices.title')}>
        <For each={notices()}>
          {(n) => (
            <div class={`health-notice health-notice--${n.level}`} role="status">
              <Icon name={n.level === 'warning' ? 'triangle-exclamation' : 'circle-info'} />
              <span>{n.message}</span>
              <Show when={n.href}>
                <A class="health-notice__link" href={n.href!}>
                  {t('dashboard.viewAll')} <Icon name="arrow-right" />
                </A>
              </Show>
            </div>
          )}
        </For>
      </section>
    </Show>
  );
}

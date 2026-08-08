import { useQuery } from '@tanstack/solid-query';
import { onMount, For, Switch, Match, Show } from 'solid-js';
import { SkeletonTable } from '../components/Skeleton';
import { t } from '../i18n';
import { absoluteTime, formatNumber, hoverTime } from '../utils';
import { timeZone } from '../tz';
import { basePath } from '../basePath';

// One row from GET <mount>/api/profiles (Wurk::Api::Serializers.profile_record).
interface Profile {
  key: string;
  jid: string;
  token: string;
  type: string;
  size: number;
  elapsed: number;
  started_at: number | null;
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

export default function Profiles() {
  onMount(() => {
    document.title = `${t('nav.profiles')} — Wurk`;
  });

  const q = useQuery<Profile[]>(() => ({
    queryKey: ['profiles'],
    queryFn: async () => {
      const r = await fetch(`${basePath()}/api/profiles`);
      if (!r.ok) throw new Error(`profiles request failed: ${r.status}`);
      return r.json() as Promise<Profile[]>;
    },
    refetchInterval: 5000,
  }));

  return (
    <Switch>
      <Match when={q.isPending}>
        <div class="obs"><SkeletonTable rows={8} cols={6} /></div>
      </Match>
      {/* Only gate on shape, not isError — with refetchInterval polling, a transient
          background refetch failure flips isError true while the last good payload
          is still cached. Showing the error state then would blank the page on
          every blip; falling through keeps stale data visible until the next poll. */}
      <Match when={!Array.isArray(q.data)}>
        <div class="obs"><div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div></div>
      </Match>
      <Match when={Array.isArray(q.data) && q.data}>
        {(data) => (
          <div class="obs">
            <div class="obs-pagehead">
              <div>
                <h1>{t('nav.profiles')}</h1>
                <p class="obs-panel__sub">{t('summaries.profiles')}</p>
              </div>
              <span class="obs-chip obs-chip--active">{formatNumber(data().length)}</span>
            </div>

            <Show
              when={data().length > 0}
              fallback={<div class="obs-card obs-empty">{t('common.empty')}</div>}
            >
              <div class="obs-card obs-table">
                <div class="obs-tablescroll">
                  <table>
                    <thead>
                      <tr>
                        <th>{t('table.type')}</th>
                        <th>{t('table.jid')}</th>
                        <th>{t('busy.started')}</th>
                        <th>{t('table.elapsed')}</th>
                        <th>{t('table.size')}</th>
                        <th />
                      </tr>
                    </thead>
                    <tbody>
                      <For each={data()}>
                        {(p) => (
                          <tr>
                            <td style={{ 'font-weight': 500, color: 'var(--obs-text)' }}>{p.type}</td>
                            <td><span class="obs-mono-cell">{p.jid}</span></td>
                            <td>
                              <Show when={p.started_at} fallback="—">
                                {(startedAt) => <span title={hoverTime(startedAt(), timeZone)}>{absoluteTime(startedAt(), timeZone)}</span>}
                              </Show>
                            </td>
                            <td>{formatNumber(p.elapsed)} {t('common.ms')}</td>
                            <td>{fmtBytes(p.size)}</td>
                            <td style={{ 'text-align': 'end' }}>
                              {/* Full reload (not client-route): the backend POSTs the blob
                                  to the Firefox profiler then 302s out to profiler.firefox.com. */}
                              <a
                                class="obs-btn obs-btn--ghost obs-btn--sm"
                                href={`${basePath()}/profiles/${encodeURIComponent(p.key)}`}
                                target="_blank"
                                rel="noopener noreferrer"
                              >
                                <i class="fa-solid fa-up-right-from-square" aria-hidden="true" /> {t('extension.open')}
                              </a>
                            </td>
                          </tr>
                        )}
                      </For>
                    </tbody>
                  </table>
                </div>
              </div>
            </Show>
          </div>
        )}
      </Match>
    </Switch>
  );
}

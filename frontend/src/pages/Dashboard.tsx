import { useQuery } from '@tanstack/solid-query';
import { createSignal, createMemo, onMount, For, Show, Switch, Match } from 'solid-js';
import { A } from '@solidjs/router';
import { AreaChart } from '../components/charts';
import { AnimatedNumber } from '../components/AnimatedNumber';
import { PageHeader } from '../components/PageHeader';
import { Skeleton, SkeletonCards, SkeletonTable } from '../components/Skeleton';
import { t } from '../i18n';
import { useSSE } from '../hooks/useSSE';
import { formatDuration } from '../utils';
import { basePath } from '../basePath';

interface StatsData {
  processed: number;
  failed: number;
  expired: number;
  busy: number;
  enqueued: number;
  retries: number;
  scheduled: number;
  dead: number;
  processes: number;
  latency: number;
  queues: Array<{ name: string; size: number; latency: number; paused: boolean }>;
}

interface HistoryPoint {
  at: number;
  processed: number;
  failed: number;
}

interface HistoryResponse {
  bucket: string;
  window: number;
  series: HistoryPoint[];
}

// Throughput change over the trailing hour vs the hour before it, derived from
// the same buckets the chart plots — no extra request, no fabricated number.
function hourlyDeltaPct(series: HistoryPoint[], key: 'processed' | 'failed'): number | null {
  if (series.length < 2) return null;
  const now = series[series.length - 1].at;
  let cur = 0;
  let prev = 0;
  for (const p of series) {
    if (p.at > now - 3600) cur += p[key];
    else if (p.at > now - 7200) prev += p[key];
  }
  if (prev === 0) return cur === 0 ? null : 100;
  return Math.round(((cur - prev) / prev) * 100);
}

// Range buttons → rollup bucket + retention window, matching the Metrics page.
// "1h" reuses the 1m/24h rollup and slices client-side; the rest map 1:1 to a
// stored window. `desc_key` is an i18n path (resolved via t()) so the panel
// subtitle localizes alongside the rest of the dashboard copy.
const RANGES = [
  { key: '1h', bucket: '1m', window: '24h', slice: 60, desc_key: 'dashboard.range_1h_desc' },
  { key: '24h', bucket: '1m', window: '24h', desc_key: 'dashboard.range_24h_desc' },
  { key: '7d', bucket: '5m', window: '7d', desc_key: 'dashboard.range_7d_desc' },
  { key: '30d', bucket: '1h', window: '30d', desc_key: 'dashboard.range_30d_desc' },
] as const;

const fmtBucket = (at: number, bucket: string) => {
  const d = new Date(at * 1000);
  const hh = String(d.getHours()).padStart(2, '0');
  return bucket === '1h'
    ? `${d.getMonth() + 1}/${d.getDate()} ${hh}:00`
    : `${hh}:${String(d.getMinutes()).padStart(2, '0')}`;
};

function DeltaSub(props: { pct: number | null; goodWhenUp: boolean }) {
  return (
    <Show when={props.pct !== null} fallback={<span class="obs-metric__sub">{t('dashboard.vs_last_hour')}</span>}>
      {(() => {
        const up = () => props.pct! >= 0;
        const good = () => up() === props.goodWhenUp;
        return (
          <span class="obs-metric__sub">
            <span class={good() ? 'up' : 'down'}>
              {up() ? '▲' : '▼'} {up() ? '+' : ''}{props.pct}%
            </span>{' '}
            {t('dashboard.vs_last_hour')}
          </span>
        );
      })()}
    </Show>
  );
}

export default function Dashboard() {
  const sse = useSSE();
  const [rangeIdx, setRangeIdx] = createSignal(0); // default 1h
  const range = () => RANGES[rangeIdx()];

  onMount(() => {
    document.title = `${t('nav.dashboard')} — Wurk`;
  });

  const statsQuery = useQuery(() => ({
    queryKey: ['stats'],
    queryFn: () => fetch(`${basePath()}/api/stats`).then((r) => r.json() as Promise<StatsData>),
    enabled: !sse.connected(),
    refetchInterval: sse.connected() ? false : 5000,
  }));

  // Throughput for the Performance Insight chart over the selected range (same
  // source as Metrics).
  const historyQuery = useQuery(() => ({
    queryKey: ['history', range().bucket, range().window],
    queryFn: () =>
      fetch(`${basePath()}/api/history/${range().bucket}?window=${range().window}`).then((r) => r.json() as Promise<HistoryResponse>),
    refetchInterval: 30000,
  }));

  const stats = (): StatsData | null => sse.stats() ?? statsQuery.data ?? null;
  // Delta math needs the prior-hour buckets, so keep the full history for
  // hourlyDeltaPct() and slice only for chart rendering. Slicing first would
  // drop the comparison window on the 1h tab and force the 100% fallback.
  const fullSeries = createMemo(() =>
    (historyQuery.data?.series ?? []).map((p) => ({ ...p, label: fmtBucket(p.at, range().bucket) })),
  );
  const series = createMemo(() => {
    const r = range();
    const sliceN = 'slice' in r ? r.slice : undefined;
    return sliceN ? fullSeries().slice(-sliceN) : fullSeries();
  });
  const hasHistory = createMemo(() => series().some((p) => p.processed > 0 || p.failed > 0));

  // One definition, rendered by every branch. The page's <h1> lives here, so a
  // branch that omits it leaves the document untitled — which is how the dashboard
  // lost its heading in the first place. A component rather than a shared element:
  // each branch mounts its own node instead of moving one between them.
  const Header = () => (
    <PageHeader icon="fa-gauge-high" title={t('nav.dashboard')} summary={t('summaries.dashboard')} />
  );

  return (
    <Switch>
      <Match when={statsQuery.isLoading && !stats()}>
        <div class="obs">
          <Header />
          <SkeletonCards count={4} />
          <SkeletonTable rows={6} cols={4} />
        </div>
      </Match>
      <Match when={statsQuery.isError && !stats()}>
        <div class="obs">
          <Header />
          <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
        </div>
      </Match>
      <Match when={!stats()}>
        <div class="obs">
          <Header />
          <div class="empty-state">{t('common.empty')}</div>
        </div>
      </Match>
      <Match when={stats()}>
        {(s) => (
          <div class="obs">
            <Header />
            <div class="obs-metrics">
              <A class="obs-card obs-metric obs-card--link" href="/metrics">
                <div class="obs-metric__head">
                  <span class="obs-mono">{t('dashboard.processed')}</span>
                  <i class="fa-solid fa-circle-check obs-metric__icon" aria-hidden="true" />
                </div>
                <span class="obs-metric__value">
                  <AnimatedNumber value={s().processed} />
                </span>
                <DeltaSub pct={hourlyDeltaPct(fullSeries(), 'processed')} goodWhenUp />
                <i class="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
              </A>
              <A class="obs-card obs-metric obs-card--link" href="/retries">
                <div class="obs-metric__head">
                  <span class="obs-mono">{t('dashboard.failed')}</span>
                  <i class="fa-solid fa-triangle-exclamation obs-metric__icon" aria-hidden="true" />
                </div>
                <span class="obs-metric__value">
                  <AnimatedNumber value={s().failed} />
                </span>
                <DeltaSub pct={hourlyDeltaPct(fullSeries(), 'failed')} goodWhenUp={false} />
                <i class="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
              </A>
              <A class="obs-card obs-metric obs-card--link" href="/dead">
                <div class="obs-metric__head">
                  <span class="obs-mono">{t('dashboard.expired')}</span>
                  <i class="fa-solid fa-ban obs-metric__icon" aria-hidden="true" />
                </div>
                <span class="obs-metric__value">
                  <AnimatedNumber value={s().expired} />
                </span>
                <span class="obs-metric__sub">{s().expired === 0 ? t('dashboard.stable_threshold') : t('dashboard.above_threshold')}</span>
                <i class="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
              </A>
              <A class="obs-card obs-metric obs-card--link" href="/busy">
                <div class="obs-metric__head">
                  <span class="obs-mono">{t('dashboard.busy')}</span>
                  <i class="fa-solid fa-spinner obs-metric__icon" aria-hidden="true" />
                </div>
                <span class="obs-metric__value">
                  <AnimatedNumber value={s().busy} />
                </span>
                <span class="obs-metric__sub">{s().busy === 0 ? t('dashboard.system_idle') : t('dashboard.processing')}</span>
                <i class="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
              </A>
            </div>

            <div class="obs-card obs-panel">
              <div class="obs-panel__head">
                <div>
                  <h2 class="obs-panel__title">{t('dashboard.performance_insight')}</h2>
                  <p class="obs-panel__sub">{t('dashboard.perf_subtitle', { range: t(range().desc_key) })}</p>
                </div>
                <div class="obs-panel__controls">
                  <div class="obs-seg" role="tablist" aria-label="Time range">
                    <For each={RANGES}>
                      {(r, i) => (
                        <button
                          role="tab"
                          aria-selected={i() === rangeIdx()}
                          class={i() === rangeIdx() ? 'is-active' : ''}
                          onClick={() => setRangeIdx(i())}
                        >
                          {r.key}
                        </button>
                      )}
                    </For>
                  </div>
                  <div class="obs-legend">
                    <span><i class="dot dot--processed" /> {t('dashboard.processed')}</span>
                    <span><i class="dot dot--failed" /> {t('dashboard.failed')}</span>
                  </div>
                </div>
              </div>
              <div class="obs-chartbox">
                <Show when={!historyQuery.isPending} fallback={<Skeleton height={320} />}>
                  <Show
                    when={hasHistory()}
                    fallback={
                      <div class="empty-state" style={{ height: '320px', display: 'grid', 'place-items': 'center' }}>
                        {t('dashboard.no_history')}
                      </div>
                    }
                  >
                    <AreaChart
                      data={series()}
                      height={320}
                      xMinTickGap={64}
                      series={[
                        { key: 'processed', name: t('dashboard.processed'), stroke: '#fafafa', strokeWidth: 2, fill: 'gradient' },
                        { key: 'failed', name: t('dashboard.failed'), stroke: '#a1a1aa', strokeWidth: 1.5, strokeDasharray: '5 4', fill: 'none' },
                      ]}
                    />
                  </Show>
                </Show>
              </div>
            </div>

            <div class="obs-stats">
              <A class="obs-card obs-stat obs-card--link" href="/queues">
                <span class="obs-mono">{t('dashboard.enqueued')}</span>
                <span class="obs-stat__value">
                  <AnimatedNumber value={s().enqueued} />
                </span>
                <i class="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
              </A>
              <A class="obs-card obs-stat obs-card--link" href="/retries">
                <span class="obs-mono">{t('dashboard.retries')}</span>
                <span class="obs-stat__value">
                  <AnimatedNumber value={s().retries} />
                </span>
                <i class="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
              </A>
              <A class="obs-card obs-stat obs-card--link" href="/scheduled">
                <span class="obs-mono">{t('dashboard.scheduled')}</span>
                <span class="obs-stat__value">
                  <AnimatedNumber value={s().scheduled} />
                </span>
                <i class="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
              </A>
              <A class="obs-card obs-stat obs-card--link" href="/dead">
                <span class="obs-mono">{t('dashboard.dead')}</span>
                <span class="obs-stat__value">
                  <AnimatedNumber value={s().dead} />
                </span>
                <i class="fa-solid fa-arrow-right obs-card__go" aria-hidden="true" />
              </A>
            </div>

            <div class="obs-card obs-table">
              <div class="obs-table__head">
                <h2 class="obs-table__title">{t('table.queues')}</h2>
                <A class="obs-table__link" href="/queues">
                  View All <i class="fa-solid fa-arrow-right" aria-hidden="true" />
                </A>
              </div>
              <Show
                when={s().queues.length > 0}
                fallback={<div class="empty-state">{t('common.empty')}</div>}
              >
                <div class="obs-tablescroll">
                  <table>
                    <thead>
                      <tr>
                        <th>Name</th>
                        <th>{t('table.size')}</th>
                        <th>{t('table.latency')}</th>
                        <th>{t('table.status')}</th>
                      </tr>
                    </thead>
                    <tbody>
                      <For each={s().queues}>
                        {(q) => (
                          <tr>
                            <td style={{ 'font-weight': 500, color: 'var(--obs-text)' }}>{q.name}</td>
                            <td><AnimatedNumber value={q.size} /></td>
                            <td title={`${q.latency.toFixed(3)}s`}>{formatDuration(q.latency)}</td>
                            <td>
                              <Show
                                when={q.paused}
                                fallback={<span class="obs-chip obs-chip--active">{t('dashboard.active')}</span>}
                              >
                                <span class="obs-chip obs-chip--paused">{t('dashboard.paused')}</span>
                              </Show>
                            </td>
                          </tr>
                        )}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>
            </div>

            <div class="obs-card obs-cta">
              <span class="obs-cta__icon"><i class="fa-solid fa-bolt" aria-hidden="true" /></span>
              <h2 class="obs-cta__title">{t('dashboard.strapline')}</h2>
              <p class="obs-cta__text">{t('dashboard.tagline')}</p>
              <div class="obs-cta__actions">
                <a class="obs-btn obs-btn--primary" href="https://developerz-ai.github.io/wurk/" target="_blank" rel="noreferrer">
                  <i class="fa-solid fa-download" aria-hidden="true" /> {t('dashboard.install')}
                </a>
                <a class="obs-btn obs-btn--ghost" href="https://github.com/developerz-ai/wurk/wiki" target="_blank" rel="noreferrer">
                  <i class="fa-solid fa-book" aria-hidden="true" /> {t('dashboard.docs')}
                </a>
              </div>
            </div>
          </div>
        )}
      </Match>
    </Switch>
  );
}

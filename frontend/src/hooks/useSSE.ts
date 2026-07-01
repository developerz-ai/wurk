import { createSignal, onCleanup, onMount, type Accessor } from 'solid-js';

export interface StatsSnapshot {
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
  at: number;
}

// Live stats over Server-Sent Events. Returns signal accessors — read them as
// `stats()` / `connected()` inside JSX or a memo so they track reactively.
// The EventSource is opened on mount and closed on cleanup (component dispose),
// so exactly one connection lives per mounted consumer.
export function useSSE(
  enabled = true,
): { stats: Accessor<StatsSnapshot | null>; connected: Accessor<boolean> } {
  const [stats, setStats] = createSignal<StatsSnapshot | null>(null);
  const [connected, setConnected] = createSignal(false);

  onMount(() => {
    if (!enabled) return;
    const es = new EventSource('/wurk/api/stream');
    es.addEventListener('stats', (e) => {
      try {
        setStats(JSON.parse((e as MessageEvent).data) as StatsSnapshot);
      } catch {
        // ignore parse errors
      }
    });
    es.onopen = () => setConnected(true);
    es.onerror = () => setConnected(false);
    onCleanup(() => {
      es.close();
      setConnected(false);
    });
  });

  return { stats, connected };
}

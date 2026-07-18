import { onCleanup, onMount, createSignal, type Accessor } from 'solid-js';
import { basePath } from '../basePath';

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

// One shared SSE stream for the whole app. useSSE() is called by both the
// persistent Nav (live-status chip) and the Dashboard, so a per-consumer
// EventSource would open two streams to /api/stream the moment the dashboard is
// on screen. The connection is instead a module singleton, ref-counted across
// consumers: opened on the first mount, closed when the last consumer unmounts.
// Signals are module-level so every consumer reads the same live state.
const [stats, setStats] = createSignal<StatsSnapshot | null>(null);
const [connected, setConnected] = createSignal(false);
let source: EventSource | null = null;
let refs = 0;

function openStream() {
  source = new EventSource(`${basePath()}/api/stream`);
  source.addEventListener('stats', (e) => {
    try {
      setStats(JSON.parse((e as MessageEvent).data) as StatsSnapshot);
    } catch {
      // ignore parse errors
    }
  });
  source.onopen = () => setConnected(true);
  source.onerror = () => setConnected(false);
}

function closeStream() {
  source?.close();
  source = null;
  setConnected(false);
  setStats(null);
}

// Live stats over Server-Sent Events. Returns signal accessors — read them as
// `stats()` / `connected()` inside JSX or a memo so they track reactively.
export function useSSE(
  enabled = true,
): { stats: Accessor<StatsSnapshot | null>; connected: Accessor<boolean> } {
  onMount(() => {
    if (!enabled) return;
    if (refs === 0) openStream();
    refs += 1;
    onCleanup(() => {
      refs -= 1;
      if (refs === 0) closeStream();
    });
  });

  return { stats, connected };
}

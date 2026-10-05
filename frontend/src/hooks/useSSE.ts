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

// EventSource's own reconnect only covers a stream that dropped mid-flight
// (readyState CONNECTING). A non-200 answer — the server's 503 when the stream
// cap is reached or Redis is down — leaves it CLOSED for good, and the status
// and Retry-After are invisible to script. Reopen ourselves, backing off so a
// saturated server isn't hammered; consumers fall back to polling meanwhile.
//
// The server also ends every stream after a fixed lifetime; the browser then
// reconnects on its own (CONNECTING). `connected` only drops if that reconnect
// hasn't reopened within a grace period, so the routine rotation doesn't
// flicker the live chip or kick the dashboard into polling.
const READY_STATE_CLOSED = 2;
// First retry matches the `Retry-After: 3` the stream's 503 advertises.
const RECONNECT_BASE_MS = 3000;
const RECONNECT_MAX_MS = 30_000;
const DISCONNECT_GRACE_MS = 5000;
let attempts = 0;
let retryTimer: ReturnType<typeof setTimeout> | undefined;
let graceTimer: ReturnType<typeof setTimeout> | undefined;

function clearTimers() {
  clearTimeout(retryTimer);
  clearTimeout(graceTimer);
  retryTimer = undefined;
  graceTimer = undefined;
  attempts = 0;
}

function openStream() {
  const es = new EventSource(`${basePath()}/api/stream`);
  source = es;
  es.addEventListener('stats', (e) => {
    try {
      setStats(JSON.parse((e as MessageEvent).data) as StatsSnapshot);
    } catch {
      // ignore parse errors
    }
  });
  es.onopen = () => {
    attempts = 0;
    clearTimeout(graceTimer);
    graceTimer = undefined;
    setConnected(true);
  };
  es.onerror = () => {
    if (source !== es) return;
    if (es.readyState !== READY_STATE_CLOSED) {
      graceTimer ??= setTimeout(() => {
        graceTimer = undefined;
        setConnected(false);
      }, DISCONNECT_GRACE_MS);
      return;
    }
    clearTimeout(graceTimer);
    graceTimer = undefined;
    setConnected(false);
    es.close();
    source = null;
    const delay = Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * 2 ** attempts);
    attempts += 1;
    retryTimer = setTimeout(() => {
      retryTimer = undefined;
      if (refs > 0 && !source) openStream();
    }, delay);
  };
}

function closeStream() {
  clearTimers();
  source?.close();
  source = null;
  setConnected(false);
  setStats(null);
}

// Test-only: module state (source/refs/signals) survives across test cases
// since the SSE stream is a singleton, not per-component. A test that throws
// mid-run can skip its onCleanup and leak refs/source into the next test —
// call this in afterEach to force a clean slate regardless of how the
// previous test exited.
export function __resetSSE(): void {
  clearTimers();
  source?.close();
  source = null;
  refs = 0;
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

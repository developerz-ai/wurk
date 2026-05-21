import { useState, useEffect, useRef } from 'react';

export interface StatsSnapshot {
  processed: number;
  failed: number;
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

export function useSSE(enabled = true) {
  const [stats, setStats] = useState<StatsSnapshot | null>(null);
  const [connected, setConnected] = useState(false);
  const esRef = useRef<EventSource | null>(null);

  useEffect(() => {
    if (!enabled) return;
    const es = new EventSource('/wurk/api/stream');
    esRef.current = es;
    es.addEventListener('stats', (e) => {
      try {
        setStats(JSON.parse((e as MessageEvent).data) as StatsSnapshot);
      } catch {
        // ignore parse errors
      }
    });
    es.onopen = () => setConnected(true);
    es.onerror = () => setConnected(false);
    return () => {
      es.close();
      setConnected(false);
    };
  }, [enabled]);

  return { stats, connected };
}

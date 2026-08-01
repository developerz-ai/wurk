import { describe, it, expect, vi, afterEach } from 'vitest';
import { renderHook, waitFor, cleanup } from '@solidjs/testing-library';
import { useSSE, __resetSSE, type StatsSnapshot } from './useSSE';

// Minimal EventSource stand-in that records every instance opened so tests can
// reach in and fire onopen/onerror/message the way a real SSE stream would.
class StubEventSource {
  static instances: StubEventSource[] = [];
  readonly url: string;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  closed = false;
  private listeners: Record<string, Array<(e: MessageEvent) => void>> = {};

  constructor(url: string) {
    this.url = url;
    StubEventSource.instances.push(this);
  }

  addEventListener(type: string, cb: (e: MessageEvent) => void): void {
    (this.listeners[type] ??= []).push(cb);
  }

  removeEventListener(): void {}

  close(): void {
    this.closed = true;
  }

  emit(type: string, event: Partial<MessageEvent>): void {
    for (const cb of this.listeners[type] ?? []) cb(event as MessageEvent);
  }
}

const SNAPSHOT: StatsSnapshot = {
  processed: 1,
  failed: 0,
  expired: 0,
  busy: 2,
  enqueued: 3,
  retries: 0,
  scheduled: 0,
  dead: 0,
  processes: 1,
  latency: 0.5,
  queues: [{ name: 'default', size: 3, latency: 0.5, paused: false }],
  at: 12345,
};

describe('useSSE', () => {
  afterEach(() => {
    // cleanup() disposes any still-mounted reactive root first (running
    // useSSE's onCleanup, which decrements refs the normal way); __resetSSE()
    // then forces module state to zero regardless of whether that dispose
    // ran at all — belt-and-braces for a test that threw before reaching its
    // own cleanup() call. Order matters: resetting first would let a
    // still-pending onCleanup decrement refs to -1 instead of 0.
    cleanup();
    __resetSSE();
    vi.unstubAllGlobals();
    StubEventSource.instances = [];
  });

  it('opens exactly one connection against basePath + /api/stream on mount', async () => {
    vi.stubGlobal('EventSource', StubEventSource);
    const { result } = renderHook(() => useSSE());

    await waitFor(() => expect(StubEventSource.instances).toHaveLength(1));
    expect(StubEventSource.instances[0].url).toBe('/wurk/api/stream');
    expect(result.connected()).toBe(false);
    expect(result.stats()).toBeNull();
  });

  it('flips connected true on open and false again on error', async () => {
    vi.stubGlobal('EventSource', StubEventSource);
    const { result } = renderHook(() => useSSE());
    await waitFor(() => expect(StubEventSource.instances).toHaveLength(1));
    const es = StubEventSource.instances[0];

    es.onopen?.();
    expect(result.connected()).toBe(true);

    es.onerror?.();
    expect(result.connected()).toBe(false);
  });

  it('parses a "stats" message into the stats signal', async () => {
    vi.stubGlobal('EventSource', StubEventSource);
    const { result } = renderHook(() => useSSE());
    await waitFor(() => expect(StubEventSource.instances).toHaveLength(1));
    const es = StubEventSource.instances[0];

    es.emit('stats', { data: JSON.stringify(SNAPSHOT) });
    expect(result.stats()).toEqual(SNAPSHOT);
  });

  it('swallows a malformed "stats" payload instead of throwing', async () => {
    vi.stubGlobal('EventSource', StubEventSource);
    const { result } = renderHook(() => useSSE());
    await waitFor(() => expect(StubEventSource.instances).toHaveLength(1));
    const es = StubEventSource.instances[0];

    expect(() => es.emit('stats', { data: 'not json' })).not.toThrow();
    expect(result.stats()).toBeNull();
  });

  it('closes the connection and resets connected on cleanup (component dispose)', async () => {
    vi.stubGlobal('EventSource', StubEventSource);
    const { result, cleanup } = renderHook(() => useSSE());
    await waitFor(() => expect(StubEventSource.instances).toHaveLength(1));
    const es = StubEventSource.instances[0];
    es.onopen?.();
    expect(result.connected()).toBe(true);

    cleanup();
    expect(es.closed).toBe(true);
    expect(result.connected()).toBe(false);
  });

  it('never opens a connection when disabled', async () => {
    vi.stubGlobal('EventSource', StubEventSource);
    renderHook(() => useSSE(false));
    await new Promise((r) => setTimeout(r, 0));
    expect(StubEventSource.instances).toHaveLength(0);
  });

  it('does not leak refs/source into the next test when a mid-test assertion throws', async () => {
    vi.stubGlobal('EventSource', StubEventSource);
    renderHook(() => useSSE());
    await waitFor(() => expect(StubEventSource.instances).toHaveLength(1));

    // Simulates a failing assertion (or any thrown error) partway through a
    // test, before its cleanup() would normally run and decrement refs.
    // __resetSSE() in afterEach must still bring module state back to zero.
    expect(() => {
      throw new Error('simulated mid-test failure before cleanup() runs');
    }).toThrow();
    // Deliberately no cleanup() call here — mirrors a real thrown failure.
  });

  it('opens exactly one fresh connection after a prior test threw without cleanup', async () => {
    vi.stubGlobal('EventSource', StubEventSource);
    const { result } = renderHook(() => useSSE());

    await waitFor(() => expect(StubEventSource.instances).toHaveLength(1));
    expect(result.connected()).toBe(false);
    expect(result.stats()).toBeNull();
  });
});

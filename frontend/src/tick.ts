import { createSignal, onCleanup, onMount } from 'solid-js';

// One interval for the whole app, driving every relative label on screen.
// Relative times are read per cell and a single table can render hundreds of
// them (VirtualList.tsx keeps the DOM short, not the data), so a timer per cell
// would mean hundreds of timers to observe one second passing. The timer is
// instead a module singleton ref-counted across consumers — the same shape as
// the SSE stream in hooks/useSSE.ts: started on the first mount, cleared when
// the last consumer unmounts, never two at once.

// One second: below the smallest unit any label renders, so a "3 seconds ago"
// cell is never visibly behind the clock, and the work per tick is one integer.
export const TICK_MS = 1000;

const [tick, setTick] = createSignal(0);
let timer: ReturnType<typeof setInterval> | null = null;
let refs = 0;

/**
 * Subscribes the calling computation to the shared tick. The returned count
 * carries no meaning on its own — it only announces that time moved, so a
 * label reading it recomputes against a fresh clock. Deliberately *not* the
 * current time: a label rendered where nothing owns the timer still formats
 * against `Date.now()` instead of freezing at whenever the bundle loaded.
 */
export function liveTick(): number {
  return tick();
}

function stopTimer(): void {
  if (timer !== null) clearInterval(timer);
  timer = null;
}

/** Owns the shared timer for as long as the calling component stays mounted. */
export function useLiveTick(): void {
  onMount(() => {
    if (refs === 0) timer = setInterval(() => setTick((n) => n + 1), TICK_MS);
    refs += 1;
    onCleanup(() => {
      refs -= 1;
      if (refs === 0) stopTimer();
    });
  });
}

// Test-only: the timer and refcount are module state that outlives a single
// test case, so a test throwing before its onCleanup runs would leak a live
// interval and a non-zero refcount into the next one. Mirrors `__resetSSE`.
export function __resetTick(): void {
  stopTimer();
  refs = 0;
  setTick(0);
}

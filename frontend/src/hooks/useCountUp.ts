import { createSignal, createEffect, onCleanup, type Accessor } from 'solid-js';

const easeOutCubic = (t: number) => 1 - Math.pow(1 - t, 3);

const prefersReducedMotion = () =>
  typeof window !== 'undefined' &&
  window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

// Tween a displayed number toward `target` with requestAnimationFrame so a stat
// counts up to its real value instead of snapping. `target` is an accessor; the
// effect re-runs whenever it changes. Each run starts from whatever is currently
// on screen (tracked in `current`), so the first landing counts up from zero
// while later live SSE updates ease smoothly between values rather than
// restarting from zero. Honors prefers-reduced-motion by snapping.
export function useCountUp(target: Accessor<number>, duration = 700): Accessor<number> {
  const [display, setDisplay] = createSignal(0);
  let current = 0;
  let raf: number | null = null;

  createEffect(() => {
    const tgt = target();
    if (prefersReducedMotion() || !Number.isFinite(tgt)) {
      current = tgt;
      setDisplay(tgt);
      return;
    }

    const from = current;
    if (from === tgt) return;

    const start = performance.now();
    const tick = (now: number) => {
      const t = Math.min((now - start) / duration, 1);
      const value = from + (tgt - from) * easeOutCubic(t);
      current = value;
      setDisplay(value);
      if (t < 1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);

    onCleanup(() => {
      if (raf !== null) cancelAnimationFrame(raf);
    });
  });

  return display;
}

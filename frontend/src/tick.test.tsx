import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup } from '@solidjs/testing-library';
import { For } from 'solid-js';
import { TICK_MS, useLiveTick, __resetTick } from './tick';
import { relativeTime } from './utils';

const NOW = new Date('2026-08-08T12:00:00Z');
const EPOCH = NOW.getTime() / 1000;

// A cell exactly as the tables render one: the relative label is the whole of
// a JSX expression, so Solid wraps it in its own computation.
function Cell(props: { at: number }) {
  return <span data-testid="cell">{relativeTime(props.at)}</span>;
}

/** A page: owns the tick once, renders `rows` labels under it. */
function Page(props: { rows: number }) {
  useLiveTick();
  return (
    <For each={Array.from({ length: props.rows }, (_, i) => EPOCH - i)}>{(at) => <Cell at={at} />}</For>
  );
}

describe('shared live tick', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
  });

  afterEach(() => {
    // Dispose the trees first: cleanup runs the onCleanup that releases the
    // refcount, and it has to happen while the fake clock still owns the timer.
    cleanup();
    __resetTick();
    vi.useRealTimers();
  });

  it('runs one interval for a whole table, not one per cell', () => {
    render(() => <Page rows={200} />);

    expect(screen.getAllByTestId('cell')).toHaveLength(200);
    expect(vi.getTimerCount()).toBe(1);
  });

  it('shares that one interval across concurrently mounted pages', () => {
    render(() => <Page rows={3} />);
    render(() => <Page rows={3} />);

    expect(vi.getTimerCount()).toBe(1);
  });

  it('ages every label on the tick, with no refetch and no prop change', () => {
    render(() => <Cell at={EPOCH - 5} />);
    expect(screen.getByTestId('cell')).toHaveTextContent('5 seconds ago');

    render(() => <Page rows={0} />);
    vi.advanceTimersByTime(60 * TICK_MS);

    expect(screen.getByTestId('cell')).toHaveTextContent('1 minute ago');
  });

  it('keeps ticking while any consumer is still mounted', () => {
    const first = render(() => <Page rows={1} />);
    render(() => <Page rows={1} />);

    first.unmount();

    expect(vi.getTimerCount()).toBe(1);
  });

  it('clears the interval when the last consumer unmounts', () => {
    const first = render(() => <Page rows={1} />);
    const second = render(() => <Page rows={1} />);

    first.unmount();
    second.unmount();

    expect(vi.getTimerCount()).toBe(0);
  });

  it('restarts cleanly after the last consumer left', () => {
    render(() => <Page rows={1} />).unmount();
    render(() => <Page rows={1} />);

    expect(vi.getTimerCount()).toBe(1);
  });

  // The tick announces that time moved; it is not itself the clock. A label
  // rendered where nothing owns the timer — a standalone modal in a test, a
  // page mounted outside the shell — must still read off Date.now().
  it('formats against the wall clock even with no timer running', () => {
    render(() => <Cell at={EPOCH - 5} />);

    expect(vi.getTimerCount()).toBe(0);
    expect(screen.getByTestId('cell')).toHaveTextContent('5 seconds ago');
  });
});

import { describe, it, expect, vi, afterEach } from 'vitest';
import { createSignal, Show, onMount, onCleanup } from 'solid-js';
import { render, screen } from '@solidjs/testing-library';
import Modal from './Modal';

// jsdom has no <dialog> top-layer support; the modal's content visibility is
// signal-driven, so stubbing these is enough for showModal()/close().
HTMLDialogElement.prototype.showModal = vi.fn();
HTMLDialogElement.prototype.close = vi.fn();

afterEach(() => {
  vi.useRealTimers();
});

describe('Modal', () => {
  it('renders the title and children while open', () => {
    render(() => (
      <Modal open onClose={() => {}} title="Detail">
        <div>payload</div>
      </Modal>
    ));
    expect(screen.getByText('Detail')).toBeInTheDocument();
    expect(screen.getByText('payload')).toBeInTheDocument();
  });

  it('resolves dynamic (e.g. <Show>-gated) children without losing them while open', () => {
    const [proc, setProc] = createSignal<{ pid: number } | null>({ pid: 1 });
    render(() => (
      <Modal open onClose={() => {}} title="Detail">
        <Show when={proc()}>{(p) => <div>pid {p().pid}</div>}</Show>
      </Modal>
    ));
    expect(screen.getByText('pid 1')).toBeInTheDocument();

    setProc({ pid: 2 });
    expect(screen.getByText('pid 2')).toBeInTheDocument();
  });

  it('keeps the last content on screen immediately after close, for the exit transition to animate', () => {
    const [open, setOpen] = createSignal(true);
    render(() => (
      <Modal open={open()} onClose={() => {}} title="Detail">
        <div>payload</div>
      </Modal>
    ));

    setOpen(false);
    expect(screen.getByText('payload')).toBeInTheDocument();
  });

  it('releases the held subtree 240ms after close (matches --dur-slow)', () => {
    vi.useFakeTimers();
    const [open, setOpen] = createSignal(true);
    render(() => (
      <Modal open={open()} onClose={() => {}} title="Detail">
        <div>payload</div>
      </Modal>
    ));

    setOpen(false);
    expect(screen.queryByText('payload')).not.toBeNull();

    vi.advanceTimersByTime(239);
    expect(screen.queryByText('payload')).not.toBeNull();

    vi.advanceTimersByTime(1);
    expect(screen.queryByText('payload')).toBeNull();
  });

  it('disposes children owned by the consumer (e.g. a <Show>) the moment its own condition flips, independent of the release timer', () => {
    vi.useFakeTimers();
    const disposed = vi.fn();
    function Tracked(props: { pid: number }) {
      onCleanup(disposed);
      return <div>payload {props.pid}</div>;
    }
    const [open, setOpen] = createSignal(true);
    const [proc, setProc] = createSignal<{ pid: number } | null>({ pid: 1 });
    render(() => (
      <Modal open={open()} onClose={() => {}} title="Detail">
        <Show when={proc()}>{(p) => <Tracked pid={p().pid} />}</Show>
      </Modal>
    ));

    // Consumers typically clear their data the instant `open` flips false —
    // Modal's held/release timer only governs how long the already-resolved
    // DOM stays visible, not when the consumer's own reactive tree disposes.
    setOpen(false);
    setProc(null);
    expect(disposed).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(240);
    expect(screen.queryByText('payload')).toBeNull();
  });

  it('reopening before the release timer fires cancels the pending release', () => {
    vi.useFakeTimers();
    const [open, setOpen] = createSignal(true);
    render(() => (
      <Modal open={open()} onClose={() => {}} title="Detail">
        <div>payload</div>
      </Modal>
    ));

    setOpen(false);
    vi.advanceTimersByTime(100);
    setOpen(true);
    vi.advanceTimersByTime(200);

    expect(screen.queryByText('payload')).not.toBeNull();
  });

  it('clears the pending release timer on unmount instead of leaking it', () => {
    vi.useFakeTimers();
    const clearSpy = vi.spyOn(window, 'clearTimeout');
    const [open, setOpen] = createSignal(true);
    const { unmount } = render(() => (
      <Modal open={open()} onClose={() => {}} title="Detail">
        <div>payload</div>
      </Modal>
    ));

    setOpen(false);
    unmount();

    expect(clearSpy).toHaveBeenCalled();
  });

  it('does not remount the children subtree on every reactive read of an unrelated signal', () => {
    const mounts = vi.fn();
    function Tracked() {
      onMount(mounts);
      return <div>payload</div>;
    }
    const [tick, setTick] = createSignal(0);
    render(() => {
      tick();
      return (
        <Modal open onClose={() => {}} title="Detail">
          <Tracked />
        </Modal>
      );
    });

    setTick((t) => t + 1);
    setTick((t) => t + 1);

    expect(mounts).toHaveBeenCalledTimes(1);
  });
});

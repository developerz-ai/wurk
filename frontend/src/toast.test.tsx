import { describe, it, expect, afterEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import { Toasts, notifyError, pushToast, dismissToast, toasts } from './toast';
import { RequestError } from './http';
import { t } from './i18n';

// The toast store is a module-global signal (app-wide), so it survives between
// `it` blocks in this file; clear it after each so tests don't leak toasts.
afterEach(() => {
  for (const toast of toasts()) dismissToast(toast.id);
});

describe('notifyError', () => {
  it('maps 403 to the read-only message', async () => {
    render(() => <Toasts />);
    notifyError(new RequestError(403));
    expect(await screen.findByText(t('toast.readonly'))).toBeInTheDocument();
  });

  it('maps 404 to the already-gone message', async () => {
    render(() => <Toasts />);
    notifyError(new RequestError(404));
    expect(await screen.findByText(t('toast.gone'))).toBeInTheDocument();
  });

  it('maps 503 to the Redis-unavailable message', async () => {
    render(() => <Toasts />);
    notifyError(new RequestError(503));
    expect(await screen.findByText(t('toast.unavailable'))).toBeInTheDocument();
  });

  it('falls back to a generic message for other statuses and network errors', async () => {
    render(() => <Toasts />);
    notifyError(new RequestError(500));
    notifyError(new Error('network down'));
    expect(await screen.findAllByText(t('toast.failed'))).toHaveLength(2);
  });
});

describe('Toasts', () => {
  it('renders as a live-region alert and dismisses on close click', async () => {
    render(() => <Toasts />);
    pushToast('boom happened', 'error');

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('boom happened');

    fireEvent.click(screen.getByRole('button', { name: t('toast.dismiss') }));
    expect(screen.queryByText('boom happened')).toBeNull();
  });
});

describe('toast timers', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('clears the auto-dismiss timer when dismissed early', () => {
    vi.useFakeTimers();
    const clearSpy = vi.spyOn(window, 'clearTimeout');

    const id = pushToast('early dismiss', 'error');
    dismissToast(id);

    expect(clearSpy).toHaveBeenCalled();
    // Advancing past the TTL must not re-dismiss (list stays empty, no throw).
    vi.advanceTimersByTime(10_000);
    expect(toasts()).toHaveLength(0);
  });

  it('caps the visible list at 5, dropping the oldest', () => {
    vi.useFakeTimers();

    for (let i = 0; i < 20; i += 1) pushToast(`toast ${i}`, 'error');

    const current = toasts();
    expect(current).toHaveLength(5);
    expect(current.map((toast) => toast.message)).toEqual(['toast 15', 'toast 16', 'toast 17', 'toast 18', 'toast 19']);
  });
});

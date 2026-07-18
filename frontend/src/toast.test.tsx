import { describe, it, expect, afterEach } from 'vitest';
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

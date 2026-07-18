import { createSignal, For } from 'solid-js';
import { RequestError } from './http';
import { t } from './i18n';

export type ToastKind = 'error' | 'success';

export interface Toast {
  id: number;
  kind: ToastKind;
  message: string;
}

// Module-level signal: a toast can be raised by any mutation on any page, so
// the list is app-global rather than scoped to a component/context. createSignal
// needs no reactive owner (only effects/memos do), so a module-scope store is
// safe and dependency-free.
const [toasts, setToasts] = createSignal<Toast[]>([]);
export { toasts };

const TTL_MS = 6000;
let seq = 0;

export function pushToast(message: string, kind: ToastKind = 'error'): number {
  const id = (seq += 1);
  setToasts((list) => [...list, { id, kind, message }]);
  // Auto-dismiss after the TTL; guarded for the non-DOM (unit) path with no timer.
  if (typeof window !== 'undefined') window.setTimeout(() => dismissToast(id), TTL_MS);
  return id;
}

export function dismissToast(id: number): void {
  setToasts((list) => list.filter((toast) => toast.id !== id));
}

// Maps a failed mutation to a status-aware toast: 403 = read-only mode, 404 =
// the target was already acted on, 503 = Redis unavailable (plan 05's
// structured 503s); anything else — including a non-HTTP network error — is a
// generic failure.
export function notifyError(err: unknown): void {
  const status = err instanceof RequestError ? err.status : 0;
  const key =
    status === 403
      ? 'toast.readonly'
      : status === 404
        ? 'toast.gone'
        : status === 503
          ? 'toast.unavailable'
          : 'toast.failed';
  pushToast(t(key), 'error');
}

const ICON: Record<ToastKind, string> = {
  error: 'fa-circle-exclamation',
  success: 'fa-circle-check',
};

// Fixed, bottom-anchored stack rendered once in the App shell. Each toast is a
// live-region alert so assistive tech announces a failed action as it appears.
export function Toasts() {
  return (
    <div class="toasts" role="region" aria-live="polite" aria-label={t('toast.region')}>
      <For each={toasts()}>
        {(toast) => (
          <div class={`toast toast--${toast.kind}`} role="alert">
            <i class={`fa-solid ${ICON[toast.kind]} toast__icon`} aria-hidden="true" />
            <span class="toast__msg">{toast.message}</span>
            <button
              type="button"
              class="toast__close"
              aria-label={t('toast.dismiss')}
              onClick={() => dismissToast(toast.id)}
            >
              <i class="fa-solid fa-xmark" aria-hidden="true" />
            </button>
          </div>
        )}
      </For>
    </div>
  );
}

import { ErrorBoundary as SolidErrorBoundary, type ParentProps } from 'solid-js';
import { t } from '../i18n';

// Catches render/lazy-load failures so a single broken route (most commonly a
// `ChunkLoadError` when a client on an old index.html requests a code-split
// chunk that a fresh deploy has already replaced) shows a recoverable message
// instead of a blank white screen. Wraps the route <Suspense> in App.tsx.
//
// Solid ships a first-class <ErrorBoundary> (no class component needed); this
// thin wrapper supplies the localized fallback + a full reload, which fetches
// the current index.html and its up-to-date chunk manifest.
export default function ErrorBoundary(props: ParentProps) {
  return (
    <SolidErrorBoundary
      fallback={(err: Error) => {
        // Surface it for whatever error reporting the host wires up.
        console.error('Dashboard route error:', err);
        return (
          <div class="empty-state" role="alert">
            <div
              style={{
                'font-size': '15px',
                'font-weight': 600,
                color: 'var(--text)',
                'margin-bottom': '0.4rem',
              }}
            >
              {t('common.load_failed')}
            </div>
            <p style={{ 'max-width': '26rem', margin: '0 auto 1.1rem', 'font-size': '13px' }}>
              {t('common.load_failed_hint')}
            </p>
            <button class="btn btn-accent" onClick={() => window.location.reload()}>
              {t('common.reload')}
            </button>
          </div>
        );
      }}
    >
      {props.children}
    </SolidErrorBoundary>
  );
}

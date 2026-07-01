import { Component, type ErrorInfo, type ReactNode } from 'react';
import { t } from '../i18n';

interface Props {
  children: ReactNode;
}

interface State {
  error: Error | null;
}

// Catches render/lazy-load failures so a single broken route (most commonly a
// `ChunkLoadError` when a client on an old index.html requests a code-split
// chunk that a fresh deploy has already replaced) shows a recoverable message
// instead of a blank white screen. Error boundaries must be class components —
// there is no hook equivalent. Wraps the route <Suspense> in App.tsx.
export default class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Surface it for whatever error reporting the host wires up.
    console.error('Dashboard route error:', error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;

    return (
      <div className="empty-state" role="alert">
        <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)', marginBottom: '0.4rem' }}>
          {t('common.load_failed')}
        </div>
        <p style={{ maxWidth: '26rem', margin: '0 auto 1.1rem', fontSize: 13 }}>
          {t('common.load_failed_hint')}
        </p>
        <button className="btn btn-accent" onClick={() => window.location.reload()}>
          {t('common.reload')}
        </button>
      </div>
    );
  }
}

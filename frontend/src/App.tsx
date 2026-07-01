import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Suspense, lazy } from 'react';
import { useState } from 'react';
import { useSSE } from './hooks/useSSE';
import { useMeta } from './hooks/useMeta';
import { t } from './i18n';
import Nav from './components/Nav';
import { PageSkeleton } from './components/Skeleton';
import ErrorBoundary from './components/ErrorBoundary';

// Each page is a lazy chunk: the initial load ships only the shell + landing
// page, and every other tab streams in on navigation behind a Suspense skeleton
// (see the <Suspense> boundary below). Keeps first paint small and fast.
const Dashboard = lazy(() => import('./pages/Dashboard'));
const Queues = lazy(() => import('./pages/Queues'));
const Retries = lazy(() => import('./pages/Retries'));
const Scheduled = lazy(() => import('./pages/Scheduled'));
const Dead = lazy(() => import('./pages/Dead'));
const Busy = lazy(() => import('./pages/Busy'));
const Batches = lazy(() => import('./pages/Batches'));
const BatchDetail = lazy(() => import('./pages/BatchDetail'));
const Limiters = lazy(() => import('./pages/Limiters'));
const Cron = lazy(() => import('./pages/Cron'));
const Metrics = lazy(() => import('./pages/Metrics'));
const Profiles = lazy(() => import('./pages/Profiles'));
const Search = lazy(() => import('./pages/Search'));
const Extension = lazy(() => import('./pages/Extension'));

const qc = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 5000,
      retry: 1,
    },
  },
});

function ReadOnlyBanner() {
  const { data: meta } = useMeta();
  if (!meta?.read_only) return null;

  return (
    <div
      role="status"
      style={{
        background: 'var(--warning)',
        color: '#1a1a1a',
        textAlign: 'center',
        padding: '0.5rem 1rem',
        fontWeight: 600,
        fontSize: 13,
        letterSpacing: '0.01em',
        borderRadius: 8,
        marginBottom: '1.75rem',
      }}
    >
      {meta.read_only_message || t('readonly.banner')}
    </div>
  );
}

const NAV_COLLAPSED_KEY = 'wurk-nav-collapsed';

function prefersReducedMotion() {
  return (
    typeof window !== 'undefined' &&
    window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true
  );
}

export default function App() {
  const [navOpen, setNavOpen] = useState(false);
  // Desktop-only: pin the rail collapsed (icons) or expanded (full), persisted
  // so the choice survives reloads. Replaces the old hover-to-expand rail that
  // moved on its own as the pointer crossed it.
  const [collapsed, setCollapsed] = useState(() => {
    // localStorage can throw SecurityError / QuotaExceededError in private mode
    // or cross-origin iframes — same guard the write path uses.
    try {
      return typeof localStorage !== 'undefined' && localStorage.getItem(NAV_COLLAPSED_KEY) === '1';
    } catch {
      return false;
    }
  });
  const toggleCollapsed = () =>
    setCollapsed((c) => {
      const next = !c;
      try {
        localStorage.setItem(NAV_COLLAPSED_KEY, next ? '1' : '0');
      } catch {
        /* storage disabled (private mode) — keep the in-memory state */
      }
      return next;
    });
  const sse = useSSE();

  return (
    <QueryClientProvider client={qc}>
      <BrowserRouter basename="/wurk">
        <div style={{ display: 'flex', minHeight: '100vh' }}>
          <button
            className="hamburger"
            style={{ position: 'fixed', top: 12, insetInlineStart: 12, zIndex: 200 }}
            onClick={() => setNavOpen((o) => !o)}
            aria-label="Toggle navigation"
          >
            <i className="fa-solid fa-bars" />
          </button>

          <main
            className="main-content"
            style={{
              flex: 1,
              padding: '1.5rem',
              // Reserve the rail or full nav width depending on the pinned state;
              // the mobile media query overrides this to 0 (drawer overlay).
              marginInlineStart: collapsed ? 'var(--nav-rail)' : 'var(--nav-width)',
              // Match the nav rail exactly (same --dur-page / --ease-emphasized)
              // so the content glides in lockstep with the width change; drop it
              // for users who asked for less motion.
              transition: prefersReducedMotion()
                ? 'none'
                : 'margin var(--dur-page) var(--ease-emphasized)',
            }}
          >
            <ReadOnlyBanner />
            <ErrorBoundary>
              <Suspense fallback={<PageSkeleton />}>
                <Routes>
                <Route path="/" element={<Dashboard sse={sse} />} />
                <Route path="/queues" element={<Queues />} />
                <Route path="/retries" element={<Retries />} />
                <Route path="/scheduled" element={<Scheduled />} />
                <Route path="/dead" element={<Dead />} />
                <Route path="/busy" element={<Busy />} />
                <Route path="/batches" element={<Batches />} />
                <Route path="/batches/:bid" element={<BatchDetail />} />
                <Route path="/limiters" element={<Limiters />} />
                <Route path="/cron" element={<Cron />} />
                <Route path="/metrics" element={<Metrics />} />
                <Route path="/profiles" element={<Profiles />} />
                <Route path="/search" element={<Search />} />
                <Route path="/ext/:tab" element={<Extension />} />
              </Routes>
              </Suspense>
            </ErrorBoundary>
          </main>

          <Nav
            open={navOpen}
            onClose={() => setNavOpen(false)}
            collapsed={collapsed}
            onToggleCollapse={toggleCollapsed}
          />
        </div>
      </BrowserRouter>
    </QueryClientProvider>
  );
}

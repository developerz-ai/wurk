import { Router, Route } from '@solidjs/router';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { Suspense, lazy, createSignal, type ParentProps } from 'solid-js';
import { Show } from 'solid-js';
import { useMeta } from './hooks/useMeta';
import { t } from './i18n';
import Nav from './components/Nav';
import { PageSkeleton } from './components/Skeleton';
import ErrorBoundary from './components/ErrorBoundary';

// Each page is a lazy chunk: the initial load ships only the shell + landing
// page, and every other tab streams in on navigation behind the Suspense
// skeleton in the layout. Keeps first paint small and fast. Solid's `lazy`
// pairs with the layout's <Suspense> the same way React.lazy did.
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

export function ReadOnlyBanner() {
  const meta = useMeta();
  return (
    <Show when={meta.data?.read_only}>
      <div
        role="status"
        style={{
          background: 'var(--warning)',
          color: '#1a1a1a',
          'text-align': 'center',
          padding: '0.5rem 1rem',
          'font-weight': 600,
          'font-size': '13px',
          'letter-spacing': '0.01em',
          'border-radius': '8px',
          'margin-bottom': '1.75rem',
        }}
      >
        {meta.data?.read_only_message || t('readonly.banner')}
      </div>
    </Show>
  );
}

const NAV_COLLAPSED_KEY = 'wurk-nav-collapsed';

function prefersReducedMotion() {
  return (
    typeof window !== 'undefined' &&
    window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true
  );
}

// Root layout: the persistent shell (hamburger, main content, nav) that wraps
// every route. Solid Router renders the matched route into `props.children`,
// which lives inside the <Suspense> so lazy chunks fall back to the skeleton.
function Layout(props: ParentProps) {
  const [navOpen, setNavOpen] = createSignal(false);
  // Desktop-only: pin the rail collapsed (icons) or expanded (full), persisted
  // so the choice survives reloads.
  const [collapsed, setCollapsed] = createSignal(
    (() => {
      // localStorage can throw SecurityError / QuotaExceededError in private mode
      // or cross-origin iframes — same guard the write path uses.
      try {
        return typeof localStorage !== 'undefined' && localStorage.getItem(NAV_COLLAPSED_KEY) === '1';
      } catch {
        return false;
      }
    })(),
  );
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

  return (
    <QueryClientProvider client={qc}>
      <div style={{ display: 'flex', 'min-height': '100vh' }}>
        <button
          class="hamburger"
          style={{ position: 'fixed', top: '12px', 'inset-inline-start': '12px', 'z-index': 200 }}
          onClick={() => setNavOpen((o) => !o)}
          aria-label="Toggle navigation"
        >
          <i class="fa-solid fa-bars" />
        </button>

        <main
          class="main-content"
          style={{
            flex: 1,
            padding: '1.5rem',
            // Reserve the rail or full nav width depending on the pinned state;
            // the mobile media query overrides this to 0 (drawer overlay).
            'margin-inline-start': collapsed() ? 'var(--nav-rail)' : 'var(--nav-width)',
            // Match the nav rail exactly (same --dur-page / --ease-emphasized)
            // so the content glides in lockstep with the width change; drop it
            // for users who asked for less motion.
            transition: prefersReducedMotion() ? 'none' : 'margin var(--dur-page) var(--ease-emphasized)',
          }}
        >
          <ReadOnlyBanner />
          <ErrorBoundary>
            <Suspense fallback={<PageSkeleton />}>{props.children}</Suspense>
          </ErrorBoundary>
        </main>

        <Nav
          open={navOpen()}
          onClose={() => setNavOpen(false)}
          collapsed={collapsed()}
          onToggleCollapse={toggleCollapsed}
        />
      </div>
    </QueryClientProvider>
  );
}

export default function App() {
  return (
    <Router root={Layout} base="/wurk">
      <Route path="/" component={Dashboard} />
      <Route path="/queues" component={Queues} />
      <Route path="/retries" component={Retries} />
      <Route path="/scheduled" component={Scheduled} />
      <Route path="/dead" component={Dead} />
      <Route path="/busy" component={Busy} />
      <Route path="/batches" component={Batches} />
      <Route path="/batches/:bid" component={BatchDetail} />
      <Route path="/limiters" component={Limiters} />
      <Route path="/cron" component={Cron} />
      <Route path="/metrics" component={Metrics} />
      <Route path="/profiles" component={Profiles} />
      <Route path="/search" component={Search} />
      <Route path="/ext/:tab" component={Extension} />
    </Router>
  );
}

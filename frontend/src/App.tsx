import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';
import { useSSE } from './hooks/useSSE';
import { useMeta } from './hooks/useMeta';
import { t } from './i18n';
import Nav from './components/Nav';
import Dashboard from './pages/Dashboard';
import Queues from './pages/Queues';
import Retries from './pages/Retries';
import Scheduled from './pages/Scheduled';
import Dead from './pages/Dead';
import Busy from './pages/Busy';
import Batches from './pages/Batches';
import BatchDetail from './pages/BatchDetail';
import Limiters from './pages/Limiters';
import Cron from './pages/Cron';
import Metrics from './pages/Metrics';
import Profiles from './pages/Profiles';
import Search from './pages/Search';

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

export default function App() {
  const [navOpen, setNavOpen] = useState(false);
  const sse = useSSE();

  return (
    <QueryClientProvider client={qc}>
      <BrowserRouter basename="/wurk">
        <div style={{ display: 'flex', minHeight: '100vh' }}>
          <button
            className="hamburger"
            style={{ position: 'fixed', top: 12, left: 12, zIndex: 200 }}
            onClick={() => setNavOpen((o) => !o)}
            aria-label="Toggle navigation"
          >
            <i className="fa-solid fa-bars" />
          </button>

          <main
            className="main-content"
            style={{ flex: 1, padding: '1.5rem', marginLeft: 'var(--nav-width)' }}
          >
            <ReadOnlyBanner />
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
            </Routes>
          </main>

          <Nav open={navOpen} onClose={() => setNavOpen(false)} />
        </div>
      </BrowserRouter>
    </QueryClientProvider>
  );
}

import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';
import { useTheme } from './hooks/useTheme';
import { useSSE } from './hooks/useSSE';
import Nav from './components/Nav';
import Dashboard from './pages/Dashboard';
import Queues from './pages/Queues';
import Retries from './pages/Retries';
import Scheduled from './pages/Scheduled';
import Dead from './pages/Dead';
import Busy from './pages/Busy';
import Batches from './pages/Batches';
import Limiters from './pages/Limiters';
import Cron from './pages/Cron';
import Metrics from './pages/Metrics';
import Search from './pages/Search';

const qc = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 5000,
      retry: 1,
    },
  },
});

export default function App() {
  const { theme, toggle } = useTheme();
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
            ☰
          </button>

          <main
            className="main-content"
            style={{ flex: 1, padding: '1.5rem', marginRight: 'var(--nav-width)' }}
          >
            <Routes>
              <Route path="/" element={<Dashboard sse={sse} />} />
              <Route path="/queues" element={<Queues />} />
              <Route path="/retries" element={<Retries />} />
              <Route path="/scheduled" element={<Scheduled />} />
              <Route path="/dead" element={<Dead />} />
              <Route path="/busy" element={<Busy />} />
              <Route path="/batches" element={<Batches />} />
              <Route path="/limiters" element={<Limiters />} />
              <Route path="/cron" element={<Cron />} />
              <Route path="/metrics" element={<Metrics />} />
              <Route path="/search" element={<Search />} />
            </Routes>
          </main>

          <Nav
            open={navOpen}
            onClose={() => setNavOpen(false)}
            theme={theme}
            onThemeToggle={toggle}
          />
        </div>
      </BrowserRouter>
    </QueryClientProvider>
  );
}

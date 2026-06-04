import { NavLink } from 'react-router-dom';
import { t } from '../i18n';
import logoUrl from '../assets/wurk-logo.png';

interface NavProps {
  open: boolean;
  onClose: () => void;
}

const LINKS = [
  { to: '/', label: t('nav.dashboard'), icon: 'fa-gauge-high', end: true },
  { to: '/queues', label: t('nav.queues'), icon: 'fa-layer-group', end: false },
  { to: '/retries', label: t('nav.retries'), icon: 'fa-rotate-right', end: false },
  { to: '/scheduled', label: t('nav.scheduled'), icon: 'fa-clock', end: false },
  { to: '/dead', label: t('nav.dead'), icon: 'fa-skull', end: false },
  { to: '/busy', label: t('nav.busy'), icon: 'fa-gears', end: false },
  { to: '/batches', label: t('nav.batches'), icon: 'fa-table-cells-large', end: false },
  { to: '/limiters', label: t('nav.limiters'), icon: 'fa-gauge', end: false },
  { to: '/cron', label: t('nav.cron'), icon: 'fa-stopwatch', end: false },
  { to: '/metrics', label: t('nav.metrics'), icon: 'fa-chart-line', end: false },
  { to: '/search', label: t('nav.search'), icon: 'fa-magnifying-glass', end: false },
];

export default function Nav({ open, onClose }: NavProps) {
  return (
    <>
      {/* Overlay for mobile */}
      {open && (
        <div
          onClick={onClose}
          style={{
            position: 'fixed',
            inset: 0,
            background: 'rgba(0,0,0,0.5)',
            zIndex: 99,
            display: 'none',
          }}
          className="nav-overlay"
        />
      )}
      <nav
        className={`wurk-nav${open ? ' wurk-nav--open' : ''}`}
        style={{
          position: 'fixed',
          top: 0,
          left: 0,
          bottom: 0,
          width: 'var(--nav-width)',
          background: 'var(--surface)',
          borderRight: '1px solid var(--border)',
          display: 'flex',
          flexDirection: 'column',
          zIndex: 100,
          overflowY: 'auto',
          transition: 'transform 0.25s ease',
        }}
      >
        <div style={{ padding: '1.25rem 1rem 0.75rem' }}>
          <span
            style={{
              fontSize: 20,
              fontWeight: 800,
              letterSpacing: '-0.03em',
              color: 'var(--text)',
              display: 'flex',
              alignItems: 'center',
              gap: '0.55rem',
            }}
          >
            <img
              src={logoUrl}
              alt="Wurk"
              style={{ height: 48, width: 'auto', display: 'block', filter: 'drop-shadow(0 2px 6px rgba(0,0,0,0.45))' }}
            />
            Wurk
          </span>
        </div>

        <div style={{ height: 1, background: 'var(--border)', margin: '0 1rem 0.5rem' }} />

        <ul style={{ listStyle: 'none', flex: 1 }}>
          {LINKS.map(({ to, label, icon, end }) => (
            <li key={to}>
              <NavLink
                to={to}
                end={end}
                onClick={onClose}
                className="wurk-navlink"
                style={({ isActive }) => ({
                  display: 'flex',
                  alignItems: 'center',
                  gap: '0.625rem',
                  padding: '0.5rem 0.85rem',
                  borderRadius: 8,
                  margin: '2px 8px',
                  color: isActive ? 'var(--accent)' : 'var(--text)',
                  background: isActive ? 'var(--accent-soft)' : 'transparent',
                  boxShadow: isActive
                    ? 'inset 0 0 0 1px color-mix(in oklch, var(--accent) 30%, transparent)'
                    : 'none',
                  fontWeight: isActive ? 600 : 400,
                  fontSize: 14,
                  textDecoration: 'none',
                  transition: 'background 0.15s, color 0.15s, box-shadow 0.15s',
                })}
              >
                <i className={`fa-solid ${icon}`} style={{ fontSize: 14, width: 20, textAlign: 'center' }} />
                <span>{label}</span>
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>

      <style>{`
        .wurk-navlink:hover {
          background: color-mix(in oklch, var(--color-base-content) 8%, transparent) !important;
          color: var(--accent) !important;
          text-decoration: none !important;
        }
        @media (max-width: 767px) {
          .wurk-nav {
            transform: translateX(-100%);
          }
          .wurk-nav--open {
            transform: translateX(0);
          }
          .nav-overlay {
            display: block !important;
          }
        }
        @media (min-width: 768px) {
          .wurk-nav {
            transform: none !important;
          }
        }
      `}</style>
    </>
  );
}

import { NavLink, Link } from 'react-router-dom';
import { t } from '../i18n';
import { useMeta } from '../hooks/useMeta';
import logoUrl from '../assets/wurk-logo.png';

interface NavProps {
  open: boolean;
  onClose: () => void;
  /** Desktop: pinned to the icon-only rail. */
  collapsed: boolean;
  /** Desktop: flip between the icon rail and the full-width nav. */
  onToggleCollapse: () => void;
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
  { to: '/profiles', label: t('nav.profiles'), icon: 'fa-fire', end: false },
  { to: '/search', label: t('nav.search'), icon: 'fa-magnifying-glass', end: false },
];

export default function Nav({ open, onClose, collapsed, onToggleCollapse }: NavProps) {
  // Tabs registered by third-party gems (sidekiq-cron, sidekiq-unique-jobs, …)
  // via Sidekiq::Web.register_extension. They link out to the extension's own
  // path — wurk surfaces the tab but doesn't render the gem's view in the SPA.
  const { data: meta } = useMeta();
  const customTabs = meta?.custom_tabs ?? [];

  // Close the mobile drawer on navigation. The desktop rail no longer expands on
  // hover/focus, so there's nothing to blur back.
  const handleNavClick = () => onClose();

  return (
    <>
      {/* Overlay for mobile */}
      {open && (
        <div
          onClick={handleNavClick}
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
        className={`wurk-nav${open ? ' wurk-nav--open' : ''}${collapsed ? ' wurk-nav--collapsed' : ''}`}
        style={{
          position: 'fixed',
          top: 0,
          insetInlineStart: 0,
          bottom: 0,
          background: 'var(--surface)',
          borderInlineEnd: '1px solid var(--border)',
          display: 'flex',
          flexDirection: 'column',
          zIndex: 100,
          overflowY: 'auto',
          overflowX: 'hidden',
        }}
      >
        <div className="nav-brand-wrap" style={{ padding: '1.25rem 1rem 0.75rem' }}>
          <Link
            to="/"
            onClick={handleNavClick}
            aria-label="Wurk — dashboard home"
            style={{
              color: 'var(--text)',
              textDecoration: 'none',
              display: 'flex',
              alignItems: 'center',
              gap: '0.6rem',
            }}
          >
            <img
              src={logoUrl}
              alt="Wurk"
              style={{ height: 36, width: 'auto', display: 'block', flex: 'none', filter: 'drop-shadow(0 2px 6px rgba(0,0,0,0.45))' }}
            />
            <span className="nav-label" style={{ display: 'flex', flexDirection: 'column', lineHeight: 1.15 }}>
              <span style={{ fontSize: 18, fontWeight: 700, letterSpacing: '-0.02em', color: 'var(--text-bright)' }}>Wurk</span>
              <span
                style={{
                  fontFamily: 'var(--font-mono)',
                  fontSize: 9,
                  fontWeight: 500,
                  letterSpacing: '0.1em',
                  textTransform: 'uppercase',
                  color: 'var(--text-muted)',
                  marginTop: 2,
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 5,
                }}
              >
                <span className="live-dot" style={{ width: 6, height: 6 }} />
                System Status: Active
              </span>
            </span>
          </Link>
        </div>

        <div style={{ height: 1, background: 'var(--border)', margin: '0 1rem 0.5rem' }} />

        <ul style={{ listStyle: 'none', flex: 1 }}>
          {LINKS.map(({ to, label, icon, end }) => (
            <li key={to}>
              <NavLink
                to={to}
                end={end}
                onClick={handleNavClick}
                title={label}
                className="wurk-navlink"
                style={({ isActive }) => ({
                  display: 'flex',
                  alignItems: 'center',
                  gap: '0.625rem',
                  padding: '0.5rem 0.85rem',
                  borderRadius: 8,
                  margin: '2px 8px',
                  // Text stays white for every item; the active one is marked by
                  // a subtle dark raised pill + hairline, not a bright white box.
                  color: isActive ? 'var(--accent)' : 'var(--text)',
                  background: isActive ? 'var(--surface-strong)' : 'transparent',
                  boxShadow: isActive ? 'inset 0 0 0 1px var(--border)' : 'none',
                  fontWeight: isActive ? 600 : 400,
                  fontSize: 14,
                  textDecoration: 'none',
                  transition: 'background 0.15s, color 0.15s, box-shadow 0.15s',
                })}
              >
                <i className={`fa-solid ${icon} wurk-navlink__icon`} aria-hidden="true" />
                <span className="nav-label">{label}</span>
              </NavLink>
            </li>
          ))}

          {customTabs.length > 0 && (
            <li aria-hidden="true" style={{ padding: '0.5rem 0.95rem 0.2rem', marginTop: '0.4rem' }}>
              <div style={{ height: 1, background: 'var(--border)', marginBottom: '0.45rem' }} />
              <span className="nav-label" style={{ fontSize: 10, fontWeight: 600, letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--text-muted)' }}>
                {t('nav.extensions')}
              </span>
            </li>
          )}
          {customTabs.map((tab) => (
            <li key={tab.path}>
              {/* In-SPA route: /ext/:tab renders an Extension page (native
                  server-rendered view, or an iframe for bare tabs[]= tabs).
                  Registered index paths end in "/" ("locks/"); strip it so the
                  route param round-trips to the same tab. */}
              <NavLink
                to={`/ext/${tab.path.replace(/\/+$/, '')}`}
                onClick={handleNavClick}
                title={tab.name}
                className="wurk-navlink"
                style={({ isActive }) => ({
                  display: 'flex',
                  alignItems: 'center',
                  gap: '0.625rem',
                  padding: '0.5rem 0.85rem',
                  borderRadius: 8,
                  margin: '2px 8px',
                  color: isActive ? 'var(--accent)' : 'var(--text)',
                  background: isActive ? 'var(--surface-strong)' : 'transparent',
                  boxShadow: isActive ? 'inset 0 0 0 1px var(--border)' : 'none',
                  fontWeight: isActive ? 600 : 400,
                  fontSize: 14,
                  textDecoration: 'none',
                  transition: 'background 0.15s, color 0.15s, box-shadow 0.15s',
                })}
              >
                <i className="fa-solid fa-puzzle-piece wurk-navlink__icon" aria-hidden="true" />
                <span className="nav-label">{tab.name}</span>
              </NavLink>
            </li>
          ))}
        </ul>

        {/* Desktop-only: pin the rail collapsed (icons) or expanded (full).
            Hidden on mobile, where the nav is a full-width drawer. */}
        <div style={{ height: 1, background: 'var(--border)', margin: '0.5rem 1rem 0' }} />
        <button
          type="button"
          onClick={onToggleCollapse}
          className="nav-collapse-toggle"
          aria-label={collapsed ? t('nav.expand') : t('nav.collapse')}
          aria-expanded={!collapsed}
          title={collapsed ? t('nav.expand') : t('nav.collapse')}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '0.625rem',
            width: 'calc(100% - 16px)',
            padding: '0.5rem 0.85rem',
            margin: '4px 8px',
            borderRadius: 8,
            border: 'none',
            background: 'transparent',
            color: 'var(--text-muted)',
            fontSize: 13,
            cursor: 'pointer',
            font: 'inherit',
          }}
        >
          <i
            className={`fa-solid ${collapsed ? 'fa-angles-right' : 'fa-angles-left'} wurk-navlink__icon`}
            aria-hidden="true"
          />
          <span className="nav-label">{t('nav.collapse')}</span>
        </button>

        {/* Footer: link out to the source repo. Pinned to the bottom because the
            nav list above is flex:1. Muted by default; hover lifts like a nav item. */}
        <div style={{ height: 1, background: 'var(--border)', margin: '0.5rem 1rem' }} />
        <a
          href="https://github.com/developerz-ai/wurk"
          target="_blank"
          rel="noopener noreferrer"
          className="wurk-navlink"
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '0.625rem',
            padding: '0.5rem 0.85rem',
            margin: '2px 8px 0.85rem',
            borderRadius: 8,
            color: 'var(--text-muted)',
            fontSize: 13,
            textDecoration: 'none',
            transition: 'background 0.15s, color 0.15s',
          }}
        >
          <i className="fa-brands fa-github" style={{ fontSize: 16, width: 20, textAlign: 'center', flex: 'none' }} />
          <span className="nav-label">GitHub</span>
        </a>
      </nav>

      <style>{`
        .wurk-nav { width: var(--nav-width); transition: width 0.2s ease; }
        .wurk-navlink:hover {
          background: var(--surface-hover) !important;
          color: var(--accent) !important;
          text-decoration: none !important;
        }
        /* The collapse toggle is a control, not a nav item — it only shifts
           colour on hover, no filled pill/active box. */
        .nav-collapse-toggle:hover { color: var(--text) !important; }
        .nav-label { white-space: nowrap; }
        .wurk-navlink__icon { width: 24px; font-size: 18px; text-align: center; flex: none; transition: background 0.15s ease, color 0.15s ease, transform 0.18s ease; }
        /* Subtle lift on hover so the nav feels reactive. */
        .wurk-navlink:hover .wurk-navlink__icon { transform: scale(1.12); }
        @media (prefers-reduced-motion: reduce) {
          .wurk-navlink__icon { transition: background 0.15s ease, color 0.15s ease; }
          .wurk-navlink:hover .wurk-navlink__icon { transform: none; }
        }
        @media (max-width: 767px) {
          .wurk-nav {
            transform: translateX(-100%);
            transition: transform 0.25s ease;
          }
          .wurk-nav--open {
            transform: translateX(0);
          }
          /* RTL: the rail is pinned to the right edge, so it slides off to the
             right when closed. */
          [dir="rtl"] .wurk-nav {
            transform: translateX(100%);
          }
          [dir="rtl"] .wurk-nav--open {
            transform: translateX(0);
          }
          .nav-overlay {
            display: block !important;
          }
          /* The collapse control is desktop-only; on mobile the nav is a
             full-width drawer toggled by the hamburger. */
          .nav-collapse-toggle { display: none !important; }
        }
        /* Desktop: a fixed-width rail the user pins open or collapsed (icons only)
           via the toggle button — no hover-driven movement. The width change
           animates; prefers-reduced-motion drops the animation. */
        @media (min-width: 768px) {
          .wurk-nav { transform: none !important; }
          .wurk-nav--collapsed { width: var(--nav-rail); }
          /* !important: the brand wordmark span carries an inline display:flex,
             which a plain class rule can't beat — without this the "Wurk /
             System Status" text stays rendered in the 64px rail and gets clipped. */
          .wurk-nav--collapsed .nav-label { display: none !important; }
          /* Collapsed: center each icon. The glyph lives in a FIXED 38px round
             container at all times, so idle → hover → active only swaps its
             background colour, never its size — the icon never shifts when you
             click it, and the highlight is always a circle, never a square link
             box. Tight link padding keeps the icons from drifting apart. */
          /* !important: the NavLink carries an inline padding (0.5rem 0.85rem)
             that outranks any class rule. Zero it in the rail so the fixed-size
             round glyph container — not link padding — defines the footprint;
             the horizontal inline padding would otherwise cramp the circle in
             the 64px rail and make it shift when the active background appears. */
          .wurk-nav--collapsed .wurk-navlink,
          .wurk-nav--collapsed .nav-collapse-toggle { justify-content: center; padding: 0 !important; }
          .wurk-nav--collapsed .wurk-navlink__icon {
            display: grid;
            place-items: center;
            width: 36px;
            height: 36px;
            border-radius: 50%;
          }
          /* The link/button never fills — the round glyph container carries the
             highlight instead of a boxy pill. */
          .wurk-nav--collapsed .wurk-navlink:hover,
          .wurk-nav--collapsed .wurk-navlink.active {
            background: transparent !important;
            box-shadow: none !important;
          }
          .wurk-nav--collapsed .wurk-navlink:hover .wurk-navlink__icon {
            background: var(--surface-hover);
            color: var(--accent);
          }
          .wurk-nav--collapsed .wurk-navlink.active .wurk-navlink__icon {
            background: var(--surface-strong);
            box-shadow: inset 0 0 0 1px var(--border);
            color: var(--accent);
          }
          /* Collapsed: drop the wordmark and show just the logo mark, centered
             with balanced padding so it sits squarely in the rail instead of
             hugging the top-left. */
          .wurk-nav--collapsed .nav-brand-wrap { padding: 0.9rem 0; }
          .wurk-nav--collapsed .nav-brand-wrap a { justify-content: center; gap: 0; }
          .wurk-nav--collapsed .nav-brand-wrap img { height: 38px !important; }
        }
        @media (min-width: 768px) and (prefers-reduced-motion: reduce) {
          .wurk-nav { transition: none; }
        }
      `}</style>
    </>
  );
}

import type { MouseEvent } from 'react';
import { NavLink, Link } from 'react-router-dom';
import { t } from '../i18n';
import { useMeta } from '../hooks/useMeta';
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
  { to: '/profiles', label: t('nav.profiles'), icon: 'fa-fire', end: false },
  { to: '/search', label: t('nav.search'), icon: 'fa-magnifying-glass', end: false },
];

export default function Nav({ open, onClose }: NavProps) {
  // Tabs registered by third-party gems (sidekiq-cron, sidekiq-unique-jobs, …)
  // via Sidekiq::Web.register_extension. They link out to the extension's own
  // path — wurk surfaces the tab but doesn't render the gem's view in the SPA.
  const { data: meta } = useMeta();
  const customTabs = meta?.custom_tabs ?? [];

  // Close the mobile drawer AND drop focus so the desktop rail collapses back
  // after a click — otherwise :focus-within keeps it expanded until you click
  // elsewhere.
  const handleNavClick = (e: MouseEvent<HTMLElement>) => {
    onClose();
    e.currentTarget.blur();
  };

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
        className={`wurk-nav${open ? ' wurk-nav--open' : ''}`}
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
        .wurk-nav { width: var(--nav-width); }
        .wurk-navlink:hover {
          background: var(--surface-hover) !important;
          color: var(--accent) !important;
          text-decoration: none !important;
        }
        .nav-label { white-space: nowrap; }
        .wurk-navlink__icon { width: 24px; font-size: 18px; text-align: center; flex: none; }
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
        }
        /* Desktop: a collapsed icon rail that expands to the full width on hover
           or keyboard focus, overlaying the content (which reserves only the rail
           width). prefers-reduced-motion drops the width animation. */
        @media (min-width: 768px) {
          .wurk-nav {
            transform: none !important;
            width: var(--nav-rail);
            transition: width 0.2s ease;
          }
          .wurk-nav:hover,
          .wurk-nav:focus-within {
            width: var(--nav-width);
            box-shadow: 10px 0 28px rgba(0, 0, 0, 0.5);
          }
          /* !important: the brand wordmark span carries an inline display:flex,
             which a plain class rule can't beat — without this the "Wurk /
             System Status" text stays rendered in the 64px rail and gets clipped. */
          .wurk-nav:not(:hover):not(:focus-within) .nav-label { display: none !important; }
          /* Collapsed: center each icon and give it roomy, even padding so the
             rail breathes. Icon size stays the SAME as the expanded state — only
             the surrounding space changes, so glyphs don't jump/resize on hover. */
          .wurk-nav:not(:hover):not(:focus-within) .wurk-navlink { justify-content: center; padding: 0.7rem 0; }
          .wurk-nav:not(:hover):not(:focus-within) .wurk-navlink__icon { width: auto; }
          /* Collapsed active item: the rectangular pill (set via inline styles)
             would look boxy in the narrow rail, so flatten the link and draw a
             round highlight around just the glyph instead. */
          .wurk-nav:not(:hover):not(:focus-within) .wurk-navlink.active {
            background: transparent !important;
            box-shadow: none !important;
          }
          .wurk-nav:not(:hover):not(:focus-within) .wurk-navlink.active .wurk-navlink__icon {
            display: grid;
            place-items: center;
            width: 38px;
            height: 38px;
            border-radius: 50%;
            background: var(--surface-strong);
            box-shadow: inset 0 0 0 1px var(--border);
            color: var(--accent);
          }
          /* Collapsed: drop the wordmark and show just the logo mark, centered
             with balanced padding so it sits squarely in the rail instead of
             hugging the top-left. */
          .wurk-nav:not(:hover):not(:focus-within) .nav-brand-wrap { padding: 0.9rem 0; }
          .wurk-nav:not(:hover):not(:focus-within) .nav-brand-wrap a { justify-content: center; gap: 0; }
          .wurk-nav:not(:hover):not(:focus-within) .nav-brand-wrap img { height: 38px !important; }
        }
        @media (min-width: 768px) and (prefers-reduced-motion: reduce) {
          .wurk-nav { transition: none; }
        }
      `}</style>
    </>
  );
}

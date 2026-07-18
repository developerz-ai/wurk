import { A } from '@solidjs/router';
import { For, Show } from 'solid-js';
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

export default function Nav(props: NavProps) {
  // Tabs registered by third-party gems (sidekiq-cron, sidekiq-unique-jobs, …)
  // via Sidekiq::Web.register_extension. They link out to the extension's own
  // path — wurk surfaces the tab but doesn't render the gem's view in the SPA.
  const meta = useMeta();
  const customTabs = () => meta.data?.custom_tabs ?? [];

  // Close the mobile drawer on navigation. The desktop rail no longer expands on
  // hover/focus, so there's nothing to blur back.
  const handleNavClick = () => props.onClose();

  return (
    <>
      {/* Overlay for mobile */}
      <Show when={props.open}>
        <div
          onClick={handleNavClick}
          style={{
            position: 'fixed',
            inset: 0,
            background: 'rgba(0,0,0,0.5)',
            'z-index': 99,
            display: 'none',
          }}
          class="nav-overlay"
        />
      </Show>
      <nav
        classList={{
          'wurk-nav': true,
          'wurk-nav--open': props.open,
          'wurk-nav--collapsed': props.collapsed,
        }}
        style={{
          position: 'fixed',
          top: 0,
          'inset-inline-start': 0,
          bottom: 0,
          background: 'var(--surface)',
          'border-inline-end': '1px solid var(--border)',
          display: 'flex',
          'flex-direction': 'column',
          'z-index': 100,
          'overflow-y': 'auto',
          'overflow-x': 'hidden',
        }}
      >
        <div class="nav-brand-wrap" style={{ padding: '1.25rem 1rem 0.75rem' }}>
          <A
            href="/"
            end
            onClick={handleNavClick}
            aria-label="Wurk — dashboard home"
            style={{
              color: 'var(--text)',
              'text-decoration': 'none',
              display: 'flex',
              'align-items': 'center',
              gap: '0.6rem',
            }}
          >
            <img
              src={logoUrl}
              alt="Wurk"
              style={{
                height: '36px',
                width: 'auto',
                display: 'block',
                flex: 'none',
                filter: 'drop-shadow(0 2px 6px rgba(0,0,0,0.45))',
              }}
            />
            <span class="nav-label" style={{ display: 'flex', 'flex-direction': 'column', 'line-height': 1.15 }}>
              <span style={{ display: 'inline-flex', 'align-items': 'baseline', gap: '0.4rem' }}>
                <span style={{ 'font-size': '18px', 'font-weight': 700, 'letter-spacing': '-0.02em', color: 'var(--text-bright)' }}>
                  Wurk
                </span>
                {/* Gem version from <mount>/api/meta, next to the wordmark. */}
                <Show when={meta.data?.version}>
                  <span
                    style={{
                      'font-family': 'var(--font-mono)',
                      'font-size': '10px',
                      'font-weight': 500,
                      'letter-spacing': '0.02em',
                      color: 'var(--text-muted)',
                      background: 'var(--surface-strong)',
                      border: '1px solid var(--border)',
                      'border-radius': '5px',
                      padding: '0.05rem 0.3rem',
                    }}
                  >
                    v{meta.data?.version}
                  </span>
                </Show>
              </span>
              <span
                style={{
                  'font-family': 'var(--font-mono)',
                  'font-size': '9px',
                  'font-weight': 500,
                  'letter-spacing': '0.1em',
                  'text-transform': 'uppercase',
                  color: 'var(--text-muted)',
                  'margin-top': '2px',
                  display: 'inline-flex',
                  'align-items': 'center',
                  gap: '5px',
                }}
              >
                <span class="live-dot" style={{ width: '6px', height: '6px' }} />
                {t('nav.status_active')}
              </span>
            </span>
          </A>
        </div>

        <div style={{ height: '1px', background: 'var(--border)', margin: '0 1rem 0.5rem' }} />

        <ul style={{ 'list-style': 'none', flex: 1 }}>
          <For each={LINKS}>
            {(link) => (
              <li>
                <A
                  href={link.to}
                  end={link.end}
                  onClick={handleNavClick}
                  title={link.label}
                  class="wurk-navlink"
                  activeClass="active"
                >
                  <i class={`fa-solid ${link.icon} wurk-navlink__icon`} aria-hidden="true" />
                  <span class="nav-label">{link.label}</span>
                </A>
              </li>
            )}
          </For>

          <Show when={customTabs().length > 0}>
            <li aria-hidden="true" style={{ padding: '0.5rem 0.95rem 0.2rem', 'margin-top': '0.4rem' }}>
              <div style={{ height: '1px', background: 'var(--border)', 'margin-bottom': '0.45rem' }} />
              <span
                class="nav-label"
                style={{ 'font-size': '10px', 'font-weight': 600, 'letter-spacing': '0.06em', 'text-transform': 'uppercase', color: 'var(--text-muted)' }}
              >
                {t('nav.extensions')}
              </span>
            </li>
          </Show>
          <For each={customTabs()}>
            {(tab) => (
              <li>
                {/* In-SPA route: /ext/:tab renders an Extension page (native
                    server-rendered view, or an iframe for bare tabs[]= tabs).
                    Registered index paths end in "/" ("locks/"); strip it so the
                    route param round-trips to the same tab. */}
                <A
                  href={`/ext/${tab.path.replace(/\/+$/, '')}`}
                  onClick={handleNavClick}
                  title={tab.name}
                  class="wurk-navlink"
                  activeClass="active"
                >
                  <i class="fa-solid fa-puzzle-piece wurk-navlink__icon" aria-hidden="true" />
                  <span class="nav-label">{tab.name}</span>
                </A>
              </li>
            )}
          </For>
        </ul>

        {/* Desktop-only: pin the rail collapsed (icons) or expanded (full).
            Hidden on mobile, where the nav is a full-width drawer. */}
        <div style={{ height: '1px', background: 'var(--border)', margin: '0.5rem 1rem 0' }} />
        <button
          type="button"
          onClick={() => props.onToggleCollapse()}
          class="nav-collapse-toggle"
          aria-label={props.collapsed ? t('nav.expand') : t('nav.collapse')}
          aria-expanded={!props.collapsed}
          title={props.collapsed ? t('nav.expand') : t('nav.collapse')}
          style={{
            display: 'flex',
            'align-items': 'center',
            gap: '0.625rem',
            width: 'calc(100% - 16px)',
            padding: '0.5rem 0.85rem',
            margin: '4px 8px',
            'border-radius': '8px',
            border: 'none',
            background: 'transparent',
            color: 'var(--text-muted)',
            'font-size': '13px',
            cursor: 'pointer',
            font: 'inherit',
          }}
        >
          <i
            class={`fa-solid ${props.collapsed ? 'fa-angles-right' : 'fa-angles-left'} wurk-navlink__icon`}
            aria-hidden="true"
          />
          <span class="nav-label">{t('nav.collapse')}</span>
        </button>

        {/* Footer: link out to the source repo. Pinned to the bottom because the
            nav list above is flex:1. Muted by default; hover lifts like a nav item. */}
        <div style={{ height: '1px', background: 'var(--border)', margin: '0.5rem 1rem' }} />
        <a
          href="https://github.com/developerz-ai/wurk"
          target="_blank"
          rel="noopener noreferrer"
          class="wurk-navlink"
          style={{
            display: 'flex',
            'align-items': 'center',
            gap: '0.625rem',
            padding: '0.5rem 0.85rem',
            margin: '2px 8px 0.85rem',
            'border-radius': '8px',
            color: 'var(--text-muted)',
            'font-size': '13px',
            'text-decoration': 'none',
            transition: 'background var(--dur-base) var(--ease-standard), color var(--dur-base) var(--ease-standard)',
          }}
        >
          <i class="fa-brands fa-github" style={{ 'font-size': '16px', width: '20px', 'text-align': 'center', flex: 'none' }} />
          <span class="nav-label">GitHub</span>
        </a>
      </nav>

      <style>{`
        .wurk-nav { width: var(--nav-width); transition: width var(--dur-page) var(--ease-emphasized); }
        /* Base nav-item chrome (was an inline style function under React; Solid's
           <A> toggles the .active class, so the active look lives in CSS now). */
        .wurk-navlink {
          display: flex;
          align-items: center;
          gap: 0.625rem;
          padding: 0.5rem 0.85rem;
          border-radius: 8px;
          margin: 2px 8px;
          color: var(--text);
          background: transparent;
          box-shadow: none;
          font-weight: 400;
          font-size: 14px;
          text-decoration: none;
          transition: background var(--dur-base) var(--ease-standard), color var(--dur-base) var(--ease-standard), box-shadow var(--dur-base) var(--ease-standard);
        }
        /* Text stays white for every item; the active one is marked by a subtle
           dark raised pill + hairline, not a bright white box. */
        .wurk-navlink.active {
          color: var(--accent);
          background: var(--surface-strong);
          box-shadow: inset 0 0 0 1px var(--border);
          font-weight: 600;
        }
        .wurk-navlink:hover {
          background: var(--surface-hover) !important;
          color: var(--accent) !important;
          text-decoration: none !important;
        }
        /* The collapse toggle is a control, not a nav item — it only shifts
           colour on hover, no filled pill/active box. */
        .nav-collapse-toggle:hover { color: var(--text) !important; }
        .nav-label { white-space: nowrap; }
        .wurk-navlink__icon { width: 24px; font-size: 18px; text-align: center; flex: none; transition: background var(--dur-base) var(--ease-standard), color var(--dur-base) var(--ease-standard), transform var(--dur-base) var(--ease-standard); }
        /* Subtle lift on hover so the nav feels reactive. */
        .wurk-navlink:hover .wurk-navlink__icon { transform: scale(1.12); }
        @media (prefers-reduced-motion: reduce) {
          .wurk-navlink__icon { transition: background var(--dur-base) var(--ease-standard), color var(--dur-base) var(--ease-standard); }
          .wurk-navlink:hover .wurk-navlink__icon { transform: none; }
        }
        @media (max-width: 767px) {
          .wurk-nav {
            transform: translateX(-100%);
            transition: transform var(--dur-slow) var(--ease-standard);
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
          /* !important: the <A> carries an inline padding (0.5rem 0.85rem)
             that outranks any class rule. Zero it in the rail so the fixed-size
             round glyph container — not link padding — defines the footprint;
             the horizontal inline padding would otherwise cramp the circle in
             the 64px rail and make it shift when the active background appears.
             width/margin pin each control to a fixed rail-width box anchored at
             the nav's start edge, so the centred glyph sits on a constant x
             (rail/2). Without this, justify-content:center re-centres against the
             *animating* nav width (248→64px), so the icons leap right on collapse
             and glide back — a visible jump (#272 follow-up). */
          .wurk-nav--collapsed .wurk-navlink,
          .wurk-nav--collapsed .nav-collapse-toggle {
            justify-content: center;
            width: var(--nav-rail) !important;
            margin-inline: 0 !important;
            padding: 0 !important;
          }
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
          /* !important: the wrap carries an inline padding (1.25rem 1rem 0.75rem)
             whose 1rem sides a plain class rule can't beat — leaving it in place
             offsets the fixed-width brand box below by 16px, so the centred logo
             lands right-of-centre in the rail. Zero the sides so the box anchors
             at the nav's start edge and the logo sits on the rail mid-line. */
          .wurk-nav--collapsed .nav-brand-wrap { padding: 0.9rem 0 !important; }
          /* Same fixed rail-width box as the nav controls above, so the logo
             centres on the constant rail mid-line instead of leaping right
             against the animating nav width on collapse. */
          .wurk-nav--collapsed .nav-brand-wrap a { justify-content: center; gap: 0; width: var(--nav-rail); }
          .wurk-nav--collapsed .nav-brand-wrap img { height: 38px !important; }
        }
        @media (min-width: 768px) and (prefers-reduced-motion: reduce) {
          .wurk-nav { transition: none; }
        }
      `}</style>
    </>
  );
}

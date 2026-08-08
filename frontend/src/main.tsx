import { render } from 'solid-js/web';
// Obsidian design system fonts, self-hosted in the bundle (no CDN / Node at
// runtime). Geist for UI text + metrics, JetBrains Mono for labels/metadata.
import '@fontsource/geist-sans/400.css';
import '@fontsource/geist-sans/500.css';
import '@fontsource/geist-sans/600.css';
import '@fontsource/geist-sans/700.css';
import '@fontsource/jetbrains-mono/500.css';
// Tailwind/daisyUI directives first, then the hand-authored SCSS system whose
// unlayered `:root` tokens override daisyUI's theme (see styles/main.scss).
import './tailwind.css';
import './styles/main.scss';
import App from './App';
import { applyLocale, locale, t } from './i18n';

// Set text direction + language from the resolved locale before first paint so
// the whole SPA (and its logical-property CSS) lays out RTL for ar/he/fa. This
// module is deferred, so #wurk-root already exists and gets its `dir` here too.
applyLocale(locale);

// When this SPA is loaded inside the Extension page's embed iframe (see
// pages/Extension.tsx), the host did NOT mount real content at the extension's
// path — wurk's catch-all served the SPA instead. Paint a small stub rather
// than recursively nesting the whole dashboard.
const embedded =
  window.self !== window.top &&
  new URLSearchParams(window.location.search).has('wurk_ext_embed');

const root = document.getElementById('wurk-root');
if (root) {
  // Solid's render takes a component factory (a function returning JSX), not an
  // element — it establishes the reactive root that owns the whole app.
  render(
    () =>
      embedded ? (
        <div
          style={{
            padding: '2rem',
            'text-align': 'center',
            color: 'var(--text-muted)',
            'font-size': '14px',
            'line-height': 1.6,
          }}
        >
          {t('extension.notRendered')}
        </div>
      ) : (
        <App />
      ),
    root,
  );
}

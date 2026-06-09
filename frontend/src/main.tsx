import React from 'react';
import ReactDOM from 'react-dom/client';
import './styles.css';
import App from './App';
import { dir, locale, t } from './i18n';

// Set text direction + language from the detected locale before first paint so
// the whole SPA (and its logical-property CSS) lays out RTL for ar/he/fa.
document.documentElement.dir = dir;
document.documentElement.lang = locale;

// When this SPA is loaded inside the Extension page's embed iframe (see
// pages/Extension.tsx), the host did NOT mount real content at the extension's
// path — wurk's catch-all served the SPA instead. Paint a small stub rather
// than recursively nesting the whole dashboard.
const embedded =
  window.self !== window.top &&
  new URLSearchParams(window.location.search).has('wurk_ext_embed');

const root = document.getElementById('wurk-root');
if (root) {
  root.dir = dir;
  ReactDOM.createRoot(root).render(
    embedded ? (
      <div style={{ padding: '2rem', textAlign: 'center', color: 'var(--text-muted)', fontSize: 14, lineHeight: 1.6 }}>
        {t('extension.notRendered')}
      </div>
    ) : (
      <React.StrictMode>
        <App />
      </React.StrictMode>
    )
  );
}

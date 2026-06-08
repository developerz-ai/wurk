import React from 'react';
import ReactDOM from 'react-dom/client';
import './styles.css';
import App from './App';
import { dir, locale } from './i18n';

// Set text direction + language from the detected locale before first paint so
// the whole SPA (and its logical-property CSS) lays out RTL for ar/he/fa.
document.documentElement.dir = dir;
document.documentElement.lang = locale;

const root = document.getElementById('wurk-root');
if (root) {
  root.dir = dir;
  ReactDOM.createRoot(root).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>
  );
}

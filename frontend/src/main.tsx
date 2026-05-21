import React from 'react';
import ReactDOM from 'react-dom/client';
import './styles.css';
import App from './App';

const root = document.getElementById('wurk-root');
if (root) {
  ReactDOM.createRoot(root).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>
  );
}

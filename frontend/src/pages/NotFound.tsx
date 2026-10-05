import { onMount } from 'solid-js';
import { A } from '@solidjs/router';
import { PageHeader } from '../components/PageHeader';
import { t } from '../i18n';

// Catch-all route: an unknown dashboard path (a stale bookmark, a Sidekiq URL
// with no Wurk equivalent) gets a way home instead of a blank main pane.
export default function NotFound() {
  onMount(() => {
    document.title = `${t('notfound.title')} — Wurk`;
  });

  return (
    <div>
      <PageHeader icon="fa-compass" title={t('notfound.title')} summary={t('notfound.hint')} />
      <div class="empty-state">
        <A href="/" class="btn btn-accent">
          {t('notfound.home')}
        </A>
      </div>
    </div>
  );
}

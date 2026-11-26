import { Show } from 'solid-js';
import { useIsRouting } from '@solidjs/router';
import { t } from '../i18n';

// Feedback on the click while the router holds the old page for a new one: a
// page chunk not loaded yet (pageChunks.ts preloads them, but a click can
// beat that). A thin bar along the top, not a skeleton over a page that is
// still valid.
export default function RouteProgress() {
  const routing = useIsRouting();
  return (
    <Show when={routing()}>
      <div class="route-progress" role="progressbar" aria-busy="true" aria-label={t('common.loading')} />
    </Show>
  );
}

import { Show } from 'solid-js';
import { t } from '../i18n';
import Icon from './Icon';

// Inline notice for a polled page whose latest refetch failed while an earlier
// payload is still cached. The page keeps rendering that payload (and any open
// modal) instead of swapping to the full error state on one dropped poll.
export function RefreshError(props: { when: boolean }) {
  return (
    <Show when={props.when}>
      <div class="health-notice health-notice--warning refresh-error" role="alert">
        <Icon name="triangle-exclamation" />
        <span>{t('common.refresh_failed')}</span>
      </div>
    </Show>
  );
}

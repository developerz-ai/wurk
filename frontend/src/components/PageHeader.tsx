import { Show, type JSX } from 'solid-js';
import type { IconName } from '../icons';
import Icon from './Icon';

interface PageHeaderProps {
  /** The page's icon, e.g. `layer-group` (matches the nav). */
  icon: IconName;
  title: string;
  summary: string;
  /** Optional right-aligned slot — typically the count badge. */
  children?: JSX.Element;
}

// Consistent header for each tab page: the tab's icon, its title, and a one-line
// summary of what the page shows. Keeps every page oriented and on-brand.
export function PageHeader(props: PageHeaderProps) {
  return (
    <div class="page-header">
      <span class="page-header__icon">
        <Icon name={props.icon} />
      </span>
      <div class="page-header__text">
        <h1 class="page-header__title">{props.title}</h1>
        <p class="page-header__summary">{props.summary}</p>
      </div>
      <Show when={props.children != null}>
        <div class="page-header__aside">{props.children}</div>
      </Show>
    </div>
  );
}

import panes from './navPanes.json';
import { t } from './i18n';

/** One entry of the dashboard's shipped navigation. */
export interface NavPane {
  to: string;
  labelKey: string;
  icon: string;
  end: boolean;
}

/**
 * The shipped panes, in rail order — the one inventory in the repo. Consumers
 * read it instead of restating the list, so a pane added or renamed here
 * reaches the nav and its drift checks in one place.
 */
export const NAV_PANES: readonly NavPane[] = Object.freeze(panes);

/** The pane's display name in the active locale. */
export function paneLabel(pane: NavPane): string {
  return t(pane.labelKey);
}

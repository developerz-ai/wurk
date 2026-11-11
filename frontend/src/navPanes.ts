import panes from './navPanes.json';
import { t } from './i18n';
import type { IconName } from './icons';

/** One entry of the dashboard's shipped navigation. */
export interface NavPane {
  to: string;
  labelKey: string;
  icon: IconName;
  end: boolean;
}

/**
 * The shipped panes, in rail order — the one inventory in the repo. Consumers
 * read it instead of restating the list, so a pane added or renamed here
 * reaches the nav and its drift checks in one place.
 */
// JSON imports type `icon` as plain string; navPanes.test.ts checks every
// entry against the shipped glyphs, which is what this cast asserts.
export const NAV_PANES: readonly NavPane[] = Object.freeze(panes as NavPane[]);

/** The pane's display name in the active locale. */
export function paneLabel(pane: NavPane): string {
  return t(pane.labelKey);
}

import { For } from 'solid-js';
import { t } from '../i18n';
import { formatNumber } from '../utils';

// One button's worth of config: the wire `cmd`, its localized label, whether
// it's destructive (red + confirm), and the count it'd act on (drives the
// disabled state for bulk buttons).
export interface ActionDef {
  cmd: string;
  label: string;
  danger?: boolean;
}

interface JobSetActionBarProps {
  bulk: ActionDef[];
  all: ActionDef[];
  selectedCount: number;
  total: number;
  // A filter is narrowing the table: the "all" buttons then act on what it
  // matches across the whole set, not just this page, and say so.
  filtered?: boolean;
  // Rows matching the active filter, preformatted ("1,204" / "20,000+").
  matching?: string;
  // Entries a running filtered sweep has acted on so far.
  progress?: number | null;
  pending: boolean;
  onBulk: (cmd: string) => void;
  onAll: (cmd: string) => void;
}

// Toolbar shown above a mutable job-set table: bulk actions over the current
// selection on the left, whole-set ("all") actions on the right. Rendered only
// when the dashboard is read-write — callers gate on useMeta().read_only.
export default function JobSetActionBar(props: JobSetActionBarProps) {
  // Destructive actions confirm; so does any action over a filter's matches,
  // which reaches rows the operator cannot see on this page.
  const confirmDanger = (a: ActionDef, scope: string, always = false) =>
    (!a.danger && !always) || window.confirm(t('actions.confirm', { action: a.label, scope }));
  const allScope = () =>
    props.filtered ? t('actions.scope_matching', { n: props.matching ?? '?' }) : t('actions.scope_all');

  return (
    <div class="action-bar">
      <div class="action-bar-group">
        <span class="action-bar-count">
          {props.progress != null
            ? t('actions.sweeping', { n: formatNumber(props.progress) })
            : props.selectedCount > 0
            ? t('actions.selected', { n: props.selectedCount })
            : props.filtered && props.matching !== undefined
              ? t('actions.matching', { n: props.matching })
              : t('actions.select_hint')}
        </span>
        <For each={props.bulk}>
          {(a) => (
            <button
              class={`btn btn-sm${a.danger ? ' btn-danger' : ''}`}
              disabled={props.pending || props.selectedCount === 0}
              onClick={() => confirmDanger(a, t('actions.scope_selected', { n: props.selectedCount })) && props.onBulk(a.cmd)}
            >
              {a.label}
            </button>
          )}
        </For>
      </div>
      <div class="action-bar-group">
        <For each={props.all}>
          {(a) => (
            <button
              class={`btn btn-sm btn-ghost${a.danger ? ' btn-danger' : ''}`}
              disabled={props.pending || props.total === 0}
              onClick={() => confirmDanger(a, allScope(), props.filtered) && props.onAll(a.cmd)}
            >
              {`${a.label} ${props.filtered ? t('actions.matching_suffix') : t('actions.all_suffix')}`}
            </button>
          )}
        </For>
      </div>
    </div>
  );
}

import { For } from 'solid-js';
import { t } from '../i18n';

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
  pending: boolean;
  onBulk: (cmd: string) => void;
  onAll: (cmd: string) => void;
}

// Toolbar shown above a mutable job-set table: bulk actions over the current
// selection on the left, whole-set ("all") actions on the right. Rendered only
// when the dashboard is read-write — callers gate on useMeta().read_only.
export default function JobSetActionBar(props: JobSetActionBarProps) {
  const confirmDanger = (a: ActionDef, scope: string) =>
    !a.danger || window.confirm(t('actions.confirm', { action: a.label, scope }));

  return (
    <div class="action-bar">
      <div class="action-bar-group">
        <span class="action-bar-count">
          {props.selectedCount > 0 ? t('actions.selected', { n: props.selectedCount }) : t('actions.select_hint')}
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
              onClick={() => confirmDanger(a, t('actions.scope_all')) && props.onAll(a.cmd)}
            >
              {`${a.label} ${t('actions.all_suffix')}`}
            </button>
          )}
        </For>
      </div>
    </div>
  );
}

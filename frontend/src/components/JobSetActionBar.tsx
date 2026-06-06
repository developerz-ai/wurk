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
export default function JobSetActionBar({
  bulk,
  all,
  selectedCount,
  total,
  pending,
  onBulk,
  onAll,
}: JobSetActionBarProps) {
  const confirmDanger = (a: ActionDef, scope: string) =>
    !a.danger || window.confirm(t('actions.confirm', { action: a.label, scope }));

  return (
    <div className="action-bar">
      <div className="action-bar-group">
        <span className="action-bar-count">
          {selectedCount > 0 ? t('actions.selected', { n: selectedCount }) : t('actions.select_hint')}
        </span>
        {bulk.map((a) => (
          <button
            key={a.cmd}
            className={`btn btn-sm${a.danger ? ' btn-danger' : ''}`}
            disabled={pending || selectedCount === 0}
            onClick={() => confirmDanger(a, t('actions.scope_selected', { n: selectedCount })) && onBulk(a.cmd)}
          >
            {a.label}
          </button>
        ))}
      </div>
      <div className="action-bar-group">
        {all.map((a) => (
          <button
            key={a.cmd}
            className={`btn btn-sm btn-ghost${a.danger ? ' btn-danger' : ''}`}
            disabled={pending || total === 0}
            onClick={() => confirmDanger(a, t('actions.scope_all')) && onAll(a.cmd)}
          >
            {`${a.label} ${t('actions.all_suffix')}`}
          </button>
        ))}
      </div>
    </div>
  );
}

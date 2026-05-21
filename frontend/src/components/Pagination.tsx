import { t } from '../i18n';

interface PaginationProps {
  page: number;
  total: number;
  count: number;
  onChange: (p: number) => void;
}

export function Pagination({ page, total, count, onChange }: PaginationProps) {
  const totalPages = Math.max(1, Math.ceil(total / count));

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '0.75rem',
        padding: '0.75rem 0',
        justifyContent: 'flex-end',
        color: 'var(--text-muted)',
        fontSize: 13,
      }}
    >
      <button
        className="btn"
        disabled={page <= 1}
        onClick={() => onChange(page - 1)}
        style={{ opacity: page <= 1 ? 0.4 : 1 }}
      >
        {t('actions.prev')}
      </button>
      <span>
        {t('common.page')} {page} {t('common.of')} {totalPages}
      </span>
      <button
        className="btn"
        disabled={page >= totalPages}
        onClick={() => onChange(page + 1)}
        style={{ opacity: page >= totalPages ? 0.4 : 1 }}
      >
        {t('actions.next')}
      </button>
    </div>
  );
}

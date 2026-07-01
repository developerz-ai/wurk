import { t } from '../i18n';

interface PaginationProps {
  page: number;
  total: number;
  count: number;
  onChange: (p: number) => void;
}

export function Pagination(props: PaginationProps) {
  const totalPages = () => Math.max(1, Math.ceil(props.total / props.count));

  return (
    <div class="pagination">
      <button
        class="btn"
        disabled={props.page <= 1}
        onClick={() => props.onChange(props.page - 1)}
        style={{ opacity: props.page <= 1 ? 0.4 : 1 }}
      >
        {t('actions.prev')}
      </button>
      <span>
        {t('common.page')} {props.page} {t('common.of')} {totalPages()}
      </span>
      <button
        class="btn"
        disabled={props.page >= totalPages()}
        onClick={() => props.onChange(props.page + 1)}
        style={{ opacity: props.page >= totalPages() ? 0.4 : 1 }}
      >
        {t('actions.next')}
      </button>
    </div>
  );
}

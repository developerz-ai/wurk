import { t } from '../i18n';

interface PaginationProps {
  page: number;
  total: number;
  count: number;
  // Deepest 1-indexed page the server will serve (API `max_page` + 1). Past it
  // the server clamps, so offering "Next" would re-show the same rows.
  maxPage?: number;
  onChange: (p: number) => void;
}

// 1-indexed page cap from a listing response's 0-indexed `max_page`.
export function maxPageOf(data: { max_page?: number } | undefined): number | undefined {
  const max = data?.max_page;
  return typeof max === 'number' ? max + 1 : undefined;
}

export function Pagination(props: PaginationProps) {
  const totalPages = () => Math.max(1, Math.min(Math.ceil(props.total / props.count), props.maxPage ?? Infinity));

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

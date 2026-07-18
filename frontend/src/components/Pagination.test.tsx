import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import { Pagination } from './Pagination';
import { t } from '../i18n';

function renderPagination(page: number, total: number, count: number) {
  const onChange = vi.fn();
  render(() => <Pagination page={page} total={total} count={count} onChange={onChange} />);
  return { onChange };
}

describe('Pagination', () => {
  it('renders "Page X of Y" from ceil(total / count), floored at 1 page', () => {
    renderPagination(1, 0, 10);
    expect(screen.getByText(`${t('common.page')} 1 ${t('common.of')} 1`)).toBeInTheDocument();
  });

  it('rounds a partial last page up', () => {
    renderPagination(1, 95, 10);
    // 95 / 10 = 9.5 -> 10 pages, not 9.
    expect(screen.getByText(`${t('common.page')} 1 ${t('common.of')} 10`)).toBeInTheDocument();
  });

  it('disables Previous on the first page and Next once the last page is reached', () => {
    renderPagination(1, 95, 10);
    expect(screen.getByRole('button', { name: t('actions.prev') })).toBeDisabled();
    expect(screen.getByRole('button', { name: t('actions.next') })).not.toBeDisabled();

    renderPagination(10, 95, 10);
    expect(screen.getAllByRole('button', { name: t('actions.next') })[1]).toBeDisabled();
  });

  it('keeps both buttons enabled on a middle page', () => {
    renderPagination(5, 95, 10);
    expect(screen.getByRole('button', { name: t('actions.prev') })).not.toBeDisabled();
    expect(screen.getByRole('button', { name: t('actions.next') })).not.toBeDisabled();
  });

  it('reports page ± 1 to onChange without clamping itself — the caller owns bounds', () => {
    const { onChange } = renderPagination(5, 95, 10);
    fireEvent.click(screen.getByRole('button', { name: t('actions.next') }));
    expect(onChange).toHaveBeenCalledWith(6);

    fireEvent.click(screen.getByRole('button', { name: t('actions.prev') }));
    expect(onChange).toHaveBeenCalledWith(4);
  });

  it('still counts a single partial page as page 1 of 1 for a tiny result set', () => {
    renderPagination(1, 3, 10);
    expect(screen.getByText(`${t('common.page')} 1 ${t('common.of')} 1`)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: t('actions.prev') })).toBeDisabled();
    expect(screen.getByRole('button', { name: t('actions.next') })).toBeDisabled();
  });
});

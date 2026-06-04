import { type ReactNode } from 'react';

interface PageHeaderProps {
  /** Font Awesome solid icon class, e.g. `fa-layer-group` (matches the nav). */
  icon: string;
  title: string;
  summary: string;
  /** Optional right-aligned slot — typically the count badge. */
  children?: ReactNode;
}

// Consistent header for each tab page: the tab's icon, its title, and a one-line
// summary of what the page shows. Keeps every page oriented and on-brand.
export function PageHeader({ icon, title, summary, children }: PageHeaderProps) {
  return (
    <div className="page-header">
      <span className="page-header__icon">
        <i className={`fa-solid ${icon}`} />
      </span>
      <div className="page-header__text">
        <h1 className="page-header__title">{title}</h1>
        <p className="page-header__summary">{summary}</p>
      </div>
      {children != null && <div className="page-header__aside">{children}</div>}
    </div>
  );
}

import type { CSSProperties } from 'react';

// Content-shaped loading placeholders. Prefer these over a lone spinner: they
// hint at the layout that's coming, so the swap to real data doesn't shift the
// page. Styling + shimmer live in styles/components/_skeleton.scss; the shimmer
// freezes to a static tint under prefers-reduced-motion (base/_motion.scss).
//
// The shimmering blocks carry no information, so they're aria-hidden; wrappers
// expose `role="status"` + `aria-busy` so assistive tech announces the wait.

type Size = number | string;

interface SkeletonProps {
  width?: Size;
  height?: Size;
  radius?: Size;
  circle?: boolean;
  className?: string;
  style?: CSSProperties;
}

/** A single shimmering block. Size it via props or let it fill its container. */
export function Skeleton({ width, height, radius, circle, className = '', style }: SkeletonProps) {
  return (
    <span
      aria-hidden="true"
      className={`skeleton${circle ? ' skeleton--circle' : ''}${className ? ` ${className}` : ''}`}
      style={{ width, height, borderRadius: radius, ...style }}
    />
  );
}

/** A single line of placeholder text. `width` gives a natural ragged edge. */
export function SkeletonText({ width = '100%', style }: { width?: Size; style?: CSSProperties }) {
  return <span aria-hidden="true" className="skeleton skeleton--text" style={{ width, ...style }} />;
}

/** Table placeholder that mirrors `.table-wrapper` chrome for a seamless swap. */
export function SkeletonTable({ rows = 6, cols = 4 }: { rows?: number; cols?: number }) {
  return (
    <div className="skeleton-table" role="status" aria-busy="true" aria-label="Loading">
      {Array.from({ length: rows }, (_, r) => (
        <div className="skeleton-table__row" key={r}>
          {Array.from({ length: cols }, (_, c) => (
            <span className="skeleton skeleton-table__cell" aria-hidden="true" key={c} />
          ))}
        </div>
      ))}
    </div>
  );
}

/** Grid of metric-card placeholders for dashboard-style stat rows. */
export function SkeletonCards({ count = 4 }: { count?: number }) {
  return (
    <div className="skeleton-cards" role="status" aria-busy="true" aria-label="Loading">
      {Array.from({ length: count }, (_, i) => (
        <div className="skeleton-card" key={i}>
          <SkeletonText width="45%" />
          <Skeleton height="1.6rem" width="60%" />
        </div>
      ))}
    </div>
  );
}

/** Generic full-page fallback: header + table. Used as a route Suspense boundary. */
export function PageSkeleton() {
  return (
    <div role="status" aria-busy="true" aria-label="Loading">
      <div className="page-header" style={{ animation: 'none' }}>
        <Skeleton width="2.75rem" height="2.75rem" radius="var(--radius)" />
        <div className="skeleton-stack" style={{ flex: 1, maxWidth: '18rem' }}>
          <Skeleton height="1.4rem" width="45%" />
          <SkeletonText width="70%" />
        </div>
      </div>
      <SkeletonTable rows={8} cols={4} />
    </div>
  );
}

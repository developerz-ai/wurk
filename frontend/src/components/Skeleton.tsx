import { Index, type JSX } from 'solid-js';

// Content-shaped loading placeholders. Prefer these over a lone spinner: they
// hint at the layout that's coming, so the swap to real data doesn't shift the
// page. Styling + shimmer live in styles/components/_skeleton.scss; the shimmer
// freezes to a static tint under prefers-reduced-motion (base/_motion.scss).
//
// The shimmering blocks carry no information, so they're aria-hidden; wrappers
// expose `role="status"` + `aria-busy` so assistive tech announces the wait.

type Size = number | string;

// Solid does not auto-suffix numeric style lengths with px (React did), so a
// numeric width/height/radius prop must be coerced to a px string.
const px = (v?: Size): string | undefined => (typeof v === 'number' ? `${v}px` : v);

interface SkeletonProps {
  width?: Size;
  height?: Size;
  radius?: Size;
  circle?: boolean;
  class?: string;
  style?: JSX.CSSProperties;
}

/** A single shimmering block. Size it via props or let it fill its container. */
export function Skeleton(props: SkeletonProps) {
  return (
    <span
      aria-hidden="true"
      class={`skeleton${props.circle ? ' skeleton--circle' : ''}${props.class ? ` ${props.class}` : ''}`}
      style={{ width: px(props.width), height: px(props.height), 'border-radius': px(props.radius), ...props.style }}
    />
  );
}

/** A single line of placeholder text. `width` gives a natural ragged edge. */
export function SkeletonText(props: { width?: Size; style?: JSX.CSSProperties }) {
  return <span aria-hidden="true" class="skeleton skeleton--text" style={{ width: px(props.width ?? '100%'), ...props.style }} />;
}

/** Table placeholder that mirrors `.table-wrapper` chrome for a seamless swap. */
export function SkeletonTable(props: { rows?: number; cols?: number }) {
  return (
    <div class="skeleton-table" role="status" aria-busy="true" aria-label="Loading">
      <Index each={Array.from({ length: props.rows ?? 6 })}>
        {() => (
          <div class="skeleton-table__row">
            <Index each={Array.from({ length: props.cols ?? 4 })}>
              {() => <span class="skeleton skeleton-table__cell" aria-hidden="true" />}
            </Index>
          </div>
        )}
      </Index>
    </div>
  );
}

/** Grid of metric-card placeholders for dashboard-style stat rows. */
export function SkeletonCards(props: { count?: number }) {
  return (
    <div class="skeleton-cards" role="status" aria-busy="true" aria-label="Loading">
      <Index each={Array.from({ length: props.count ?? 4 })}>
        {() => (
          <div class="skeleton-card">
            <SkeletonText width="45%" />
            <Skeleton height="1.6rem" width="60%" />
          </div>
        )}
      </Index>
    </div>
  );
}

/** Generic full-page fallback: header + table. Used as a route Suspense boundary. */
export function PageSkeleton() {
  return (
    <div role="status" aria-busy="true" aria-label="Loading">
      <div class="page-header" style={{ animation: 'none' }}>
        <Skeleton width="2.75rem" height="2.75rem" radius="var(--radius)" />
        <div class="skeleton-stack" style={{ flex: 1, 'max-width': '18rem' }}>
          <Skeleton height="1.4rem" width="45%" />
          <SkeletonText width="70%" />
        </div>
      </div>
      <SkeletonTable rows={8} cols={4} />
    </div>
  );
}

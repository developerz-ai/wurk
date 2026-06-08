import { useState, useRef, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

// A tooltip rendered into a body-level portal with position: fixed, so it
// escapes the `overflow: auto` clipping of scroll containers (e.g. the table
// wrapper) that swallows an absolutely-positioned CSS tooltip. Positioned above
// the trigger and horizontally centered on it.
export function Tooltip({ tip, children }: { tip: string; children: ReactNode }) {
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null);
  const ref = useRef<HTMLSpanElement>(null);

  const show = () => {
    const r = ref.current?.getBoundingClientRect();
    if (r) setPos({ x: r.left + r.width / 2, y: r.top });
  };

  return (
    <span
      ref={ref}
      onMouseEnter={show}
      onMouseLeave={() => setPos(null)}
      style={{ display: 'inline-flex' }}
    >
      {children}
      {pos &&
        createPortal(
          <div
            role="tooltip"
            style={{
              position: 'fixed',
              left: pos.x,
              top: pos.y - 8,
              transform: 'translate(-50%, -100%)',
              maxWidth: 260,
              background: 'var(--surface-strong)',
              color: 'var(--text)',
              border: '1px solid var(--border-strong)',
              padding: '0.4rem 0.6rem',
              borderRadius: 6,
              fontSize: 12,
              lineHeight: 1.35,
              zIndex: 9999,
              pointerEvents: 'none',
              boxShadow: '0 4px 14px rgba(0, 0, 0, 0.45)',
            }}
          >
            {tip}
          </div>,
          document.body
        )}
    </span>
  );
}

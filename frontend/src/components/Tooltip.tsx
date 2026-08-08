import { createSignal, createUniqueId, createEffect, children, Show, type JSX } from 'solid-js';
import { Portal } from 'solid-js/web';

// A tooltip rendered into a body-level portal with position: fixed, so it
// escapes the `overflow: auto` clipping of scroll containers (e.g. the table
// wrapper) that swallows an absolutely-positioned CSS tooltip. Positioned above
// the trigger and horizontally centered on it.
export function Tooltip(props: { tip: string; children: JSX.Element }) {
  const [pos, setPos] = createSignal<{ x: number; y: number } | null>(null);
  let ref!: HTMLSpanElement;
  const tipId = createUniqueId();

  const show = () => {
    const r = ref?.getBoundingClientRect();
    if (r) setPos({ x: r.left + r.width / 2, y: r.top });
  };

  // Associate the trigger with the tooltip for screen readers.
  const trigger = children(() => props.children);
  createEffect(() => {
    const el = trigger();
    if (el instanceof HTMLElement) el.setAttribute('aria-describedby', tipId);
  });

  return (
    <span
      ref={ref}
      onMouseEnter={show}
      onMouseLeave={() => setPos(null)}
      style={{ display: 'inline-flex' }}
    >
      {trigger()}
      <Show when={pos()}>
        {(p) => (
          <Portal>
            <div
              id={tipId}
              role="tooltip"
              style={{
                position: 'fixed',
                left: `${p().x}px`,
                top: `${p().y - 8}px`,
                transform: 'translate(-50%, -100%)',
                'max-width': '260px',
                background: 'var(--surface-strong)',
                color: 'var(--text)',
                border: '1px solid var(--border-strong)',
                padding: '0.4rem 0.6rem',
                'border-radius': '6px',
                'font-size': '12px',
                'line-height': 1.35,
                'z-index': 9999,
                'pointer-events': 'none',
                'box-shadow': '0 4px 14px var(--shadow-color)',
              }}
            >
              {props.tip}
            </div>
          </Portal>
        )}
      </Show>
    </span>
  );
}

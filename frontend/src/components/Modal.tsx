import { useEffect, useRef, type ReactNode } from 'react';

interface ModalProps {
  open: boolean;
  onClose: () => void;
  title: ReactNode;
  children: ReactNode;
  /** Optional footer (e.g. action buttons). */
  footer?: ReactNode;
  /** Max width of the dialog; defaults to a roomy detail width. */
  width?: number;
}

// Reusable accessible dialog built on the native <dialog> element, so focus
// trapping, Esc-to-close, and the top-layer/backdrop come from the platform.
// We wire showModal()/close() to the `open` prop and surface close intents
// (Esc, backdrop click, the ✕) through a single onClose.
export default function Modal({ open, onClose, title, children, footer, width = 640 }: ModalProps) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useRef(`modal-title-${Math.random().toString(36).slice(2)}`).current;

  useEffect(() => {
    const dlg = ref.current;
    if (!dlg) return;
    if (open && !dlg.open) dlg.showModal();
    else if (!open && dlg.open) dlg.close();
  }, [open]);

  // The native `cancel` event fires on Esc; route it through onClose so React
  // state stays the source of truth (preventDefault stops the default close so
  // we don't end up with dlg.open=false while the prop says open).
  useEffect(() => {
    const dlg = ref.current;
    if (!dlg) return;
    const onCancel = (e: Event) => {
      e.preventDefault();
      onClose();
    };
    dlg.addEventListener('cancel', onCancel);
    return () => dlg.removeEventListener('cancel', onCancel);
  }, [onClose]);

  if (!open) return null;

  return (
    <dialog
      ref={ref}
      className="modal"
      aria-labelledby={titleId}
      // Backdrop click: the dialog element itself is the click target outside
      // the inner content, so close only when the click lands on <dialog>.
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
    >
      <div className="modal-panel" style={{ maxWidth: width }}>
        <div className="modal-header">
          <h2 id={titleId} className="modal-title">{title}</h2>
          <button className="modal-close" onClick={onClose} aria-label="Close">
            <i className="fa-solid fa-xmark" />
          </button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-footer">{footer}</div>}
      </div>
    </dialog>
  );
}

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

// Reusable accessible dialog on the native <dialog> element — focus trapping,
// Esc-to-close, and the top-layer/backdrop come from the platform. The dialog
// stays mounted (not conditionally rendered) and is driven by showModal()/close(),
// so enter AND exit animate via CSS (@starting-style + allow-discrete in styles.css).
export default function Modal({ open, onClose, title, children, footer, width = 640 }: ModalProps) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useRef(`modal-title-${Math.random().toString(36).slice(2)}`).current;

  // Hold the last content + title so the panel isn't blank while it animates out
  // (consumers typically clear their data the moment `open` flips false).
  const held = useRef<{ title: ReactNode; children: ReactNode }>({ title, children });
  if (open) held.current = { title, children };
  const shown = open ? { title, children } : held.current;

  useEffect(() => {
    const dlg = ref.current;
    if (!dlg) return;
    if (open && !dlg.open) dlg.showModal();
    else if (!open && dlg.open) dlg.close();
  }, [open]);

  // Esc fires the native `cancel`; route it through onClose so React state stays
  // the source of truth.
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

  return (
    <dialog
      ref={ref}
      className="modal"
      aria-labelledby={titleId}
      // Close only when the click lands on the <dialog> itself (the backdrop area),
      // not the panel inside it.
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
    >
      <div className="modal-panel" style={{ maxWidth: width }}>
        <div className="modal-header">
          <h2 id={titleId} className="modal-title">{shown.title}</h2>
          <button className="modal-close" onClick={onClose} aria-label="Close">
            <i className="fa-solid fa-xmark" />
          </button>
        </div>
        <div className="modal-body">{shown.children}</div>
        {footer && <div className="modal-footer">{footer}</div>}
      </div>
    </dialog>
  );
}

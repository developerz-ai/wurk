import { createEffect, createSignal, onCleanup, onMount, Show, type JSX } from 'solid-js';

interface ModalProps {
  open: boolean;
  onClose: () => void;
  title: JSX.Element;
  children: JSX.Element;
  /** Optional footer (e.g. action buttons). */
  footer?: JSX.Element;
  /** Max width of the dialog; defaults to a roomy detail width. */
  width?: number;
}

// Reusable accessible dialog on the native <dialog> element — focus trapping,
// Esc-to-close, and the top-layer/backdrop come from the platform. The dialog
// stays mounted (not conditionally rendered) and is driven by showModal()/close(),
// so enter AND exit animate via CSS (@starting-style + allow-discrete in
// styles/components/_modal.scss).
export default function Modal(props: ModalProps) {
  let dlg!: HTMLDialogElement;
  const titleId = `modal-title-${Math.random().toString(36).slice(2)}`;

  // Hold the last content + title so the panel isn't blank while it animates out
  // (consumers typically clear their data the moment `open` flips false).
  const [held, setHeld] = createSignal<{ title: JSX.Element; children: JSX.Element }>({
    title: props.title,
    children: props.children,
  });
  createEffect(() => {
    if (props.open) setHeld({ title: props.title, children: props.children });
  });
  const shown = () => (props.open ? { title: props.title, children: props.children } : held());

  createEffect(() => {
    if (props.open && !dlg.open) dlg.showModal();
    else if (!props.open && dlg.open) dlg.close();
  });

  // Esc fires the native `cancel`; route it through onClose so app state stays
  // the source of truth.
  onMount(() => {
    const onCancel = (e: Event) => {
      e.preventDefault();
      props.onClose();
    };
    dlg.addEventListener('cancel', onCancel);
    onCleanup(() => dlg.removeEventListener('cancel', onCancel));
  });

  return (
    <dialog
      ref={dlg}
      class="modal"
      aria-labelledby={titleId}
      // Close only when the click lands on the <dialog> itself (the backdrop area),
      // not the panel inside it.
      onClick={(e) => {
        if (e.target === dlg) props.onClose();
      }}
    >
      <div class="modal-panel" style={{ 'max-width': `${props.width ?? 640}px` }}>
        <div class="modal-header">
          <h2 id={titleId} class="modal-title">{shown().title}</h2>
          <button class="modal-close" onClick={() => props.onClose()} aria-label="Close">
            <i class="fa-solid fa-xmark" />
          </button>
        </div>
        <div class="modal-body">{shown().children}</div>
        <Show when={props.footer}>
          <div class="modal-footer">{props.footer}</div>
        </Show>
      </div>
    </dialog>
  );
}

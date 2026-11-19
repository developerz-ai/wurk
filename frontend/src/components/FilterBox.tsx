import { createEffect, createSignal, on, onCleanup } from 'solid-js';
import { t } from '../i18n';

interface FilterBoxProps {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
}

const DEBOUNCE_MS = 250;

// Debounced text filter wired to the backend `?substr=` param shared by every
// job-set listing endpoint (Wurk::Api::Pagination#match?). Local `input` state
// tracks keystrokes immediately; `props.onChange` — and therefore the fetch —
// only fires after the user pauses, so a fast typer doesn't fire one request
// per keystroke.
export function FilterBox(props: FilterBoxProps) {
  const [input, setInput] = createSignal(props.value);
  // The last value this box and its owner agreed on: what it emitted, or what
  // the owner last pushed in.
  let settled = props.value;

  // Adopt a value changed from outside (browser Back on `?tag=`, a cleared
  // filter). The debounced emit below echoes back as props.value === settled
  // and is ignored, so in-progress typing is never overwritten by its own
  // earlier emit.
  createEffect(
    on(
      () => props.value,
      (value) => {
        if (value === settled) return;
        settled = value;
        setInput(value);
      },
      { defer: true },
    ),
  );

  createEffect(() => {
    const next = input();
    const id = setTimeout(() => {
      if (next === settled) return;
      settled = next;
      props.onChange(next);
    }, DEBOUNCE_MS);
    onCleanup(() => clearTimeout(id));
  });

  return (
    <div class="filter-box" style={{ 'margin-bottom': '1rem', display: 'flex' }}>
      <input
        class="input"
        type="search"
        value={input()}
        onInput={(e) => setInput(e.currentTarget.value)}
        placeholder={props.placeholder ?? t('common.filter_placeholder')}
        aria-label={props.placeholder ?? t('common.filter_placeholder')}
        style={{ flex: 1, 'max-width': '360px' }}
      />
    </div>
  );
}

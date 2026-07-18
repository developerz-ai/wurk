import { createEffect, createSignal, onCleanup } from 'solid-js';
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

  createEffect(() => {
    const next = input();
    const id = setTimeout(() => {
      if (next !== props.value) props.onChange(next);
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

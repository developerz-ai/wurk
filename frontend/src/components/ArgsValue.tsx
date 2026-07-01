import { Show } from 'solid-js';
import { truncate } from '../utils';

// Job args table cell. Empty args (`[]`) render as a muted em-dash rather than
// a literal "[]", which reads as noise; non-empty args show the truncated JSON.
export function ArgsValue(props: { str: string; max: number }) {
  return (
    <Show
      when={props.str !== '[]' && props.str !== ''}
      fallback={<span style={{ color: 'var(--text-muted)' }}>—</span>}
    >
      <span title={props.str}>{truncate(props.str, props.max)}</span>
    </Show>
  );
}

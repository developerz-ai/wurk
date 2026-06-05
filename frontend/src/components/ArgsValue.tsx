import { truncate } from '../utils';

// Job args table cell. Empty args (`[]`) render as a muted em-dash rather than
// a literal "[]", which reads as noise; non-empty args show the truncated JSON.
export function ArgsValue({ str, max }: { str: string; max: number }) {
  if (str === '[]' || str === '') {
    return <span style={{ color: 'var(--text-muted)' }}>—</span>;
  }
  return <span title={str}>{truncate(str, max)}</span>;
}

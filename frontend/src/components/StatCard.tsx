import { Show } from 'solid-js';
import { AnimatedNumber } from './AnimatedNumber';

interface StatCardProps {
  label: string;
  value: number | string;
  color?: string;
}

export function StatCard(props: StatCardProps) {
  return (
    <div
      class="card card--stat"
      style={{
        display: 'flex',
        'flex-direction': 'column',
        gap: '0.25rem',
      }}
    >
      <span
        style={{
          'font-size': '12px',
          'font-weight': 500,
          'text-transform': 'uppercase',
          'letter-spacing': '0.05em',
          color: 'var(--text-muted)',
        }}
      >
        {props.label}
      </span>
      <span
        style={{
          'font-size': '28px',
          'font-weight': 700,
          'line-height': 1.1,
          color: props.color ?? 'var(--text)',
          'font-variant-numeric': 'tabular-nums',
        }}
      >
        <Show when={typeof props.value === 'number'} fallback={props.value}>
          <AnimatedNumber value={props.value as number} />
        </Show>
      </span>
    </div>
  );
}

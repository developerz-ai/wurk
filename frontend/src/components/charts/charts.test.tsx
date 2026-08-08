import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { render, screen } from '@solidjs/testing-library';
import { AreaChart, LineChart, BarChart } from './index';

// jsdom has no layout engine and (in v29) no ResizeObserver, so the charts —
// which only draw once their container reports a non-zero size — would render an
// empty <svg>. Give every element a fixed box and a no-op ResizeObserver so the
// structural output (paths, bars, axis ticks) is exercised.
const origRO = globalThis.ResizeObserver;
let cw: PropertyDescriptor | undefined;
let ch: PropertyDescriptor | undefined;

beforeAll(() => {
  cw = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'clientWidth');
  ch = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'clientHeight');
  Object.defineProperty(HTMLElement.prototype, 'clientWidth', { configurable: true, get: () => 600 });
  Object.defineProperty(HTMLElement.prototype, 'clientHeight', { configurable: true, get: () => 300 });
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as unknown as typeof ResizeObserver;
});

afterAll(() => {
  if (cw) Object.defineProperty(HTMLElement.prototype, 'clientWidth', cw);
  if (ch) Object.defineProperty(HTMLElement.prototype, 'clientHeight', ch);
  globalThis.ResizeObserver = origRO;
});

const DATA = [
  { label: 'A', processed: 5, failed: 1 },
  { label: 'B', processed: 8, failed: 2 },
  { label: 'C', processed: 3, failed: 0 },
];

describe('LineChart', () => {
  it('emits one stroked path per series plus a legend and axis ticks', () => {
    const { container } = render(() => (
      <LineChart
        data={DATA}
        height={300}
        legend
        yAxisWidth={36}
        series={[
          { key: 'processed', name: 'Proc', stroke: 'var(--mono-1)' },
          { key: 'failed', stroke: 'var(--mono-3)' },
        ]}
      />
    ));

    const svg = container.querySelector('svg');
    expect(svg).not.toBeNull();
    // One smooth line per series.
    expect(svg!.querySelectorAll('path[stroke]')).toHaveLength(2);
    // Legend uses name ?? key.
    expect(screen.getByText('Proc')).toBeInTheDocument();
    expect(screen.getByText('failed')).toBeInTheDocument();
    // X category ticks + a Y axis tick (max rounds to 8).
    expect(screen.getAllByText('B').length).toBeGreaterThan(0);
    expect(screen.getByText('8')).toBeInTheDocument();
  });
});

describe('AreaChart', () => {
  it('renders an svg with a stroked path per series', () => {
    const { container } = render(() => (
      <AreaChart
        data={DATA}
        height={300}
        yAxisWidth={36}
        series={[
          { key: 'processed', stroke: 'var(--mono-1)', fill: 'gradient' },
          { key: 'failed', stroke: 'var(--mono-3)', fill: 'none' },
        ]}
      />
    ));

    const svg = container.querySelector('svg');
    expect(svg).not.toBeNull();
    // gradient series → area + line path; line-only series → line path.
    expect(svg!.querySelectorAll('path').length).toBeGreaterThanOrEqual(3);
    expect(svg!.querySelector('linearGradient')).not.toBeNull();
    expect(screen.getAllByText('A').length).toBeGreaterThan(0);
  });
});

describe('BarChart', () => {
  it('renders one rect per datum with axis ticks', () => {
    const { container } = render(() => (
      <BarChart
        data={[
          { label: 'A', value: 5, color: 'var(--mono-1)' },
          { label: 'B', value: 8, color: 'var(--mono-6)' },
          { label: 'C', value: 3, color: 'var(--mono-6)' },
        ]}
        height={240}
        name="Depth"
        yAxisWidth={36}
      />
    ));

    const svg = container.querySelector('svg');
    expect(svg).not.toBeNull();
    // No hover → the only rects are the three bars.
    expect(svg!.querySelectorAll('rect')).toHaveLength(3);
    expect(screen.getAllByText('C').length).toBeGreaterThan(0);
    expect(screen.getByText('8')).toBeInTheDocument();
  });
});

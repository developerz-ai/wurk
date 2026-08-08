import { createSignal, onCleanup, onMount, For, Show, type JSX } from 'solid-js';
import { formatNumber } from '../../utils';

// Shared primitives for the hand-rolled SVG charts that replace recharts. No
// deps beyond Solid + SVG. Every value below is a token reference, never a
// literal: SVG presentation attributes resolve `var()` the same way CSS
// declarations do, so charts re-paint on a theme flip with no JS involved.

export const AXIS_TICK = 'var(--mono-4)';
export const GRID = 'var(--chart-grid)';
export const MONO = 'var(--font-mono)';
export const CURSOR = 'var(--chart-cursor)';
export const BAR_CURSOR = 'var(--chart-band)';
export const TOOLTIP_BG = 'var(--surface)';
export const TOOLTIP_BORDER = 'var(--border)';
export const TOOLTIP_FG = 'var(--text)';
export const TOOLTIP_LABEL = 'var(--text-muted)';
export const DOT_STROKE = 'var(--bg)';

export interface Datum {
  label: string;
  [key: string]: string | number;
}

// Plot geometry in pixels. `left` reserves room for the optional Y axis; the
// other margins mirror recharts' defaults (top/right 8, bottom for x labels).
export interface Geo {
  width: number;
  height: number;
  left: number;
  right: number;
  top: number;
  bottom: number;
  plotW: number;
  plotH: number;
}

export function geometry(width: number, height: number, yAxisWidth = 0): Geo {
  const left = yAxisWidth;
  const right = 8;
  const top = 8;
  const bottom = 22;
  return {
    width,
    height,
    left,
    right,
    top,
    bottom,
    plotW: Math.max(0, width - left - right),
    plotH: Math.max(0, height - top - bottom),
  };
}

// Category x: evenly spaced points (line/area sit on them; bars centre bands on
// them). Single point centres in the plot so a lone bucket isn't glued to the
// left edge.
export function xAt(i: number, n: number, g: Geo): number {
  if (n <= 1) return g.left + g.plotW / 2;
  return g.left + (i * g.plotW) / (n - 1);
}

export function yAt(v: number, maxY: number, g: Geo): number {
  const bottom = g.height - g.bottom;
  if (maxY <= 0) return bottom;
  return bottom - (v / maxY) * g.plotH;
}

// Catmull-Rom → cubic bézier: the "monotone"-ish smooth recharts draws with
// type="monotone". Endpoints duplicate their neighbour so the curve starts/ends
// flat instead of flaring.
export function smoothPath(pts: Array<[number, number]>): string {
  if (pts.length === 0) return '';
  if (pts.length === 1) return `M${pts[0][0]},${pts[0][1]}`;
  let d = `M${pts[0][0]},${pts[0][1]}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] ?? pts[i];
    const p1 = pts[i];
    const p2 = pts[i + 1];
    const p3 = pts[i + 2] ?? p2;
    const c1x = p1[0] + (p2[0] - p0[0]) / 6;
    const c1y = p1[1] + (p2[1] - p0[1]) / 6;
    const c2x = p2[0] - (p3[0] - p1[0]) / 6;
    const c2y = p2[1] - (p3[1] - p1[1]) / 6;
    d += ` C${c1x},${c1y} ${c2x},${c2y} ${p2[0]},${p2[1]}`;
  }
  return d;
}

function niceNum(range: number, round: boolean): number {
  const exp = Math.floor(Math.log10(range));
  const frac = range / Math.pow(10, exp);
  let nice: number;
  if (round) {
    if (frac < 1.5) nice = 1;
    else if (frac < 3) nice = 2;
    else if (frac < 7) nice = 5;
    else nice = 10;
  } else {
    if (frac <= 1) nice = 1;
    else if (frac <= 2) nice = 2;
    else if (frac <= 5) nice = 5;
    else nice = 10;
  }
  return nice * Math.pow(10, exp);
}

// "Nice" y ticks from 0 to a rounded max. `allowDecimals=false` snaps the step
// to whole numbers (job counts, queue depth) so the axis never shows "2.5 jobs".
export function yScale(maxVal: number, allowDecimals = true): { max: number; ticks: number[] } {
  if (!(maxVal > 0)) return { max: 1, ticks: [0, 1] };
  const count = 4;
  let step = niceNum(maxVal / count, true);
  if (!allowDecimals) step = Math.max(1, Math.round(step));
  const max = Math.ceil(maxVal / step) * step;
  const ticks: number[] = [];
  for (let v = 0; v <= max + step / 1000; v += step) ticks.push(Number(v.toFixed(6)));
  return { max, ticks };
}

export function fmtTick(v: number): string {
  return Number.isInteger(v) ? formatNumber(v) : v.toFixed(v < 10 ? 2 : 1);
}

// preserveStartEnd + minTickGap: keep both endpoints and thin the interior to
// whatever fits without overlapping, estimating label width from char count at
// 11px monospace.
export function pickXTicks(labels: string[], plotW: number, minGap: number): number[] {
  const n = labels.length;
  if (n <= 1) return n === 1 ? [0] : [];
  const maxLabelPx = Math.max(...labels.map((l) => l.length)) * 6.6;
  const slot = maxLabelPx + minGap;
  const maxTicks = Math.max(2, Math.floor(plotW / slot));
  if (maxTicks >= n) return labels.map((_, i) => i);
  const step = Math.ceil((n - 1) / (maxTicks - 1));
  const idx: number[] = [];
  for (let i = 0; i < n; i += step) idx.push(i);
  if (idx[idx.length - 1] !== n - 1) idx.push(n - 1);
  return idx;
}

// Measures the plot box (width AND height) so charts fill their container and
// react to resizes — the responsive-container replacement. `flex:1` inside a
// fixed-height wrapper means legends shrink the plot without extra math.
export function useSize(): { setRef: (el: HTMLDivElement) => void; size: () => { w: number; h: number } } {
  const [size, setSize] = createSignal({ w: 0, h: 0 });
  let el: HTMLDivElement | undefined;
  const setRef = (e: HTMLDivElement) => {
    el = e;
  };
  onMount(() => {
    const measure = () => {
      if (el) setSize({ w: el.clientWidth, h: el.clientHeight });
    };
    measure();
    const ro = new ResizeObserver(measure);
    if (el) ro.observe(el);
    onCleanup(() => ro.disconnect());
  });
  return { setRef, size };
}

// Grid (faint dashed horizontals at each y tick) + axis ticks. axisLine/tickLine
// are always off (design), matching every recharts axis on these pages.
export function Frame(props: {
  geo: Geo;
  yTicks: number[];
  yAt: (v: number) => number;
  showY: boolean;
  xTicks: number[];
  xAt: (i: number) => number;
  labels: string[];
}): JSX.Element {
  const last = () => props.labels.length - 1;
  return (
    <>
      <For each={props.yTicks}>
        {(v) => (
          <line
            x1={props.geo.left}
            x2={props.geo.width - props.geo.right}
            y1={props.yAt(v)}
            y2={props.yAt(v)}
            stroke={GRID}
            stroke-dasharray="3 3"
          />
        )}
      </For>
      <Show when={props.showY}>
        <For each={props.yTicks}>
          {(v) => (
            <text
              x={props.geo.left - 6}
              y={props.yAt(v)}
              text-anchor="end"
              dominant-baseline="middle"
              fill={AXIS_TICK}
              font-size="11"
              font-family={MONO}
            >
              {fmtTick(v)}
            </text>
          )}
        </For>
      </Show>
      <For each={props.xTicks}>
        {(i) => (
          <text
            x={props.xAt(i)}
            y={props.geo.height - props.geo.bottom + 14}
            text-anchor={i === 0 ? 'start' : i === last() ? 'end' : 'middle'}
            fill={AXIS_TICK}
            font-size="11"
            font-family={MONO}
          >
            {props.labels[i]}
          </text>
        )}
      </For>
    </>
  );
}

export interface TooltipRow {
  name: string;
  value: number;
  color: string;
}

function fmtVal(v: number): string {
  return Number.isInteger(v) ? formatNumber(v) : v.toFixed(2);
}

// HTML overlay tooltip (crisp text, unlike SVG <text>). Flips to the other side
// of the cursor near the right edge so it never spills out of the plot.
export function ChartTooltip(props: { x: number; containerW: number; label: string; rows: TooltipRow[] }): JSX.Element {
  const flip = () => props.x > props.containerW / 2;
  return (
    <div
      style={{
        position: 'absolute',
        left: `${props.x}px`,
        top: '8px',
        transform: flip() ? 'translateX(calc(-100% - 12px))' : 'translateX(12px)',
        background: TOOLTIP_BG,
        border: `1px solid ${TOOLTIP_BORDER}`,
        color: TOOLTIP_FG,
        'border-radius': '6px',
        'font-size': '12px',
        'font-family': MONO,
        padding: '8px 10px',
        'pointer-events': 'none',
        'white-space': 'nowrap',
        'z-index': 10,
      }}
    >
      <div style={{ color: TOOLTIP_LABEL, 'margin-bottom': '4px' }}>{props.label}</div>
      <For each={props.rows}>
        {(row) => (
          <div style={{ display: 'flex', 'align-items': 'center', gap: '6px' }}>
            <span
              style={{
                width: '8px',
                height: '8px',
                'border-radius': '2px',
                background: row.color,
                display: 'inline-block',
                flex: 'none',
              }}
            />
            <span>{row.name}</span>
            <span style={{ 'margin-inline-start': 'auto', 'padding-inline-start': '10px' }}>{fmtVal(row.value)}</span>
          </div>
        )}
      </For>
    </div>
  );
}

// Nearest category index from a local x, for line/area (points) charts.
export function nearestPoint(localX: number, n: number, g: Geo): number {
  if (n <= 1) return 0;
  const stepX = g.plotW / (n - 1);
  const i = Math.round((localX - g.left) / stepX);
  return Math.max(0, Math.min(n - 1, i));
}

// Nearest band index from a local x, for bar charts.
export function nearestBand(localX: number, n: number, g: Geo): number {
  if (n <= 0) return -1;
  const band = g.plotW / n;
  const i = Math.floor((localX - g.left) / band);
  return Math.max(0, Math.min(n - 1, i));
}

// Local x/y from a pointer event relative to the SVG's top-left, robust to
// nested target elements (getBoundingClientRect, not offsetX).
export function localXY(e: MouseEvent, svg: SVGSVGElement): { x: number; y: number } {
  const r = svg.getBoundingClientRect();
  return { x: e.clientX - r.left, y: e.clientY - r.top };
}

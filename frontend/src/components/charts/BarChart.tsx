import { createSignal, createMemo, For, Show, type JSX } from 'solid-js';
import {
  type TooltipRow,
  ChartTooltip,
  Frame,
  geometry,
  yAt,
  yScale,
  pickXTicks,
  useSize,
  nearestBand,
  localXY,
  BAR_CURSOR,
} from './util';

export interface BarDatum {
  label: string;
  value: number;
  /** Per-bar fill (recharts <Cell> replacement). */
  color: string;
}

export interface BarChartProps {
  data: BarDatum[];
  height: number;
  /** Tooltip series label (recharts `name`). */
  name?: string;
  yAxisWidth?: number;
  yDecimals?: boolean;
  xMinTickGap?: number;
  /** Top corner radius in px (default 3). */
  radius?: number;
}

// Vertical bar chart with per-bar colours, rounded tops, and a faint band
// highlight + tooltip on hover. Replaces recharts' <BarChart> + <Cell>.
export function BarChart(props: BarChartProps): JSX.Element {
  const { setRef, size } = useSize();
  const [hover, setHover] = createSignal<number | null>(null);
  let svg: SVGSVGElement | undefined;

  const g = createMemo(() => geometry(size().w, size().h, props.yAxisWidth ?? 0));
  const maxY = createMemo(() => Math.max(0, ...props.data.map((d) => d.value)));
  const scale = createMemo(() => yScale(maxY(), props.yDecimals ?? true));
  const labels = createMemo(() => props.data.map((d) => d.label));
  const xTicks = createMemo(() => pickXTicks(labels(), g().plotW, props.xMinTickGap ?? 40));

  const py = (v: number) => yAt(v, scale().max, g());
  const band = () => (props.data.length > 0 ? g().plotW / props.data.length : 0);
  const barW = () => Math.max(1, band() * 0.62);
  const bandCenter = (i: number) => g().left + band() * (i + 0.5);

  const onMove = (e: MouseEvent) => {
    if (!svg) return;
    const { x } = localXY(e, svg);
    setHover(nearestBand(x, props.data.length, g()));
  };

  const rows = (): TooltipRow[] => {
    const i = hover();
    if (i === null || !props.data[i]) return [];
    return [{ name: props.name ?? 'Value', value: props.data[i].value, color: props.data[i].color }];
  };

  return (
    <div style={{ position: 'relative', width: '100%', height: `${props.height}px` }}>
      <div ref={setRef} style={{ position: 'relative', width: '100%', height: '100%' }}>
        <Show when={size().w > 0 && size().h > 0}>
          <svg
            ref={svg}
            width={size().w}
            height={size().h}
            onMouseMove={onMove}
            onMouseLeave={() => setHover(null)}
          >
            <Frame geo={g()} yTicks={scale().ticks} yAt={py} showY={props.yAxisWidth != null} xTicks={xTicks()} xAt={bandCenter} labels={labels()} />

            <Show when={hover() !== null}>
              <rect x={g().left + band() * hover()!} y={g().top} width={band()} height={g().plotH} fill={BAR_CURSOR} />
            </Show>

            <For each={props.data}>
              {(d, i) => {
                const top = () => py(d.value);
                const base = () => g().height - g().bottom;
                const h = () => Math.max(0, base() - top());
                const r = () => Math.min(props.radius ?? 3, barW() / 2, h());
                return (
                  <rect
                    x={bandCenter(i()) - barW() / 2}
                    y={top()}
                    width={barW()}
                    height={h()}
                    rx={r()}
                    ry={r()}
                    fill={d.color}
                  />
                );
              }}
            </For>
          </svg>
        </Show>
      </div>
      <Show when={hover() !== null}>
        <ChartTooltip x={bandCenter(hover()!)} containerW={size().w} label={labels()[hover()!]} rows={rows()} />
      </Show>
    </div>
  );
}

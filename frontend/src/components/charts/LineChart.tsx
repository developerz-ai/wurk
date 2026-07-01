import { createSignal, createMemo, For, Show, type JSX } from 'solid-js';
import {
  type Datum,
  type TooltipRow,
  ChartTooltip,
  Frame,
  geometry,
  xAt,
  yAt,
  yScale,
  pickXTicks,
  smoothPath,
  useSize,
  nearestPoint,
  localXY,
  MONO,
  CURSOR,
  DOT_STROKE,
} from './util';

export interface LineSeries {
  key: string;
  name?: string;
  stroke: string;
  strokeWidth?: number;
}

export interface LineChartProps {
  data: Datum[];
  series: LineSeries[];
  height: number;
  /** Render a monospace legend row below the plot. */
  legend?: boolean;
  yAxisWidth?: number;
  yDecimals?: boolean;
  xMinTickGap?: number;
}

// Multi-series smooth line chart with an optional legend and hover crosshair.
// Replaces recharts' <LineChart> + <Legend>.
export function LineChart(props: LineChartProps): JSX.Element {
  const { setRef, size } = useSize();
  const [hover, setHover] = createSignal<number | null>(null);
  let svg: SVGSVGElement | undefined;

  const g = createMemo(() => geometry(size().w, size().h, props.yAxisWidth ?? 0));
  const maxY = createMemo(() => {
    let m = 0;
    for (const d of props.data) for (const s of props.series) m = Math.max(m, Number(d[s.key]) || 0);
    return m;
  });
  const scale = createMemo(() => yScale(maxY(), props.yDecimals ?? true));
  const labels = createMemo(() => props.data.map((d) => d.label));
  const xTicks = createMemo(() => pickXTicks(labels(), g().plotW, props.xMinTickGap ?? 48));

  const px = (i: number) => xAt(i, props.data.length, g());
  const py = (v: number) => yAt(v, scale().max, g());

  const onMove = (e: MouseEvent) => {
    if (!svg) return;
    const { x } = localXY(e, svg);
    setHover(nearestPoint(x, props.data.length, g()));
  };

  const rows = (): TooltipRow[] => {
    const i = hover();
    if (i === null) return [];
    return props.series.map((s) => ({ name: s.name ?? s.key, value: Number(props.data[i]?.[s.key]) || 0, color: s.stroke }));
  };

  return (
    <div style={{ position: 'relative', width: '100%', height: `${props.height}px`, display: 'flex', 'flex-direction': 'column' }}>
      <div ref={setRef} style={{ position: 'relative', width: '100%', flex: 1, 'min-height': 0 }}>
        <Show when={size().w > 0 && size().h > 0}>
          <svg
            ref={svg}
            width={size().w}
            height={size().h}
            onMouseMove={onMove}
            onMouseLeave={() => setHover(null)}
          >
            <Frame geo={g()} yTicks={scale().ticks} yAt={py} showY={props.yAxisWidth != null} xTicks={xTicks()} xAt={px} labels={labels()} />

            <For each={props.series}>
              {(s) => (
                <path
                  d={smoothPath(props.data.map((d, i) => [px(i), py(Number(d[s.key]) || 0)]))}
                  fill="none"
                  stroke={s.stroke}
                  stroke-width={s.strokeWidth ?? 2}
                  stroke-linejoin="round"
                  stroke-linecap="round"
                />
              )}
            </For>

            <Show when={hover() !== null}>
              <line x1={px(hover()!)} x2={px(hover()!)} y1={g().top} y2={g().height - g().bottom} stroke={CURSOR} stroke-width="1" />
              <For each={props.series}>
                {(s) => (
                  <circle
                    cx={px(hover()!)}
                    cy={py(Number(props.data[hover()!]?.[s.key]) || 0)}
                    r="4"
                    fill={s.stroke}
                    stroke={DOT_STROKE}
                    stroke-width="2"
                  />
                )}
              </For>
            </Show>
          </svg>
        </Show>
      </div>
      <Show when={props.legend}>
        <div
          style={{
            display: 'flex',
            'flex-wrap': 'wrap',
            'justify-content': 'center',
            gap: '12px',
            'font-size': '11px',
            'font-family': MONO,
            color: '#a1a1aa',
            'padding-top': '6px',
          }}
        >
          <For each={props.series}>
            {(s) => (
              <span style={{ display: 'inline-flex', 'align-items': 'center', gap: '5px' }}>
                <span style={{ width: '10px', height: '2px', background: s.stroke, display: 'inline-block' }} />
                {s.name ?? s.key}
              </span>
            )}
          </For>
        </div>
      </Show>
      <Show when={hover() !== null}>
        <ChartTooltip x={px(hover()!)} containerW={size().w} label={labels()[hover()!]} rows={rows()} />
      </Show>
    </div>
  );
}

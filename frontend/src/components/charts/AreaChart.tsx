import { createSignal, createMemo, createUniqueId, For, Show, type JSX } from 'solid-js';
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
  CURSOR,
  DOT_STROKE,
} from './util';

export interface AreaSeries {
  /** Numeric field on each datum. */
  key: string;
  /** Legend/tooltip label; falls back to `key`. */
  name?: string;
  stroke: string;
  strokeWidth?: number;
  /** Dashed stroke, e.g. `'5 4'`. */
  strokeDasharray?: string;
  /** `'gradient'` fades the stroke colour to transparent; `'none'` = line only. */
  fill?: 'gradient' | 'none';
  /** Top opacity of the gradient fill (default 0.22). */
  fillOpacity?: number;
}

export interface AreaChartProps {
  data: Datum[];
  series: AreaSeries[];
  /** Total container height in px. */
  height: number;
  /** Reserve this many px for a Y axis; omit to hide it. */
  yAxisWidth?: number;
  yDecimals?: boolean;
  xMinTickGap?: number;
}

// Gradient-filled area chart with a smooth monotone stroke, a crosshair + active
// dots on hover, and an HTML tooltip. Replaces recharts' <AreaChart>.
export function AreaChart(props: AreaChartProps): JSX.Element {
  const { setRef, size } = useSize();
  const [hover, setHover] = createSignal<number | null>(null);
  const gid = createUniqueId();
  let svg: SVGSVGElement | undefined;

  const g = createMemo(() => geometry(size().w, size().h, props.yAxisWidth ?? 0));
  const maxY = createMemo(() => {
    let m = 0;
    for (const d of props.data) for (const s of props.series) m = Math.max(m, Number(d[s.key]) || 0);
    return m;
  });
  const scale = createMemo(() => yScale(maxY(), props.yDecimals ?? true));
  const labels = createMemo(() => props.data.map((d) => d.label));
  const xTicks = createMemo(() => pickXTicks(labels(), g().plotW, props.xMinTickGap ?? 56));

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
            <defs>
              <For each={props.series}>
                {(s) => (
                  <Show when={(s.fill ?? 'gradient') === 'gradient'}>
                    <linearGradient id={`${gid}-${s.key}`} x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stop-color={s.stroke} stop-opacity={s.fillOpacity ?? 0.22} />
                      <stop offset="95%" stop-color={s.stroke} stop-opacity={0} />
                    </linearGradient>
                  </Show>
                )}
              </For>
            </defs>

            <Frame geo={g()} yTicks={scale().ticks} yAt={py} showY={props.yAxisWidth != null} xTicks={xTicks()} xAt={px} labels={labels()} />

            <For each={props.series}>
              {(s) => {
                const pts = (): Array<[number, number]> => props.data.map((d, i) => [px(i), py(Number(d[s.key]) || 0)]);
                const line = () => smoothPath(pts());
                const area = () => {
                  const p = pts();
                  if (p.length === 0) return '';
                  const base = g().height - g().bottom;
                  return `${smoothPath(p)} L${p[p.length - 1][0]},${base} L${p[0][0]},${base} Z`;
                };
                return (
                  <>
                    <Show when={(s.fill ?? 'gradient') === 'gradient'}>
                      <path d={area()} fill={`url(#${gid}-${s.key})`} stroke="none" />
                    </Show>
                    <path
                      d={line()}
                      fill="none"
                      stroke={s.stroke}
                      stroke-width={s.strokeWidth ?? 2}
                      stroke-dasharray={s.strokeDasharray}
                      stroke-linejoin="round"
                      stroke-linecap="round"
                    />
                  </>
                );
              }}
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
      <Show when={hover() !== null}>
        <ChartTooltip x={px(hover()!)} containerW={size().w} label={labels()[hover()!]} rows={rows()} />
      </Show>
    </div>
  );
}

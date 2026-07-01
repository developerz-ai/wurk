// Dependency-free SolidJS SVG charts — the recharts replacement. Dark Obsidian
// palette, responsive to container width/height, smooth monotone paths, hover
// crosshair + tooltip. See ./util for the shared primitives.
export { AreaChart, type AreaSeries, type AreaChartProps } from './AreaChart';
export { LineChart, type LineSeries, type LineChartProps } from './LineChart';
export { BarChart, type BarDatum, type BarChartProps } from './BarChart';
export type { Datum } from './util';

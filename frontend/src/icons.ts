// Every glyph the dashboard draws, taken from Font Awesome Free's SVGs (icons
// CC BY 4.0, https://fontawesome.com/license/free). Importing only the ones
// the UI draws replaces the full webfonts and stylesheet, which shipped every
// glyph to every visitor. A new icon is one import and one entry below: the
// `IconName` type then lets <Icon> take it. Solid unless the key says otherwise
// (`calendar` is the regular style, `github` the brand mark).
import anglesLeft from '@fortawesome/fontawesome-free/svgs/solid/angles-left.svg?raw';
import anglesRight from '@fortawesome/fontawesome-free/svgs/solid/angles-right.svg?raw';
import arrowDownWideShort from '@fortawesome/fontawesome-free/svgs/solid/arrow-down-wide-short.svg?raw';
import arrowRight from '@fortawesome/fontawesome-free/svgs/solid/arrow-right.svg?raw';
import arrowUpRightFromSquare from '@fortawesome/fontawesome-free/svgs/solid/arrow-up-right-from-square.svg?raw';
import arrowUpShortWide from '@fortawesome/fontawesome-free/svgs/solid/arrow-up-short-wide.svg?raw';
import ban from '@fortawesome/fontawesome-free/svgs/solid/ban.svg?raw';
import bars from '@fortawesome/fontawesome-free/svgs/solid/bars.svg?raw';
import bolt from '@fortawesome/fontawesome-free/svgs/solid/bolt.svg?raw';
import book from '@fortawesome/fontawesome-free/svgs/solid/book.svg?raw';
import calendarRegular from '@fortawesome/fontawesome-free/svgs/regular/calendar.svg?raw';
import chartLine from '@fortawesome/fontawesome-free/svgs/solid/chart-line.svg?raw';
import check from '@fortawesome/fontawesome-free/svgs/solid/check.svg?raw';
import circleCheck from '@fortawesome/fontawesome-free/svgs/solid/circle-check.svg?raw';
import circleExclamation from '@fortawesome/fontawesome-free/svgs/solid/circle-exclamation.svg?raw';
import circleInfo from '@fortawesome/fontawesome-free/svgs/solid/circle-info.svg?raw';
import circleHalfStroke from '@fortawesome/fontawesome-free/svgs/solid/circle-half-stroke.svg?raw';
import clock from '@fortawesome/fontawesome-free/svgs/solid/clock.svg?raw';
import compass from '@fortawesome/fontawesome-free/svgs/solid/compass.svg?raw';
import crown from '@fortawesome/fontawesome-free/svgs/solid/crown.svg?raw';
import diagramProject from '@fortawesome/fontawesome-free/svgs/solid/diagram-project.svg?raw';
import download from '@fortawesome/fontawesome-free/svgs/solid/download.svg?raw';
import fire from '@fortawesome/fontawesome-free/svgs/solid/fire.svg?raw';
import gauge from '@fortawesome/fontawesome-free/svgs/solid/gauge.svg?raw';
import gaugeHigh from '@fortawesome/fontawesome-free/svgs/solid/gauge-high.svg?raw';
import gears from '@fortawesome/fontawesome-free/svgs/solid/gears.svg?raw';
import github from '@fortawesome/fontawesome-free/svgs/brands/github.svg?raw';
import globe from '@fortawesome/fontawesome-free/svgs/solid/globe.svg?raw';
import language from '@fortawesome/fontawesome-free/svgs/solid/language.svg?raw';
import layerGroup from '@fortawesome/fontawesome-free/svgs/solid/layer-group.svg?raw';
import magnifyingGlass from '@fortawesome/fontawesome-free/svgs/solid/magnifying-glass.svg?raw';
import memory from '@fortawesome/fontawesome-free/svgs/solid/memory.svg?raw';
import microchip from '@fortawesome/fontawesome-free/svgs/solid/microchip.svg?raw';
import moon from '@fortawesome/fontawesome-free/svgs/solid/moon.svg?raw';
import puzzlePiece from '@fortawesome/fontawesome-free/svgs/solid/puzzle-piece.svg?raw';
import rotateRight from '@fortawesome/fontawesome-free/svgs/solid/rotate-right.svg?raw';
import server from '@fortawesome/fontawesome-free/svgs/solid/server.svg?raw';
import skull from '@fortawesome/fontawesome-free/svgs/solid/skull.svg?raw';
import sort from '@fortawesome/fontawesome-free/svgs/solid/sort.svg?raw';
import spinner from '@fortawesome/fontawesome-free/svgs/solid/spinner.svg?raw';
import stopwatch from '@fortawesome/fontawesome-free/svgs/solid/stopwatch.svg?raw';
import sun from '@fortawesome/fontawesome-free/svgs/solid/sun.svg?raw';
import tableCellsLarge from '@fortawesome/fontawesome-free/svgs/solid/table-cells-large.svg?raw';
import triangleExclamation from '@fortawesome/fontawesome-free/svgs/solid/triangle-exclamation.svg?raw';
import upRightFromSquare from '@fortawesome/fontawesome-free/svgs/solid/up-right-from-square.svg?raw';
import xmark from '@fortawesome/fontawesome-free/svgs/solid/xmark.svg?raw';

const SOURCES = {
  'angles-left': anglesLeft,
  'angles-right': anglesRight,
  'arrow-down-wide-short': arrowDownWideShort,
  'arrow-right': arrowRight,
  'arrow-up-right-from-square': arrowUpRightFromSquare,
  'arrow-up-short-wide': arrowUpShortWide,
  'ban': ban,
  'bars': bars,
  'bolt': bolt,
  'book': book,
  'calendar': calendarRegular,
  'chart-line': chartLine,
  'check': check,
  'circle-check': circleCheck,
  'circle-exclamation': circleExclamation,
  'circle-half-stroke': circleHalfStroke,
  'circle-info': circleInfo,
  'clock': clock,
  'compass': compass,
  'crown': crown,
  'diagram-project': diagramProject,
  'download': download,
  'fire': fire,
  'gauge': gauge,
  'gauge-high': gaugeHigh,
  'gears': gears,
  'github': github,
  'globe': globe,
  'language': language,
  'layer-group': layerGroup,
  'magnifying-glass': magnifyingGlass,
  'memory': memory,
  'microchip': microchip,
  'moon': moon,
  'puzzle-piece': puzzlePiece,
  'rotate-right': rotateRight,
  'server': server,
  'skull': skull,
  'sort': sort,
  'spinner': spinner,
  'stopwatch': stopwatch,
  'sun': sun,
  'table-cells-large': tableCellsLarge,
  'triangle-exclamation': triangleExclamation,
  'up-right-from-square': upRightFromSquare,
  'xmark': xmark,
} as const;

export type IconName = keyof typeof SOURCES;

export interface Glyph {
  viewBox: string;
  path: string;
}

function parse(name: string, svg: string): Glyph {
  const viewBox = /viewBox="([^"]+)"/.exec(svg)?.[1];
  const path = /<path[^>]* d="([^"]+)"/.exec(svg)?.[1];
  if (!viewBox || !path) throw new Error(`icons: ${name}.svg is not a single-path Font Awesome glyph`);
  return { viewBox, path };
}

export const GLYPHS: Readonly<Record<IconName, Glyph>> = Object.freeze(
  Object.fromEntries(Object.entries(SOURCES).map(([name, svg]) => [name, parse(name, svg)])) as Record<
    IconName,
    Glyph
  >,
);

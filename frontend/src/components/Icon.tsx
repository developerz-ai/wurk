import type { JSX } from 'solid-js';
import { GLYPHS, type IconName } from '../icons';

interface IconProps {
  name: IconName;
  class?: string;
  style?: JSX.CSSProperties;
}

/**
 * A decorative glyph. The `<i>` keeps the box Font Awesome's webfont gave
 * (1.25em wide, 1em tall, sat on the text baseline), so every rule sizing or
 * recolouring an icon through `font-size`, `width` and `color` still applies.
 */
export default function Icon(props: IconProps) {
  return (
    <i class={props.class ? `wurk-icon ${props.class}` : 'wurk-icon'} style={props.style} aria-hidden="true">
      <svg viewBox={GLYPHS[props.name].viewBox}>
        <path d={GLYPHS[props.name].path} />
      </svg>
    </i>
  );
}

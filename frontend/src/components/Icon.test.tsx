import { describe, it, expect } from 'vitest';
import { render } from '@solidjs/testing-library';
import Icon from './Icon';
import { GLYPHS } from '../icons';

describe('Icon', () => {
  it('draws the named glyph as a decorative inline SVG', () => {
    const { container } = render(() => <Icon name="layer-group" />);
    const box = container.querySelector('i')!;
    expect(box).toHaveClass('wurk-icon');
    expect(box).toHaveAttribute('aria-hidden', 'true');
    expect(box.querySelector('svg')).toHaveAttribute('viewBox', GLYPHS['layer-group'].viewBox);
    expect(box.querySelector('path')).toHaveAttribute('d', GLYPHS['layer-group'].path);
  });

  it('keeps the caller class and style on the box', () => {
    const { container } = render(() => <Icon name="github" class="wurk-navlink__icon" style={{ width: '20px' }} />);
    const box = container.querySelector('i')!;
    expect(box).toHaveClass('wurk-icon', 'wurk-navlink__icon');
    expect(box.style.width).toBe('20px');
  });

  it('parses every shipped glyph to a viewBox and a path', () => {
    for (const [name, glyph] of Object.entries(GLYPHS)) {
      expect(glyph.viewBox, name).toMatch(/^0 0 \d+ 512$/);
      expect(glyph.path.length, name).toBeGreaterThan(0);
    }
  });

  // The Font Awesome stylesheet is gone (#918), so a `fa-*` class left in
  // markup or a selector now draws nothing. Locale tags like 'fa-IR' are
  // upper-case after the dash and don't match.
  it('leaves no Font Awesome classes in the sources', () => {
    const sources = import.meta.glob(['../**/*.{ts,tsx,scss,css}', '!../**/*.test.{ts,tsx}'], {
      query: '?raw',
      import: 'default',
      eager: true,
    }) as Record<string, string>;
    expect(Object.keys(sources).length).toBeGreaterThan(20);
    const leftovers = Object.entries(sources).flatMap(([file, text]) =>
      [...text.matchAll(/(?:^|[\s"'`.])(fa-[a-z][a-z0-9-]*)/gm)].map((m) => `${file}: ${m[1]}`),
    );
    expect(leftovers).toEqual([]);
  });
});

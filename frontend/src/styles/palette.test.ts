import { describe, it, expect } from 'vitest';

// `_tokens.scss` opens by claiming no component hardcodes a colour. It was
// false — the chart palette, the Obsidian sub-system and every overlay shadow
// each kept their own copy of the zinc ramp, so none of them followed
// `data-theme`. This walks the source and keeps the claim true, because the
// failure mode is silent: a literal renders perfectly in the palette it was
// picked against, and only breaks in the other one.
//
// Read through Vite's raw glob rather than node:fs — the SPA's tsconfig is
// browser-only (`lib: DOM`, no `@types/node`), and one test isn't worth
// widening the type surface every component then sees.
const SOURCES = import.meta.glob<string>(['../**/*.{ts,tsx,scss}', '!../**/*.test.*'], {
  query: '?raw',
  import: 'default',
  eager: true,
});

const TOKENS_PATH = './abstracts/_tokens.scss';

// `#fff`, `#fafafa`, `#ffffffcc`, plus the functional notations. `oklch()` and
// `color-mix()` over a token are fine — only literal channel values are not,
// which for oklch/rgb/hsl means a numeric first argument.
const LITERAL = /#[0-9a-f]{3}([0-9a-f]{3}([0-9a-f]{2})?)?\b|\b(?:rgba?|hsla?|oklch|oklab|lch|lab)\(\s*[.\d]/gi;

// Issue references (`#187`, `#272`) read as hex triples, and only ever appear
// in prose. Strip comments before matching rather than allow-list them one at a
// time. The `:` guard spares `https://`, the one `//` that isn't a comment.
function code(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
}

describe('design tokens', () => {
  it('are the only place a colour is written literally', () => {
    // A glob that stops resolving would green this test by scanning nothing.
    expect(Object.keys(SOURCES).length).toBeGreaterThan(50);

    const offenders = Object.entries(SOURCES)
      .filter(([path]) => path !== TOKENS_PATH)
      .flatMap(([path, source]) => (code(source).match(LITERAL) ?? []).map((literal) => `${path}: ${literal}`));

    expect(offenders).toEqual([]);
  });

  it('reverses the ink ladder in the light palette, so mono-1 is always the most contrast', () => {
    const [dark, light] = SOURCES[TOKENS_PATH].split(":root[data-theme='light']");
    const ladder = (block: string) => [...block.matchAll(/--mono-\d: (#[0-9a-f]{6})/g)].map((m) => m[1]);

    // Six steps each, and the two are mirrors: the light theme's strongest ink
    // is the dark theme's weakest. Everything keyed off `--mono-*` — chart
    // series, job dots, muted text — inverts for free because of this.
    expect(ladder(dark)).toHaveLength(6);
    expect(ladder(light)).toHaveLength(6);
    expect(ladder(dark)[0]).not.toEqual(ladder(light)[0]);
    expect(ladder(light)[5]).toEqual(ladder(dark)[1]);
  });
});

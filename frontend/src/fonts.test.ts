import { describe, it, expect } from 'vitest';
import tokens from './styles/abstracts/_tokens.scss?raw';
import geistSans from '@fontsource/geist-sans/500.css?raw';
import jetbrainsMono from '@fontsource/jetbrains-mono/500.css?raw';

// main.tsx bundles these @fontsource faces; the tokens must name the family
// each one registers, or the browser silently falls back to system-ui.
const registered = (css: string) => css.match(/font-family: '([^']+)'/)?.[1];
const firstFamily = (token: string) => tokens.match(new RegExp(`--${token}: '([^']+)'`))?.[1];

describe('font tokens', () => {
  it('name the families the bundled @fontsource faces register', () => {
    expect(firstFamily('font-sans')).toBe(registered(geistSans));
    expect(firstFamily('font-mono')).toBe(registered(jetbrainsMono));
    expect(firstFamily('font-sans')).toBeTruthy();
  });
});

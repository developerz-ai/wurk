import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import LocalePicker from './LocalePicker';
import { availableLocales, setLocale, t } from '../i18n';

// Only setLocale is stubbed: it persists and then reloads, and jsdom has no
// navigation. Everything else (t, availableLocales, the resolved locale) stays
// real so the picker is exercised against the actual bundle registry.
vi.mock('../i18n', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../i18n')>()),
  setLocale: vi.fn(),
}));

const label = (name: string) => t('nav.language_current', { name });

function open() {
  render(() => <LocalePicker />);
  const trigger = screen.getByRole('button', { name: label('English') });
  fireEvent.click(trigger);
  return trigger;
}

const items = () => screen.getAllByRole('menuitemradio');

// jsdom measures every element as a zero rect, so placement is the one
// behaviour that has to be handed a real one. Viewport is jsdom's 768px tall.
function openAt(top: number, height = 36) {
  render(() => <LocalePicker />);
  const trigger = screen.getByRole('button', { name: label('English') });
  vi.spyOn(trigger, 'getBoundingClientRect').mockReturnValue({
    top,
    bottom: top + height,
    left: 20,
    right: 84,
    height,
  } as DOMRect);
  fireEvent.click(trigger);
  return screen.getByRole('menu');
}

beforeEach(() => vi.mocked(setLocale).mockClear());

describe('LocalePicker', () => {
  it('labels the trigger with the resolved language and opens nothing until asked', () => {
    render(() => <LocalePicker />);
    const trigger = screen.getByRole('button', { name: label('English') });

    expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
    expect(trigger).toHaveAttribute('aria-expanded', 'false');
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('lists every shipped locale by endonym with the current one marked', () => {
    const trigger = open();

    expect(trigger).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('menu')).toHaveAccessibleName(t('nav.language'));
    expect(items()).toHaveLength(availableLocales.length);
    expect(items().map((el) => el.textContent)).toEqual([
      'English',
      'Español',
      'Français',
      'Deutsch',
      'Português (Brasil)',
      '日本語',
      '简体中文',
      'العربية',
    ]);
    // jsdom resolves navigator.language ("en-US") to the en bundle.
    expect(screen.getByRole('menuitemradio', { name: 'English' })).toHaveAttribute('aria-checked', 'true');
    expect(items().filter((el) => el.getAttribute('aria-checked') === 'true')).toHaveLength(1);
  });

  it('names every shipped bundle, never falling back to a raw tag', () => {
    open();
    // A row rendering its own code means ENDONYMS is missing that locale.
    items().forEach((el, i) => expect(el.textContent).not.toBe(availableLocales[i]));
  });

  it('tags each entry with its own lang so a screen reader pronounces the endonym', () => {
    open();
    expect(items().map((el) => el.getAttribute('lang'))).toEqual([...availableLocales]);
  });

  it('reports the pick to setLocale and closes', () => {
    open();
    fireEvent.click(screen.getByRole('menuitemradio', { name: '日本語' }));

    expect(vi.mocked(setLocale)).toHaveBeenCalledWith('ja');
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('still reports a pick of the language already showing', () => {
    // Persisting is the point: this is how a ?locale= support link becomes the
    // user's stored choice.
    open();
    fireEvent.click(screen.getByRole('menuitemradio', { name: 'English' }));
    expect(vi.mocked(setLocale)).toHaveBeenCalledWith('en');
  });

  it('opens onto the current entry and wraps arrow keys in both directions', () => {
    open();
    const last = availableLocales.length - 1;
    expect(document.activeElement).toBe(items()[0]);

    fireEvent.keyDown(document.activeElement!, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(items()[last]);

    fireEvent.keyDown(document.activeElement!, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(items()[0]);

    fireEvent.keyDown(document.activeElement!, { key: 'End' });
    expect(document.activeElement).toBe(items()[last]);

    fireEvent.keyDown(document.activeElement!, { key: 'Home' });
    expect(document.activeElement).toBe(items()[0]);
  });

  it('opens from the keyboard on either arrow', () => {
    render(() => <LocalePicker />);
    const trigger = screen.getByRole('button', { name: label('English') });

    fireEvent.keyDown(trigger, { key: 'ArrowUp' });
    expect(screen.getByRole('menu')).toBeInTheDocument();
  });

  it.each(['Escape', 'Tab'])('closes on %s, returning focus to the trigger', (key) => {
    const trigger = open();
    fireEvent.keyDown(document.activeElement!, { key });

    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(document.activeElement).toBe(trigger);
  });

  it('closes on an outside press without reporting a pick', () => {
    open();
    fireEvent.pointerDown(document.body);

    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(vi.mocked(setLocale)).not.toHaveBeenCalled();
  });

  it('closes when the rail scrolls out from under the anchored panel', () => {
    open();
    fireEvent.scroll(window);
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('opens upward from a trigger in the rail footer', () => {
    const menu = openAt(700);

    expect(menu.style.bottom).toBe('76px');
    expect(menu.style.top).toBe('');
    expect(menu.style.maxHeight).toBe('684px');
  });

  it('flips below the trigger when there is no room above', () => {
    // A short viewport or the mobile drawer can put the footer near the top;
    // opening upward there would strand the entries off-screen.
    const menu = openAt(10);

    expect(menu.style.top).toBe('54px');
    expect(menu.style.bottom).toBe('');
    expect(menu.style.maxHeight).toBe('706px');
  });

  it.each([0, 40, 120, 400, 740, 760])('keeps the panel on screen from %ipx', (top) => {
    const { style } = openAt(top);
    const height = parseFloat(style.maxHeight);
    // Whichever edge it is pinned to, the panel grows away from it — so both
    // ends have to land inside the viewport.
    const edge = parseFloat(style.bottom || style.top);

    expect(height).toBeGreaterThan(0);
    expect(edge).toBeGreaterThanOrEqual(0);
    expect(edge + height).toBeLessThanOrEqual(window.innerHeight);
  });
});

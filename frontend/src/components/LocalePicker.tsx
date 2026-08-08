import { For, Show, createEffect, createSignal, onCleanup } from 'solid-js';
import { Portal } from 'solid-js/web';
import { availableLocales, bundleFor, locale, setLocale, t } from '../i18n';

// Endonyms: every language named in itself, never translated — a menu that
// offers "German" to someone who can't read English is useless. Keyed by the
// bundle codes in `i18n/index.ts`; a bundle added there without an entry here
// falls back to its raw tag, and LocalePicker.test.tsx fails on the gap rather
// than letting a bare "pt-BR" ship.
const ENDONYMS: Record<string, string> = {
  en: 'English',
  es: 'Español',
  fr: 'Français',
  de: 'Deutsch',
  'pt-BR': 'Português (Brasil)',
  ja: '日本語',
  'zh-CN': '简体中文',
  ar: 'العربية',
};

/** Gap between the trigger and the panel, and the panel's viewport margin. */
const GAP = 8;

/** Room the panel wants; short of it, `open()` takes the roomier side. */
const MIN_PANEL = 160;

interface Anchor {
  /** Distance from the viewport's inline-start edge (right edge under RTL). */
  start: number;
  /** Whether the panel hangs above the trigger; below it when false. */
  up: boolean;
  /** Distance from the viewport edge the panel is pinned to. */
  offset: number;
  maxHeight: number;
}

/**
 * Language menu for the nav rail's footer. The locale is baked in at module
 * load (`Nav.tsx`'s LINKS call `t()` once), so picking one reloads the page —
 * `setLocale()` owns that, see `i18n/index.ts`.
 */
export default function LocalePicker() {
  // The resolved locale can't change without a reload, so these are constants,
  // not signals. A locale with no bundle ("he") marks nothing and labels the
  // trigger with its raw tag.
  const active = bundleFor(locale);
  const currentLabel = ENDONYMS[active ?? ''] ?? locale;

  let trigger!: HTMLButtonElement;
  let panel: HTMLDivElement | undefined;
  const items: HTMLButtonElement[] = [];

  // The anchor doubles as the open flag — one source of truth, so an open menu
  // can never be un-positioned.
  const [anchor, setAnchor] = createSignal<Anchor | null>(null);
  const isOpen = () => anchor() !== null;
  const activeIndex = () => Math.max(0, availableLocales.indexOf(active ?? ''));

  const open = () => {
    const r = trigger.getBoundingClientRect();
    // Fixed + portaled so the panel escapes the rail's `overflow: hidden`,
    // which would otherwise clip it to 64px in the collapsed rail. Anchored to
    // the trigger's inline-start edge — the viewport's right edge under RTL.
    const rtl = document.documentElement.dir === 'rtl';
    // Room left on each side of the trigger once both gaps are spent: one
    // between panel and trigger, one between panel and viewport edge.
    const above = r.top - GAP * 2;
    const below = window.innerHeight - r.bottom - GAP * 2;
    // Upward is the natural direction — the trigger sits in the rail's footer —
    // but a trigger high in the viewport would push a fixed panel off the top
    // edge, where its own scrollbar can't bring the clipped entries back.
    const up = above >= MIN_PANEL || above >= below;
    setAnchor({
      start: rtl ? window.innerWidth - r.right : r.left,
      up,
      offset: up ? window.innerHeight - r.top + GAP : r.bottom + GAP,
      // Never taller than the side it opened onto: entries past the viewport
      // edge are unreachable, entries past the panel's edge only need a scroll.
      maxHeight: Math.max(up ? above : below, 0),
    });
    // Solid renders the panel synchronously with the write above, so its refs
    // are already assigned here.
    items[activeIndex()]?.focus();
  };

  const close = (refocus: boolean) => {
    setAnchor(null);
    if (refocus) trigger.focus();
  };

  const choose = (code: string) => {
    close(false);
    // Re-picking the language that's already showing is not a no-op: arriving
    // on a ?locale= support link and clicking that language is how the pick
    // becomes the persisted one.
    setLocale(code);
  };

  const focusItem = (i: number) => items[i]?.focus();

  const onPanelKeyDown = (e: KeyboardEvent) => {
    const last = availableLocales.length - 1;
    const cur = items.findIndex((el) => el === document.activeElement);
    switch (e.key) {
      case 'ArrowDown':
        focusItem(cur >= last ? 0 : cur + 1);
        break;
      case 'ArrowUp':
        focusItem(cur <= 0 ? last : cur - 1);
        break;
      case 'Home':
        focusItem(0);
        break;
      case 'End':
        focusItem(last);
        break;
      case 'Escape':
      // Tab out of a portaled panel would land focus at the end of <body>,
      // nowhere near the rail, so it returns to the trigger instead; the next
      // Tab then continues from there through the rest of the nav.
      case 'Tab':
        close(true);
        break;
      default:
        return;
    }
    e.preventDefault();
  };

  const onTriggerKeyDown = (e: KeyboardEvent) => {
    // The panel lands on whichever side has room, so both arrows open it.
    if (isOpen() || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) return;
    e.preventDefault();
    open();
  };

  createEffect(() => {
    if (!isOpen()) return;
    const onPointerDown = (e: Event) => {
      const target = e.target as Node;
      if (!panel?.contains(target) && !trigger.contains(target)) close(false);
    };
    // The rail scrolls its own overflow, so the trigger can move out from under
    // a positioned panel. Close rather than chase it.
    const onViewportChange = () => close(false);
    document.addEventListener('pointerdown', onPointerDown, true);
    window.addEventListener('scroll', onViewportChange, true);
    window.addEventListener('resize', onViewportChange);
    onCleanup(() => {
      document.removeEventListener('pointerdown', onPointerDown, true);
      window.removeEventListener('scroll', onViewportChange, true);
      window.removeEventListener('resize', onViewportChange);
    });
  });

  return (
    <>
      <button
        ref={trigger}
        type="button"
        class="wurk-navlink locale-picker__trigger"
        aria-haspopup="menu"
        aria-expanded={isOpen()}
        aria-label={t('nav.language_current', { name: currentLabel })}
        title={t('nav.language')}
        onClick={() => (isOpen() ? close(false) : open())}
        onKeyDown={onTriggerKeyDown}
      >
        <i class="fa-solid fa-language wurk-navlink__icon" aria-hidden="true" />
        <span class="nav-label">
          <bdi>{currentLabel}</bdi>
        </span>
      </button>

      <Show when={anchor()}>
        {(pos) => (
          <Portal>
            <div
              ref={panel}
              role="menu"
              aria-label={t('nav.language')}
              class="locale-menu"
              style={{
                'inset-inline-start': `${pos().start}px`,
                ...(pos().up ? { bottom: `${pos().offset}px` } : { top: `${pos().offset}px` }),
                'max-height': `${pos().maxHeight}px`,
              }}
              onKeyDown={onPanelKeyDown}
            >
              <For each={availableLocales}>
                {(code, i) => (
                  <button
                    ref={(el) => (items[i()] = el)}
                    type="button"
                    role="menuitemradio"
                    aria-checked={code === active}
                    class="locale-menu__item"
                    // `lang` so a screen reader pronounces the endonym in its own
                    // language; `<bdi>` keeps an RTL name from reordering the row.
                    lang={code}
                    onClick={() => choose(code)}
                  >
                    <bdi>{ENDONYMS[code] ?? code}</bdi>
                    <Show when={code === active}>
                      <i class="fa-solid fa-check" aria-hidden="true" />
                    </Show>
                  </button>
                )}
              </For>
            </div>
          </Portal>
        )}
      </Show>
    </>
  );
}

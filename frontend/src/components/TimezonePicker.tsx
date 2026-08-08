import { For, Show, createEffect, createMemo, createSignal } from 'solid-js';
import { t } from '../i18n';
import { browserZone, setTimeZone, storedZone, supportedZones, timeZone } from '../tz';
import Modal from './Modal';

interface Entry {
  /** The zone to persist, or null for the entry that clears the override. */
  zone: string | null;
  label: string;
  selected: boolean;
}

/** Folds a zone id and a query onto common ground: "America/New_York" -> "america new york". */
function normalize(s: string): string {
  return s.toLowerCase().replace(/[_/]/g, ' ');
}

/** "Europe/Berlin" -> "Berlin". The rail is far too narrow for the full id. */
function shortLabel(zone: string): string {
  return zone.slice(zone.lastIndexOf('/') + 1).replace(/_/g, ' ');
}

/**
 * Timezone menu for the nav rail's footer, next to the language one. There are
 * ~400 zones, so this opens a filterable dialog rather than the flat menu eight
 * locales get. The resolved zone is baked in at module load (`tz.ts`), so
 * picking one reloads the page — `setTimeZone()` owns that.
 */
export default function TimezonePicker() {
  // Fixed for the page's life, for the same reason: nothing here can change
  // without the reload.
  const override = storedZone();
  const automatic = browserZone();

  const [isOpen, setIsOpen] = createSignal(false);
  const [query, setQuery] = createSignal('');

  let filter: HTMLInputElement | undefined;
  let list: HTMLDivElement | undefined;
  // Read from the DOM rather than collected into a ref array as the rows
  // render: the list is filtered while the user types, and a stale ref array
  // would move focus onto a row that is no longer on screen.
  const options = () => Array.from(list?.querySelectorAll<HTMLButtonElement>('[role="option"]') ?? []);

  const entries = createMemo<Entry[]>(() => {
    const all: Entry[] = [
      { zone: null, label: t('timezone.automatic', { name: automatic }), selected: override === undefined },
      ...supportedZones().map((zone) => ({ zone, label: zone, selected: zone === override })),
    ];
    const q = normalize(query().trim());
    return q ? all.filter((entry) => normalize(entry.label).includes(q)) : all;
  });

  const close = () => {
    setIsOpen(false);
    setQuery('');
  };

  const choose = (zone: string | null) => {
    close();
    // Re-picking the zone already showing is not a no-op: it's how the browser
    // zone becomes a pinned choice that survives the OS zone changing.
    setTimeZone(zone);
  };

  // The dialog opens onto its filter — this list is long enough that typing is
  // the way in, not scrolling.
  createEffect(() => {
    if (isOpen()) filter?.focus();
  });

  const onFilterKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      options()[0]?.focus();
    } else if (e.key === 'Enter' && query().trim()) {
      // Only with a query: on the unfiltered list the first row is "automatic",
      // which nobody means to pick by pressing Enter on an empty field.
      const first = entries()[0];
      if (!first) return;
      choose(first.zone);
    } else {
      return;
    }
    e.preventDefault();
  };

  const onListKeyDown = (e: KeyboardEvent) => {
    const rows = options();
    const cur = rows.findIndex((el) => el === document.activeElement);
    switch (e.key) {
      case 'ArrowDown':
        rows[Math.min(cur + 1, rows.length - 1)]?.focus();
        break;
      case 'ArrowUp':
        // Off the top of the list is back to the filter, so a correction
        // doesn't need a reach for the mouse.
        if (cur <= 0) filter?.focus();
        else rows[cur - 1].focus();
        break;
      case 'Home':
        rows[0]?.focus();
        break;
      case 'End':
        rows[rows.length - 1]?.focus();
        break;
      default:
        return;
    }
    e.preventDefault();
  };

  return (
    <>
      <button
        type="button"
        class="wurk-navlink timezone-picker__trigger"
        aria-haspopup="dialog"
        aria-expanded={isOpen()}
        aria-label={t('nav.timezone_current', { name: timeZone })}
        title={t('timezone.shown_in', { name: timeZone })}
        onClick={() => setIsOpen(true)}
      >
        <i class="fa-solid fa-globe wurk-navlink__icon" aria-hidden="true" />
        <span class="nav-label">
          <bdi>{shortLabel(timeZone)}</bdi>
        </span>
      </button>

      <Modal open={isOpen()} onClose={close} title={t('timezone.title')} width={420}>
        {/* Gated so ~400 rows are built when the dialog opens, not on every
            page load — Nav, and this picker with it, is mounted for the app's
            whole lifetime. */}
        <Show when={isOpen()}>
          <p class="timezone-picker__hint">{t('timezone.shown_in', { name: timeZone })}</p>
          <input
            ref={filter}
            class="input timezone-picker__filter"
            type="search"
            value={query()}
            placeholder={t('timezone.filter')}
            aria-label={t('timezone.filter')}
            aria-controls="timezone-picker-list"
            onInput={(e) => setQuery(e.currentTarget.value)}
            onKeyDown={onFilterKeyDown}
          />
          <div
            ref={list}
            id="timezone-picker-list"
            role="listbox"
            aria-label={t('timezone.title')}
            class="timezone-picker__list"
            onKeyDown={onListKeyDown}
          >
            <For each={entries()}>
              {(entry) => (
                <button
                  type="button"
                  role="option"
                  aria-selected={entry.selected}
                  class="timezone-picker__option"
                  onClick={() => choose(entry.zone)}
                >
                  <bdi>{entry.label}</bdi>
                  <Show when={entry.selected}>
                    <i class="fa-solid fa-check" aria-hidden="true" />
                  </Show>
                </button>
              )}
            </For>
          </div>
          <Show when={entries().length === 0}>
            <p class="timezone-picker__empty">{t('timezone.empty', { query: query().trim() })}</p>
          </Show>
        </Show>
      </Modal>
    </>
  );
}

import { createSignal } from 'solid-js';
import { t } from '../i18n';
import { setThemePreference, themePreference, type ThemePreference } from '../theme';

// Cycle order and the icon each state wears. `system` leads because it is the
// default, so the first press off it is an explicit "no, this one".
const CYCLE: readonly { preference: ThemePreference; icon: string }[] = [
  { preference: 'system', icon: 'fa-circle-half-stroke' },
  { preference: 'light', icon: 'fa-sun' },
  { preference: 'dark', icon: 'fa-moon' },
];

/**
 * Theme control for the nav rail's footer, next to the language and timezone
 * pickers. A cycling button rather than a menu: three states, and unlike those
 * two the switch is instant — no reload — so pressing through them is how you
 * see them. The applied palette lives on `<html data-theme>`; `theme.ts` owns
 * the stamp.
 */
export default function ThemeToggle() {
  // The only writer of the preference on the page, so a local signal is the
  // whole reactive story — `theme.ts` re-resolves for the OS listener itself.
  const [preference, setPreference] = createSignal(themePreference());

  const index = () => CYCLE.findIndex((state) => state.preference === preference());
  const icon = () => CYCLE[index()].icon;
  const next = () => CYCLE[(index() + 1) % CYCLE.length].preference;
  const label = (state: ThemePreference) => t(`theme.${state}`);

  const cycle = () => {
    const pick = next();
    setPreference(pick);
    setThemePreference(pick);
  };

  return (
    <button
      type="button"
      class="wurk-navlink theme-toggle__trigger"
      // The accessible name carries the current state, the tooltip what a press
      // does — a three-way cycle can say neither with `aria-pressed`.
      aria-label={t('nav.theme_current', { name: label(preference()) })}
      title={t('nav.theme_next', { name: label(next()) })}
      onClick={cycle}
    >
      <i class={`fa-solid ${icon()} wurk-navlink__icon`} aria-hidden="true" />
      <span class="nav-label">{label(preference())}</span>
    </button>
  );
}

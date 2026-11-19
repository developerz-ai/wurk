// Props for a non-button element that opens a detail view on click — a table
// row, a card. A bare `onClick` leaves it out of the tab order, so a keyboard
// user can never reach the detail behind it; these make it focusable and give
// Enter/Space the click's effect. Keys that bubble up from a control inside
// the element (a row checkbox, an action button) are that control's own.
export function activatable(open: () => void) {
  return {
    tabindex: 0,
    onClick: open,
    onKeyDown: (e: KeyboardEvent) => {
      if (e.target !== e.currentTarget || (e.key !== 'Enter' && e.key !== ' ')) return;
      e.preventDefault();
      open();
    },
  };
}

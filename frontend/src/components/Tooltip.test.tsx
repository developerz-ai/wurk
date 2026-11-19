import { describe, it, expect } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import { Tooltip } from './Tooltip';

function renderTip() {
  render(() => (
    <Tooltip tip="Stops fetching from this queue">
      <button type="button">Pause</button>
    </Tooltip>
  ));
  return screen.getByRole('button', { name: 'Pause' });
}

describe('Tooltip', () => {
  it('shows on hover and hides on leave', () => {
    const button = renderTip();

    fireEvent.mouseEnter(button.parentElement!);
    expect(screen.getByRole('tooltip')).toHaveTextContent('Stops fetching from this queue');
    fireEvent.mouseLeave(button.parentElement!);

    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument();
  });

  it('shows on keyboard focus, described by the tip, and hides on blur', () => {
    const button = renderTip();

    fireEvent.focusIn(button);
    const tip = screen.getByRole('tooltip');
    expect(button.getAttribute('aria-describedby')).toBe(tip.id);
    fireEvent.focusOut(button);

    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument();
  });

  it('dismisses on Escape while focused', () => {
    const button = renderTip();

    fireEvent.focusIn(button);
    fireEvent.keyDown(button, { key: 'Escape' });

    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument();
  });
});

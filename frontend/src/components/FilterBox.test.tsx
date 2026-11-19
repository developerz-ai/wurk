import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import { createSignal } from 'solid-js';
import { FilterBox } from './FilterBox';

const DEBOUNCE_MS = 250;

function renderBox(initial = '') {
  const [value, setValue] = createSignal(initial);
  const onChange = vi.fn((v: string) => setValue(v));
  render(() => <FilterBox value={value()} onChange={onChange} placeholder="filter" />);
  return { input: screen.getByRole('searchbox') as HTMLInputElement, onChange, setValue };
}

describe('FilterBox', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('emits the typed value once, after the debounce', () => {
    const { input, onChange } = renderBox();

    fireEvent.input(input, { target: { value: 'a' } });
    fireEvent.input(input, { target: { value: 'ab' } });
    expect(onChange).not.toHaveBeenCalled();
    vi.advanceTimersByTime(DEBOUNCE_MS);

    expect(onChange.mock.calls).toEqual([['ab']]);
  });

  // Browser Back on Batches `?tag=`: the owner's value changes with no keystroke.
  it('adopts a value changed from outside, without emitting it back', () => {
    const { input, onChange, setValue } = renderBox('customer:1');

    setValue('');
    expect(input.value).toBe('');
    vi.advanceTimersByTime(DEBOUNCE_MS);

    expect(onChange).not.toHaveBeenCalled();
  });

  it('keeps what is being typed when its own earlier emit comes back', () => {
    const { input, onChange } = renderBox();

    fireEvent.input(input, { target: { value: 'ab' } });
    vi.advanceTimersByTime(DEBOUNCE_MS);
    // The owner now holds 'ab'; the user is already past it.
    fireEvent.input(input, { target: { value: 'abc' } });
    expect(input.value).toBe('abc');
    vi.advanceTimersByTime(DEBOUNCE_MS);

    expect(onChange.mock.calls).toEqual([['ab'], ['abc']]);
    expect(input.value).toBe('abc');
  });

  it('emits again after an outside reset to a value typed before', () => {
    const { input, onChange, setValue } = renderBox();

    fireEvent.input(input, { target: { value: 'ab' } });
    vi.advanceTimersByTime(DEBOUNCE_MS);
    setValue('');
    fireEvent.input(input, { target: { value: 'ab' } });
    vi.advanceTimersByTime(DEBOUNCE_MS);

    expect(onChange.mock.calls).toEqual([['ab'], ['ab']]);
  });
});

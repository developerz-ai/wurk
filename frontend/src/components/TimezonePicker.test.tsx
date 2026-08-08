import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import TimezonePicker from './TimezonePicker';
import { t } from '../i18n';
import { browserZone, setTimeZone, timeZone } from '../tz';

// Only setTimeZone is stubbed: it persists and then reloads, and jsdom has no
// navigation. Resolution stays real so the picker is exercised against the
// zones Intl actually offers.
vi.mock('../tz', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../tz')>()),
  setTimeZone: vi.fn(),
}));

// jsdom has no <dialog> top-layer support. Unlike Modal.test.tsx's inert stubs,
// these carry the `open` state: a closed <dialog> keeps its subtree out of the
// accessibility tree, and every query below is a role query.
HTMLDialogElement.prototype.showModal = vi.fn(function (this: HTMLDialogElement) {
  this.open = true;
});
HTMLDialogElement.prototype.close = vi.fn(function (this: HTMLDialogElement) {
  this.open = false;
});

const trigger = () => screen.getByRole('button', { name: t('nav.timezone_current', { name: timeZone }) });
const options = () => screen.getAllByRole('option');
const filter = () => screen.getByRole('searchbox', { name: t('timezone.filter') });

function open() {
  render(() => <TimezonePicker />);
  fireEvent.click(trigger());
}

function type(query: string) {
  const input = filter();
  fireEvent.input(input, { target: { value: query } });
  return input;
}

beforeEach(() => vi.mocked(setTimeZone).mockClear());
afterEach(() => localStorage.clear());

describe('TimezonePicker', () => {
  it('labels the trigger with the resolved zone and opens nothing until asked', () => {
    render(() => <TimezonePicker />);

    expect(trigger()).toHaveAttribute('aria-haspopup', 'dialog');
    expect(trigger()).toHaveAttribute('aria-expanded', 'false');
    expect(trigger()).toHaveAttribute('title', t('timezone.shown_in', { name: timeZone }));
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('says which zone the times on screen are in', () => {
    open();
    expect(screen.getByText(t('timezone.shown_in', { name: timeZone }))).toBeInTheDocument();
  });

  it('leads with the automatic entry, then UTC, then the IANA zones', () => {
    open();
    const labels = options().map((el) => el.textContent);

    expect(trigger()).toHaveAttribute('aria-expanded', 'true');
    expect(labels[0]).toBe(t('timezone.automatic', { name: browserZone() }));
    expect(labels[1]).toBe('UTC');
    expect(labels).toContain('America/New_York');
  });

  it('marks the automatic entry while no zone is pinned', () => {
    open();
    const selected = options().filter((el) => el.getAttribute('aria-selected') === 'true');

    expect(selected).toHaveLength(1);
    expect(selected[0].textContent).toBe(t('timezone.automatic', { name: browserZone() }));
  });

  it('marks the pinned zone instead once one is stored', () => {
    localStorage.setItem('wurk.tz', 'Asia/Tokyo');
    open();
    const selected = options().filter((el) => el.getAttribute('aria-selected') === 'true');

    expect(selected).toHaveLength(1);
    expect(selected[0].textContent).toBe('Asia/Tokyo');
  });

  it('narrows the list as the user types, ignoring separators and case', () => {
    open();
    type('new york');

    expect(options().map((el) => el.textContent)).toEqual(['America/New_York']);
  });

  it('says so when nothing matches', () => {
    open();
    type('atlantis');

    expect(screen.queryAllByRole('option')).toHaveLength(0);
    expect(screen.getByText(t('timezone.empty', { query: 'atlantis' }))).toBeInTheDocument();
  });

  it('reports a pinned zone and closes', () => {
    open();
    type('tokyo');
    fireEvent.click(screen.getByRole('option', { name: 'Asia/Tokyo' }));

    expect(vi.mocked(setTimeZone)).toHaveBeenCalledWith('Asia/Tokyo');
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('reports null for the automatic entry, dropping the override', () => {
    localStorage.setItem('wurk.tz', 'Asia/Tokyo');
    open();
    fireEvent.click(options()[0]);

    expect(vi.mocked(setTimeZone)).toHaveBeenCalledWith(null);
  });

  it('takes the first match on Enter, so a filtered pick needs no mouse', () => {
    open();
    fireEvent.keyDown(type('lisbon'), { key: 'Enter' });

    expect(vi.mocked(setTimeZone)).toHaveBeenCalledWith('Europe/Lisbon');
  });

  it('ignores Enter on an empty filter rather than pinning the automatic entry', () => {
    open();
    fireEvent.keyDown(filter(), { key: 'Enter' });

    expect(vi.mocked(setTimeZone)).not.toHaveBeenCalled();
  });

  it('walks the list from the filter and back again', () => {
    open();
    type('europe/l');
    const rows = options();
    expect(rows.length).toBeGreaterThan(1);

    fireEvent.keyDown(filter(), { key: 'ArrowDown' });
    expect(document.activeElement).toBe(rows[0]);

    fireEvent.keyDown(document.activeElement!, { key: 'End' });
    expect(document.activeElement).toBe(rows[rows.length - 1]);

    fireEvent.keyDown(document.activeElement!, { key: 'Home' });
    expect(document.activeElement).toBe(rows[0]);

    fireEvent.keyDown(document.activeElement!, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(rows[1]);

    fireEvent.keyDown(document.activeElement!, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(rows[0]);

    // Off the top of the list is the filter, not a trapped first row.
    fireEvent.keyDown(document.activeElement!, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(filter());
  });

  it('drops the filter when closed, so the next open starts from the whole list', () => {
    open();
    type('tokyo');
    fireEvent.click(screen.getByLabelText('Close'));
    fireEvent.click(trigger());

    expect(filter()).toHaveValue('');
    expect(options().length).toBeGreaterThan(2);
  });
});

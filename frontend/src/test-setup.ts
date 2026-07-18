// Vitest global setup (see vitest.config.ts `setupFiles`).
//
// - jest-dom matchers (toBeInTheDocument, toHaveTextContent, …) for the
//   component + integration suites.
// - @solidjs/testing-library auto-cleanup: each test's rendered tree is
//   disposed and removed from the document after it finishes, so parallel
//   isolated files never inherit a dirty DOM or leaked reactive root.
import '@testing-library/jest-dom/vitest';
import '@solidjs/testing-library';

// jsdom has no EventSource. Nav (mounted for the whole app lifetime, see
// components/Nav.tsx) opens one via useSSE for the live-status chip, so every
// component/integration test that renders the app shell needs this stubbed —
// not just SSE-specific tests. It never "connects" (no onopen/onerror fires),
// which is fine: tests assert on rendered markup, not live connection state.
if (typeof globalThis.EventSource === 'undefined') {
  class StubEventSource {
    onopen: (() => void) | null = null;
    onerror: (() => void) | null = null;

    constructor(_url: string) {}

    addEventListener(): void {}
    removeEventListener(): void {}
    close(): void {}
  }

  // @ts-expect-error test stub — not a full EventSource implementation.
  globalThis.EventSource = StubEventSource;
}

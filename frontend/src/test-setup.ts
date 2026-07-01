// Vitest global setup (see vitest.config.ts `setupFiles`).
//
// - jest-dom matchers (toBeInTheDocument, toHaveTextContent, …) for the
//   component + integration suites.
// - @solidjs/testing-library auto-cleanup: each test's rendered tree is
//   disposed and removed from the document after it finishes, so parallel
//   isolated files never inherit a dirty DOM or leaked reactive root.
import '@testing-library/jest-dom/vitest';
import '@solidjs/testing-library';

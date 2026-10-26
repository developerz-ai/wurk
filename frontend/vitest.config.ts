import { defineConfig } from 'vitest/config';
import solid from 'vite-plugin-solid';

// Dedicated test config — kept out of vite.config.ts so the build's
// manifest-generator plugin (apply: "build") never runs under the test runner.
//
// SolidJS compiles JSX at build time via vite-plugin-solid; the same plugin
// runs here so component tests exercise the real compiled reactive output.
// `conditions: ['development', 'browser']` pins Solid's dev build (dev warnings
// + client render) the way @solidjs/testing-library expects.
export default defineConfig({
  plugins: [solid()],
  resolve: {
    conditions: ['development', 'browser'],
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test-setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    coverage: {
      provider: 'v8',
      // An explicit include also counts unimported source files in Vitest 5.
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['src/**/*.{test,spec}.{ts,tsx}', 'src/test-setup.ts'],
      thresholds: {
        perFile: false,
        lines: 83,
        branches: 66,
      },
    },
    // Fast + parallel: files run concurrently across a worker-thread pool and
    // each file is isolated (fresh module registry + DOM) so component/route
    // tests never leak signals or the document between suites.
    pool: 'threads',
    isolate: true,
    // Above vitest's 5s default: TimezonePicker renders the full IANA zone list
    // (~400 rows) and asserts through `getAllByRole`, which computes an
    // accessible name per row. That lands around a second locally and has timed
    // out at 5s on a loaded shared runner — a real hang still fails, just later.
    testTimeout: 20_000,
    // Keep source-inspection imports and the shadow view's compiled local CSS
    // real; other stylesheet imports stay stubbed. An empty ?inline stub would
    // silently remove the baseline these isolation tests need to inspect.
    css: { include: [/\?raw/, /pages\/_extension\.scss\?inline/] },
  },
});

# 09 — Frontend fixes

> Part of [`overview.md`](overview.md). Depends on: none. All in `frontend/` (SolidJS + TS, vitest via `bun run test`).

## Files to change

- `frontend/src/pages/Extension.tsx:45-60` — fetch abort (FE6)
- `frontend/src/toast.tsx:21-27` — timer handles + cap (FE7)
- `frontend/src/components/Modal.tsx:25-32` — held-content retention (FE8)
- `frontend/src/hooks/useSSE.ts:27-28` — test-only reset (FE10)
- `frontend/src/App.tsx:126`, `frontend/src/hooks/useCountUp.ts:5-7` — reduced-motion reactivity (cosmetic, optional)

## Steps

1. **FE6 — Extension fetches have no AbortController.** `load()` writes into signals after dispose; in-flight bodies retained. Per `load`: create `AbortController`, pass `signal`, `onCleanup(() => controller.abort())`, swallow `AbortError`. Keep the existing `seq` guard (still needed for in-life reordering).
2. **FE7 — toast timers leak + uncapped list.** Store the `setTimeout` handle on the toast record; `clearTimeout` in `dismissToast`; cap visible toasts (slice oldest beyond 5). Under sustained mutation failures the current code accumulates DOM alerts + timers unboundedly.
3. **FE8 — Modal retains last-opened subtree until next open**, and re-creates children per parent update while open (tracks `props.children` in `createEffect`; `Busy.tsx:403-409` re-renders per 5 s poll). Fix: wrap children in Solid's `children()` helper (memoized), and clear `held` after exit transition (timeout matching `--dur-*` token).
4. **FE10 — `useSSE` module-level `source`/`refs` never reset between vitest tests**; one mid-test throw cascades failures. Export test-only `__resetSSE()`; call in `afterEach` of `useSSE.test.ts`. Do not change the production singleton/refcount logic — it's verified correct.
5. Optional (cosmetic, flagged by audit): `prefersReducedMotion` read non-reactively at `App.tsx:126` / `useCountUp.ts:5-7` — make reactive via `matchMedia` listener wrapped in a signal with `onCleanup` removal. Skip if time-boxed.

## Tests

- vitest: Extension unmount mid-fetch → no signal write after dispose (spy on setter), abort called.
- vitest: dismiss toast early → timer cleared (fake timers); 20 rapid toasts → list capped.
- vitest: modal close → held content cleared after transition window.
- vitest: `useSSE` suite passes with injected mid-test failure (reset works).
- Command: `bun run test` in `frontend/`; `bin/rake frontend:build` still succeeds (bundle ships in gem).

## Done when

- All new vitest cases green; no `EventSource`/observer/timer regressions in existing suite.
- Built bundle regenerated only if this ships in a release cut (release task rebuilds anyway).

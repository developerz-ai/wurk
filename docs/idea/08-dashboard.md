# Dashboard

A modern, faster, easier-to-use replacement for Sidekiq Web. Same data shape and panes — better UX, mobile-friendly, themed, internationalized.

## Look and feel

- **Left-rail navigation menu**, not a top navbar. More screen vertical space, better fit for dense tables, easier to scan.
- **Mobile-first responsive design.** On narrow viewports the nav collapses into an off-canvas drawer (slides in from the left); tables become card lists; charts shrink gracefully. The dashboard works on a phone, unlike Sidekiq Web.
- **Dark-only theme.** A single cohesive dark theme (no light toggle), with a data viz palette tuned for accessibility.
- **Visual language inspired by Sidekiq Web** so existing users feel oriented, but with a modern density and typography. Familiar but clearly newer.

## i18n

- All UI strings live in translation files.
- A handful of locales ship in the gem (en, es, fr, de, pt-BR, ja, zh-CN to start).
- Host apps can extend or override translations by dropping their own locale files into a known load path. Wurk merges host-app translations on top of the bundled ones.
- The active locale follows the host app's locale by default; users can override via a UI control.
- Date and number formatting use the active locale.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Frontend | React + TypeScript + Vite | Faster than Sidekiq's ERB+jQuery, modern DX |
| State | TanStack Query | Cache + revalidate, pairs well with SSE |
| Realtime | Server-Sent Events | One-way push, simpler than WebSocket |
| Charts | Recharts | Good defaults, small bundle, themeable |
| Styling | CSS variables + container queries | Themeable, mobile-friendly without a heavy CSS framework |
| i18n runtime | A small, dependency-free translator that reads the bundled JSON locale files | Avoid pulling i18next-size deps for what is mostly key lookup |
| Server | Rack app inside the engine | No Node runtime in production — see precompiled assets |

## Parity panes (must match Sidekiq Web data shape)

- Dashboard summary (processed, failed, queue depths)
- Busy (live workers, jobs in flight)
- Queues (list, depths, pause/resume)
- Retries
- Scheduled
- Dead
- Cron (Enterprise parity)
- Limiters (Enterprise parity)
- Batches (Pro parity)
- Search (Pro parity)

## AI panes (opt-in)

Powered by the Anthropic API. Haiku for cheap classification, Sonnet for analytical queries. Disabled until a token is configured.

| Pane | What it does |
|---|---|
| Anomaly detection | Surfaces when a queue's latency or failure rate departs sharply from baseline |
| Backlog forecast | Estimates when each queue will clear at current drain rate |
| Error triage | Clusters dead jobs by inferred root cause and suggests fixes |
| Natural-language query | "Show jobs that failed with Net::ReadTimeout in the last 24h" |
| Capacity advisor | Recommends worker / concurrency adjustments for a target latency |
| Retry pattern flags | Detects jobs that always retry N times before succeeding |

## Performance posture

- Precompiled bundle — no asset pipeline cost on consumers.
- Single SSE stream multiplexes live updates; no polling.
- Charts and tables render only the visible viewport (virtualized lists for retry/dead/scheduled sets).
- Dashboard route is fast enough to feel native — under 100ms first interactive on a warm cache.

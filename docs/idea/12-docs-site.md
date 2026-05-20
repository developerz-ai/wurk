# Docs Site (GitHub Pages)

Public-facing documentation served on GitHub Pages, with the option to CNAME to a custom domain later.

## Generator choice: VitePress

| Choice | Verdict |
|---|---|
| VitePress | Recommended. Markdown-first, fast, modern theme, good default search, easy code-tabs for Sidekiq-vs-Wurk comparisons. We already use Vite for the dashboard — same toolchain |
| Docusaurus | Heavier, React-app shape, overkill for a docs site |
| Jekyll | GH Pages' default but ages poorly, weaker theming |
| mkdocs-material | Python toolchain adds friction next to Ruby + Node |

## Layout

- `docs-site/` — separate from `/docs` (internal idea docs).
- VitePress config defines nav and sidebar.
- `index.md` — landing.
- `guide/` — getting started, Rails integration, standalone, configuration, migration from Sidekiq.
- `concepts/` — architecture, swarm, reliable fetch, signals, compatibility.
- `features/` — batches, rate limiting, periodic jobs, unique jobs, encryption, metrics, dashboard.
- `api/` — one page per public module, auto-generated from YARD comments in `lib/`.
- `deployment/` — Docker, Kubernetes, Heroku, Fly.

## Build and deploy

A docs workflow on GitHub Actions runs when `docs-site/**` changes. It builds the VitePress site on a Blacksmith runner, uploads the static output as a Pages artifact, and deploys via the official pages deploy action.

The workflow is a separate file from the main test workflow so docs deploys don't depend on the full matrix turning green.

## API ref generation

YARD reads doc comments in the gem's lib tree and emits JSON. A small Rake task converts the YARD JSON into markdown pages under `docs-site/api/`. The conversion runs as part of the docs build, so API docs are always in sync with the released gem.

## Landing page must include

- A code-diff side-by-side showing the one-line change to migrate from Sidekiq.
- A benchmarks table populated from the latest CI artifact.
- A "Pro + Enterprise features included" checklist.
- A direct link to the migration guide as the first call-to-action.

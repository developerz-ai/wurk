# Brief: is a release due?

Weekday checkup, fired by `schedules: release-due` in `.dz/maintainer/maintainer.yml`. Wurk releases
like a maintained gem: when merged work that ships has waited for a release, it gets one. Releasing
is `RELEASE.md`; this brief only decides *when*.

## Decide

```bash
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
git log --format='%h %cI %s' "$last"..origin/main -- 'lib/**/*.rb' 'lib/**/*.lua' 'app/**/*.rb' 'config/**' 'exe/*' 'frontend/src/**' wurk.gemspec
```

Those paths are `wurk.gemspec`'s `spec.files` (the dashboard bundle is built from `frontend/src`).
Tests, docs, CI, the demo and benchmarks ship nothing.

| Window | Do |
|---|---|
| empty | nothing |
| `Wurk::VERSION` already ahead of `$last` | nothing — a release is in flight (`release.yml`) |
| the oldest shipping commit is under 24 h old | nothing — an org member may still release their own work |
| a **Breaking** change under `## [Unreleased]` | nothing, unless no open issue says a major is pending: then one, for a maintainer |
| otherwise | one ask, **Release `<next>`**, listing the commits |

`<next>`: `### Added` under `[Unreleased]`, or a `feat` subject → minor; anything else → patch.

## The ask, when due

1. Re-check the window on fresh `main`; still due, or stop.
2. `## [Unreleased]` empty (a Dependabot-only window)? Add a `### Changed` line per bumped runtime
   dependency first.
3. `RELEASE.md` → *Cutting a release*: bump `lib/wurk/version.rb`, `bundle exec rake
   release:relock_demo`, move `[Unreleased]` under `## [<next>] - <today>`, `bin/check`.
4. One PR, `release: <next>`, nothing else in it. It merges on green like any PR.
5. Merging it is the release: `release.yml` publishes the gem, then tags. Never tag, never
   `gem push` by hand.

Never file a second ask while one titled `Release …` is open.

# Brief: is a release due?

Weekday checkup, fired by `schedules: release-due` in `.dz/maintainer/maintainer.yml`. Wurk releases
like a maintained gem: when merged work that ships has waited for a release, it gets one. Releasing
is `RELEASE.md`; this brief only decides *when*.

## Decide

```bash
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
git log --format='%h %cI %s' "$last"..origin/main -- 'lib/**/*.rb' 'lib/**/*.lua' 'app/**/*.rb' 'config/**' 'exe/*' 'frontend/src/**' wurk.gemspec
```

Those paths are `wurk.gemspec`'s `spec.files`, with two deliberate differences. The dashboard bundle
(`vendor/assets/dashboard/**`) is built at release and git-ignored, so its source, `frontend/src`, is
what a commit changes. `README.md` and `LICENSE` ship but are excluded on purpose: prose alone never
owes a release. Tests, CI, the demo and the benchmarks ship nothing.

| Window | Do |
|---|---|
| empty | nothing |
| `Wurk::VERSION` already ahead of `$last` | nothing — a release is in flight (`release.yml`) |
| the oldest shipping commit is under 24 h old | nothing — an org member may still release their own work |
| a **Breaking** change under `## [Unreleased]` | no release ask, ever: a major is a maintainer's. If no open issue says a major is pending, file one, for a maintainer, with no release steps |
| otherwise | one ask, **Release `<next>`**, listing the commits |

`<next>` (only ever reached without a breaking change): `### Added` under `[Unreleased]`, or a `feat`
subject → minor; anything else → patch.

## The ask, when due

1. **Pre-flight guard (gh-capable lane only).** The lane running this brief MUST be a `gh`-capable execution surface — the only surface eligible to file a `Release <next>` ask. Verify capability with `gh auth status`: no `gh` binary, or a non-zero exit, means the lane is not gh-capable, and a lane without `gh` MUST skip this ask entirely. Once eligible, run `gh issue list --state open` and `gh pr list --state open`; if any title matches `^Release|^release:`, MUST skip the Release ask (standing prohibition below — never file a second ask while one titled `Release …` is open).
2. Re-check the window on fresh `main`; still due, or stop.
3. `## [Unreleased]` empty (a Dependabot-only window)? Add a `### Changed` line per bumped runtime
   dependency first.
4. `RELEASE.md` → *Cutting a release*: bump `lib/wurk/version.rb`, `bundle exec rake
   release:relock_demo`, move `[Unreleased]` under `## [<next>] - <today>`, `bin/check`.
5. One PR, `release: <next>`, nothing else in it. It merges on green like any PR.
6. Merging it is the release: `release.yml` publishes the gem, then tags. Never tag, never
   `gem push` by hand.

Never file a second ask while one titled `Release …` is open.

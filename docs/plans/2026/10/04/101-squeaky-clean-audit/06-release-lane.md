# 06 — Release lane (closes #491, #482)

> Part of [`overview.md`](overview.md). Depends on: [`05`](05-ci-gates.md) C7. Both issues edit `RELEASE.md` — one PR or sequential.

## #491 — `rake release` / `release:full` bypass the CI-only lane

- Root cause: `Rakefile:3` loads `bundler/gem_tasks` (Bundler `release` = tag + push); `Rakefile:245-246` `release:full` depends on undefined `push` → can't run. `CLAUDE.md:33` advertises `bin/rake release`; `RELEASE.md:180-185` documents `release:full`.
- Steps:
  1. After `Rakefile:3`: `Rake::Task[...].clear` then redefine `release`, `release:source_control_push`, `release:rubygem_push` as `abort` w/ message → RELEASE.md (release = merge a `lib/wurk/version.rb` bump).
  2. Delete `Rakefile:245-246`.
  3. `bin/gem-push`: run `bundle exec rake release:check` before `gem push` (`tag_matches_version!` no-ops w/o tag, `tasks/release_helpers.rb:44-45`).
  4. Rewrite `CLAUDE.md:33` Release row ("merge version bump → release.yml"); `RELEASE.md:180-185`.
- Tests: new `test/unit/rakefile_release_test.rb` — subprocess `rake release`, `rake release:rubygem_push`, `rake release:source_control_push` exit non-zero with the RELEASE.md message; `release:full` not defined. `claude_md_claims_test` stays green.

## #482 — commit `demo/Gemfile.lock`

- Root cause: `demo/.gitignore:6` ignores lock; `demo/Gemfile:5-7` unpinned; `Dockerfile:43` plain `bundle install`.
- Not actually HITL: this box has Ruby (mise 3.4.7) + network.
- Steps:
  1. Drop the line from `demo/.gitignore`.
  2. `cd demo && bundle lock --add-platform x86_64-linux --add-platform aarch64-linux` (match image Bundler version).
  3. `Dockerfile:43` → `bundle install --frozen` (or `BUNDLE_FROZEN=1`).
  4. One line in `demo/README.md` + RELEASE.md step 1 ("re-lock demo on version bump").
  5. **Guard** (issue misses this): lock pins `wurk (path: ..)` at `Wurk::VERSION`; a bump without re-lock breaks the frozen build inside `release.yml` → `deploy-demo` *after* gem publish. Add assertion in `release:check` (`tasks/release_helpers.rb`) + unit test: `demo/Gemfile.lock` wurk version == `Wurk::VERSION`. Better: have the version-bump tooling re-lock automatically.
- Tests: `docker build .`; `bundle exec rake release:check`; guard unit test (fails when versions differ).

## Done when
- `bin/rake release` aborts with pointer to RELEASE.md; `release:full` gone.
- Demo image builds with `--frozen`; guard test exists and runs in `bin/check`.
- #491, #482 closed.

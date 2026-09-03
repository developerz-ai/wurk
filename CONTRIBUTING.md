# Contributing to Wurk

Thanks for helping make Wurk better. This guide covers local setup, the test
layers, and the conventions a change has to follow to merge.

## Setup

```sh
git clone https://github.com/developerz-ai/wurk
cd wurk
bin/setup          # gem + frontend (bun) deps + dummy app db:prepare
```

You'll need a local **Redis ≥ 7.0** running (tests use real Redis, never a mock)
and [**bun**](https://bun.sh). Bun is not only for frontend work: the engine
tests render the dashboard shell, so the SolidJS SPA under `frontend/` has to be
built before they can run. `vendor/assets/dashboard/` is gitignored rather than
committed, so a fresh clone has no bundle — `bin/setup` installs the frontend
deps, and the first `bin/rake test` builds the bundle itself.

Consumers of the published gem run neither Node nor bun: the bundle is baked
into `vendor/assets/` at release time and ships inside the gem.

`bin/setup` installs the dummy app's gems into a **project-local** path
(`test/dummy/vendor/bundle`) so a read-only or permission-locked global gem home
never blocks setup with `Bundler::PermissionError`.

## Dashboard development (live reload)

```sh
bin/dev            # Redis + Vite (SolidJS HMR) + the dummy Rails host
```

Open <http://localhost:3000/wurk>. `bin/dev` reuses a Redis already on `:6379`
or starts a throwaway Docker one, runs the Vite dev server, and boots
`test/dummy` with `WURK_VITE_DEV=1` so the dashboard shell pulls modules and the
HMR client straight from Vite. Edit anything under `frontend/src` and the browser
updates instantly — no rebuild, no gem repackage.

- `NO_VITE=1 bin/dev` serves the prebuilt bundle instead (run
  `bin/rake frontend:build` first) — useful to sanity-check the shipped artifact.
- `PORT` / `VITE_PORT` override the defaults (3000 / 5173).

Frontend unit + integration tests (Vitest, SolidJS Testing Library) run with
`bun run test` in `frontend/`.

## Running the tests

**`bin/check` is the one to remember.** It runs the same gates CI does, in the
order that fails fastest, and prints a per-stage wall clock:

```sh
bin/check fast     # rubocop + unit tests           — the inner loop
bin/check          # rubocop + full suite + parity  — run this before opening a PR
bin/check full     # ...plus the ecosystem suites
```

It refuses to start without a local Redis and tells you how to get one. A green
`bin/check` is the answer CI will give you.

### Exit codes

`bin/check` exits with one of four codes — CI treats anything but `0` as a
failed run.

With no argument, mode defaults to `pr` (the same path `bin/check pr` takes) —
the case dispatch at `bin/check:20-31` matches `''` to `pr` rather than
treating it as unknown:

| Exit | Trigger | Source |
|---|---|---|
| `0` | Every stage passed, OR `-h` / `--help` / `help` printed the help block without running any stage. | `bin/check:94-97`, `bin/check:23-26` |
| `1` | At least one stage reported failure. | `bin/check:99-100` |
| `64` | Unrecognised mode argument — anything other than `''`, `pr`, `fast`, `full`, `-h`, `--help`, or `help`. | `bin/check:27-30` |
| `75` | No bundler on `PATH` — the environment cannot run the Ruby gate at all. | `bin/check:62-66` |
| `75` | No Redis on `127.0.0.1:6379`. | `bin/check:74-78` |

`75` is the platform's "preconditions unmet" code, and both triggers share it on
purpose: neither says anything about the diff. A gate that cannot reach its Redis,
or cannot find the bundler it runs every stage through, has established NOTHING —
so it must not exit `1`, which means "the gate ran and judged the change". An
automated maintainer reads `1` as a red diff and sends its agent hunting a bug
nobody wrote.

### Env knobs

- `SKIP_LINT=1` — drop the rubocop stage (`bin/check:80`).
- `SKIP_PARITY=1` — drop the parity oracles stage (`bin/check:87`).
- `NCPU=<n>` — see [Worker count](#worker-count) below for the trade-off (ceiling 14).

The individual tasks, when you want one:

| Task | Command |
|---|---|
| Full suite (parallel) | `bin/rake test` |
| A single file | `bin/rake test TEST=test/path/to/file_test.rb` |
| A single test by name | `bin/rake test TEST=test/foo_test.rb TESTOPTS="--name=/pattern/"` |
| Parity suite (oracles lifted from Sidekiq) | `bin/rake test:parity` |
| Ecosystem compatibility | `bin/rake test:ecosystem` |
| Coverage gate | `COVERAGE=1 bin/rake test` |
| Benchmarks | `bin/rake bench` |
| Lint | `bundle exec rubocop --parallel` |

### Worker count

The suite forks 4 parallel workers, each on its own Redis logical DB. That is
deliberately below most machines' core count: the integration layer boots real
swarms (4 children × 5 threads apiece), so one worker per core oversubscribes and
starts failing on wall clock rather than on assertions. `NCPU=<n>` raises it if
your machine has headroom (ceiling 14, the number of isolated DBs); `NCPU=1` is
how to chase an ordering flake.

The engine tests render the dashboard shell, which needs the precompiled SPA.
That bundle is built rather than committed, so a fresh clone has none — the
first `bin/rake test` builds it once (roughly 4s) and says so. Later runs skip
it. If you change anything under `frontend/src`, rebuild explicitly with
`bin/rake frontend:build`; the automatic build only covers "no bundle at all".

## Profiling a slow path

```sh
bin/profile                 # fetch+execute, CPU samples, real Redis
bin/profile enqueue         # the client push path
bin/profile fetch --alloc   # allocation counts — what feeds the GC
bin/profile fetch --dump    # keep tmp/profile.dump for `stackprof --method ...`
```

`bin/rake bench` tells you *that* something regressed; this tells you *where*.
Both drive the real fetcher, processor, and round trips — a stubbed hot path
only profiles the stub.

Test layers:

- **unit** — plain Ruby classes in isolation.
- **engine** — boots the dummy Rails app in `test/dummy/`.
- **integration** — real forks + real Redis.
- **parity** (`test/parity/`) — tests lifted from upstream Sidekiq, SHA-pinned.
  These are **oracles**: if Wurk diverges, Wurk is wrong unless the divergence
  is explicitly documented as intentional.
- **ecosystem** — third-party Sidekiq gem suites run against Wurk.

Never mock Redis in integration or parity tests. Each test uses a unique Redis
key namespace so the parallel runner stays safe.

## Conventions

These are non-negotiable — they're what keep Wurk a true drop-in:

- **Wire-compat is sacred.** Never change a Redis key, JSON field, or
  sorted-set score format. If an optimization would break compatibility, drop
  the optimization.
- **SOLID, especially SRP.** One reason to change per class — Manager owns
  lifecycle, Fetcher owns the Redis pop, Processor owns middleware + perform,
  Client owns enqueue.
- **Match the spec.** Any public Sidekiq surface must match
  `docs/target/sidekiq-{free,pro,ent}.md` exactly.
- **Frozen string literals everywhere**; per-fork Redis pools (never share a
  socket across a fork).
- **Comments explain non-obvious _why_**, never restate the code.
- **Coverage**: SimpleCov **line** and **branch** coverage on `lib/` must both
  stay ≥ 90% (both are blocking; `minimum_coverage line: 90, branch: 90` in
  `test/test_helper.rb`). Branch was ratcheted from ~78% to ≥90% in #67 —
  keep new code at parity.

## Pull requests

1. Commit with an email linked to your GitHub account
   (`git config user.email` matches the address on
   <https://github.com/settings/emails>). The repo's `main-protection` ruleset
   sets `require_extra_approval_for_unattributed_changes: true`, so any commit
   in your PR not attributed to a GitHub account adds a human approval
   requirement on top of the zero the ruleset otherwise asks for — this repo
   otherwise never asks for one, so the PR will silently park instead of
   auto-merging. See `.maintainer.yml` for the ruleset citation.
2. Branch off `main`.
3. Keep the change focused; add tests at the right layer.
4. Run `bin/check` (or `bin/check full` if you touched the compat surface).
5. Open the PR — CI runs one Ruby suite on the newest Ruby + Rails with the
   coverage gate folded in, plus the parity oracles, rubocop, the frontend
   suite, and benchmarks. The bench bot comments per-benchmark deltas; a real
   regression fails the check.
6. Don't `--no-verify` past a failing hook — fix the hook.

By contributing you agree your work is licensed under the project's
[MIT License](LICENSE).

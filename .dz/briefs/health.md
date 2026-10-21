# Brief: is the project healthy?

Daily checkup, fired by `schedules: health` in `.dz/maintainer/maintainer.yml`. Wurk is maintained
so that nobody has to watch it. This brief covers the failures no issue or PR announces.

| Signal | Command | Healthy |
|---|---|---|
| `main` is green | `run=$(gh run list --workflow test.yml --branch main --event push --limit 1 --json databaseId,headSha,conclusion \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); v=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$(jq -r .databaseId <<<"$run")/jobs" \| jq -r '[.jobs[]?] as $all \| [$all[] \| select(.name != "detect changed paths")] as $g \| [$all[] \| select(.name == "detect changed paths")] as $d \| if ($all \| length) == 0 then "unreadable" elif ($d \| length) == 1 and ($d[0].conclusion == "success") and ($g \| length) > 0 and all($g[]; .conclusion == "skipped") then "dup" else "graded" end' 2>/dev/null); case "$v" in dup) echo "Unhealthy: $sha is a dup'd push run" ;; graded) echo "$(jq -r .conclusion <<<"$run") $sha" ;; *) echo "verdict unknown $sha" ;; esac` | `success`, and `detect.dup=false` |
| the last release published | `run=$(gh run list --workflow release.yml --limit 1 --json databaseId,headSha,conclusion \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); c=$(jq -r .conclusion <<<"$run"); v=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$(jq -r .databaseId <<<"$run")/jobs" \| jq -r '[.jobs[]?] as $all \| [$all[] \| select(.name == "preflight")] as $p \| [$all[] \| select(.name == "release")] as $r \| if ($all \| length) == 0 then "unreadable" elif ($p \| length) == 1 and ($p[0].conclusion == "success") and ($r \| length) == 1 and ($r[0].conclusion == "skipped") then "noop" else "graded" end' 2>/dev/null); if [ "$c" = "null" ]; then echo "in flight $sha"; else case "$v" in noop) echo "no-op $sha, preflight passed with proceed=false: nothing was owed, that version is already on RubyGems" ;; graded) echo "$c $sha" ;; *) echo "verdict unknown $sha" ;; esac; fi` | `success`, or a named `no-op <sha>` (proceed=false, nothing owed) |
| RubyGems serves `Wurk::VERSION` | `gem list wurk --remote --exact` vs `lib/wurk/version.rb` | equal, or a release run is in flight |
| the demo deployed | `gh run list --workflow deploy-demo.yml --limit 1 --json conclusion` | `success` |
| topology and ecosystem lanes | `for wf in topology.yml ecosystem.yml; do run=$(gh run list --workflow $wf --branch main --event push --limit 1 --json databaseId,headSha,conclusion \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); v=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$(jq -r .databaseId <<<"$run")/jobs" \| jq -r '[.jobs[]?] as $all \| [$all[] \| select(.name != "detect changed paths" and .name != "sidekiq release watcher")] as $g \| [$all[] \| select(.name == "detect changed paths")] as $d \| if ($all \| length) == 0 then "unreadable" elif ($d \| length) == 1 and ($d[0].conclusion == "success") and ($g \| length) > 0 and all($g[]; .conclusion == "skipped") then "dup" else "graded" end' 2>/dev/null); case "$v" in dup) echo "Unhealthy: $wf at $sha is a dup'd push run" ;; graded) echo "$wf $(jq -r .conclusion <<<"$run") $sha" ;; *) echo "$wf verdict unknown $sha" ;; esac; done` | `success` on both, and `detect.dup=false` on both |
| Dependabot is not stuck | `gh pr list --app dependabot --json number,createdAt` | none older than 7 days |

**Grading a dup'd push.** `bin/ci-dup-push` lets a push to main skip a workflow's gated jobs when the
pushed tree already passed that workflow on the merged PR's head — `detect.dup=true`. Such a run
still reports `conclusion=success` with nothing having run, so rows 8 and 12 read
`databaseId,headSha,conclusion` *and* the job list from
`gh api repos/$repo/actions/runs/<databaseId>/jobs`, and grade it in three steps.

1. **An unreadable job list grades `verdict unknown <sha>`**, never a colour. The `gh api` call is
   the only thing standing between a rate limit or 4xx and a verdict the row cannot actually
   establish, so an empty or unparseable list short-circuits *before* anything is concluded from
   `conclusion`. A run whose verdict is unknown is not a green run and not a red one; the next
   checkup re-runs it.
2. **`detect changed paths` must conclude `success`** before all-skipped reads as a dup. A failed or
   cancelled `detect` publishes no outputs, `needs:` then skips every dependent, and the job list
   comes back all-skipped with no dup anywhere in it — the same signature, a different cause. The
   jobs API carries no step *outputs*, so `dup=true` is read from its runtime signature: the
   `detect changed paths` job succeeded and every other job in the run came back `skipped`. On a
   push event, with a successful `detect`, that is one-to-one — the same
   `RUN: needs.detect.outputs.dup != 'true'` expressions run every gated job when `dup` is false, so
   all-skipped then means dup and nothing else (`sidekiq release watcher` is excluded; it is a
   `schedule`/`workflow_dispatch` job, never gated on dup). A `detect` that failed is not a dup: the
   run grades on its own `conclusion`, which is what actually explains why nothing ran.
3. **Otherwise grade on `conclusion`**, printing `<conclusion> <sha>`.

A dup'd push grades **Unhealthy whatever its `conclusion`**, and the ask must name the dup'd
`headSha`: that coverage came from the PR run, so main has no fresh signal of its own. Row 12 runs
the same three-step read over both workflows and names the offending one. Keep rows 8 and 12 on one
read shape — dropping the jobs call reopens a `main` that certifies green having run no tests at all,
and dropping the `detect` check misreads a failed run as a dup'd one.

**Grading a release run that published nothing.** Row 9 reads `databaseId,headSha,conclusion` *and*
the job list from `gh api repos/$repo/actions/runs/<databaseId>/jobs`, and grades in three steps, for
the reason the dup rows do: the jobs API carries no step *outputs*, so what release.yml decided
cannot be read directly, and its cheapest exit is a run that publishes nothing and still reports
`conclusion=success`.

1. **A null `conclusion` is in flight** — report `in flight <sha>` and grade nothing. A run still
   executing has `conclusion=null`, and its job list is a partial picture (`release` not started,
   `demo` not queued) that no verdict may be built on.
2. **An unreadable job list grades `verdict unknown <sha>`**, never a colour — the same fail-closed
   rule rows 8 and 12 use.
3. **`preflight` concluded `success` with `release` skipped is a no-op.** release.yml:80-90 is the
   whole proceed signal in one contiguous range: preflight curls RubyGems for `Wurk::VERSION` and
   emits `proceed=false` when it is already there, and the `release` job is gated on
   `needs.preflight.outputs.proceed == 'true'`. `demo` needs `[preflight, release]`
   (release.yml:222-228). So a proceed=false run is `preflight` `success`, `release` skipped, `demo`
   skipped — and the run still concludes `success`, because a skipped job does not fail a run. Print
   `no-op <sha>`. Grading this row on `--json conclusion` alone reports that green as the last
   release published, which it is not.
4. **Otherwise grade on `conclusion`**, printing `<conclusion> <sha>`.

A no-op is **not Unhealthy and files no ask**: proceed=false means that version is already live on
RubyGems, so nothing was owed. Take `<v>` for an ask title from `lib/wurk/version.rb`, not from the
shell; row 10 owns the RubyGems cross-check. A run that genuinely went red stays Unhealthy and grades
on its own `conclusion` — `release` failed, or `preflight` failed the non-main refusal
(release.yml:55-60). That second case skips every dependent through `needs:` and comes back with the
same all-skipped list a no-op produces, which is why step 3 requires `preflight` itself to have
concluded `success`.

For each unhealthy signal, file one ask unless an open issue already names it. The title names the
signal (`main is red at <sha>`, `main is green only via a dup'd push at <sha>`,
`release <v> did not publish`), and the body carries the command, its output and the run URL. A red
`main` comes first: nothing releases from it. Recovery is `RELEASE.md`'s *If a release
fails*. For a gem-less release, follow that runbook's *Recovering a gem-less release*:
`gh release delete vX.Y.Z --cleanup-tag --yes`, then `git fetch --prune-tags`,
then let CI re-cut the tag from the version bump. That cleanup is the sanctioned
path here, not a workaround — never manually re-tag over an existing `vX.Y.Z`
(force-moving a tag to a different commit), never `gem push` from a workstation as a
replacement for the CI publish lane, and never force a version already on
RubyGems down the publish lane a second time; the only version number that may
be published for a given `<v>` is the one CI published. Break-glass hand-cutting
a release when CI is unavailable, as RELEASE.md's *Break-glass manual publish*
prescribes, is not re-tagging or force-moving — it runs only because the gem has
already shipped and the lane can no longer act.

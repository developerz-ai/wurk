# Brief: is the project healthy?

Daily checkup, fired by `schedules: health` in `.dz/maintainer/maintainer.yml`. Wurk is maintained
so that nobody has to watch it. This brief covers the failures no issue or PR announces.

| Signal | Command | Healthy |
|---|---|---|
| `main` is green | `run=$(gh run list --workflow test.yml --branch main --event push --limit 1 --json databaseId,headSha,conclusion \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); v=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$(jq -r .databaseId <<<"$run")/jobs" \| jq -r '[.jobs[]?] as $all \| [$all[] \| select(.name != "detect changed paths")] as $g \| [$all[] \| select(.name == "detect changed paths")] as $d \| if ($all \| length) == 0 then "unreadable" elif ($d \| length) == 1 and ($d[0].conclusion == "success") and ($g \| length) > 0 and all($g[]; .conclusion == "skipped") then "dup" else "graded" end' 2>/dev/null); case "$v" in dup) echo "Unhealthy: $sha is a dup'd push run" ;; graded) echo "$(jq -r .conclusion <<<"$run") $sha" ;; *) echo "verdict unknown $sha" ;; esac` | `success`, and `detect.dup=false` |
| the last release published | `gh run list --workflow release.yml --limit 1 --json conclusion,displayTitle` | `success` |
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

For each unhealthy signal, file one ask unless an open issue already names it. The title names the
signal (`main is red at <sha>`, `main is green only via a dup'd push at <sha>`,
`release <v> did not publish`), and the body carries the command, its output and the run URL. A red
`main` comes first: nothing releases from it. Recovery is
`RELEASE.md`'s *If a release fails*. Never delete a tag, re-run a publish or `gem push` from here.

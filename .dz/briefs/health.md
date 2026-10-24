# Brief: is the project healthy?

Daily checkup, fired by `schedules: health` in `.dz/maintainer/maintainer.yml`. Wurk is maintained
so that nobody has to watch it. This brief covers the failures no issue or PR announces.

| Signal | Command | Healthy |
|---|---|---|
| `main` is green | `run=$(gh run list --workflow test.yml --branch main --event push --limit 1 --json databaseId,headSha,conclusion,url 2>/dev/null); rc=$?; if [ "$rc" -ne 0 ] \|\| [ -z "$run" ] \|\| ! printf '%s' "$run" \| jq -e 'type == "array"' >/dev/null 2>&1; then echo "verdict unknown test.yml: the run list is not readable (gh run list failed or returned a non-array)"; elif [ "$(printf '%s' "$run" \| jq -r 'length')" = "0" ]; then echo "no run: test.yml has no matching run"; else run=$(printf '%s' "$run" \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); url=$(jq -r .url <<<"$run"); c=$(jq -r .conclusion <<<"$run"); dbid=$(jq -r .databaseId <<<"$run"); v=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$dbid/jobs" \| jq -r 'def gate_steps: [(.steps // [])[] \| select(.name != "Set up job" and .name != "Complete job")]; [.jobs[]?] as $all \| [$all[] \| select(.name != "detect changed paths")] as $g \| [$all[] \| select(.name == "detect changed paths")] as $d \| ($g \| map(gate_steps)) as $gs \| if ($all \| length) == 0 then "evidence unavailable (the jobs list could not be read)" elif ($g \| length) == 0 then "evidence unavailable (the jobs list carries no gated job)" elif ($d \| length) == 1 and ($d[0].conclusion == "success") and all($g[]; .conclusion == "success") and all($gs[]; length > 0) and all($gs[]; all(.[]; .conclusion == "skipped")) then "duplicate-skipped" elif any($gs[]; any(.[]; .conclusion != "skipped")) then "executed" else "evidence unavailable (no gated job ran and the reuse could not be confirmed)" end' 2>/dev/null); [ -n "$v" ] \|\| v="evidence unavailable (the jobs list could not be read)"; if [ "$c" = "success" ]; then case "$v" in executed) echo "executed: $c $sha $url" ;; duplicate-skipped) echo "duplicate-skipped: the gated steps were skipped; the tree already passed that workflow $sha $url" ;; *) echo "$v, so this run's gates are unverified $sha $url" ;; esac; else echo "$c $sha $url"; fi; fi` | `executed` (the gated steps ran); `duplicate-skipped` and `evidence unavailable` file no ask |
| the last release published | `vsha=$(gh api "repos/developerz-ai/wurk/commits?path=lib/wurk/version.rb&sha=main&per_page=1" 2>/dev/null \| jq -r 'if type == "array" and length > 0 then .[0].sha else "" end' 2>/dev/null); if [ -z "$vsha" ]; then echo "verdict unknown: the main commit carrying Wurk::VERSION is unreadable, so no release run can be bound to it and no version read from it"; else v=$(gh api -H "Accept: application/vnd.github.raw" "repos/developerz-ai/wurk/contents/lib/wurk/version.rb?ref=$vsha" 2>/dev/null \| grep -oE "[\"'][0-9][^\"']*[\"']" \| head -1 \| tr -d "\"'"); if [ -z "$v" ]; then echo "verdict unknown: lib/wurk/version.rb at $vsha is unreadable or carries no version, so the release run cannot be bound to a version"; else run=$(gh run list --workflow release.yml --commit "$vsha" --limit 1 --json databaseId,headSha,conclusion,url 2>/dev/null); sha=$(jq -r 'if type == "array" and length > 0 then .[0].headSha else "" end' <<<"$run" 2>/dev/null); url=$(jq -r 'if type == "array" and length > 0 then .[0].url else "" end' <<<"$run" 2>/dev/null); c=$(jq -r 'if type == "array" and length > 0 then (.[0].conclusion \| if . == null then "null" else . end) else "" end' <<<"$run" 2>/dev/null); if [ -z "$sha" ]; then echo "verdict unknown: no release.yml run for $vsha could be read"; elif [ "$sha" != "$vsha" ]; then echo "verdict unknown: the release.yml run reports headSha $sha, not the version's own sha $vsha, so it cannot be graded as this version's release"; elif [ "$c" = "null" ]; then echo "in flight $sha $url"; else dbid=$(jq -r 'if type == "array" and length > 0 then .[0].databaseId else "" end' <<<"$run" 2>/dev/null); jv=$(gh api "repos/developerz-ai/wurk/actions/runs/$dbid/jobs" 2>/dev/null \| jq -r '[.jobs[]?] as $all \| [$all[] \| select(.name == "preflight")] as $p \| [$all[] \| select(.name == "release")] as $r \| if ($all \| length) == 0 then "unreadable" elif ($p \| length) == 1 and ($p[0].conclusion == "success") and ($r \| length) == 1 and ($r[0].conclusion == "skipped") then "noop" else "graded" end' 2>/dev/null); if [ -z "$jv" ] \|\| [ "$jv" = "unreadable" ]; then echo "verdict unknown $sha $url"; elif [ "$jv" = "noop" ]; then echo "no-op $sha, preflight passed with proceed=false: nothing was owed, that version is already on RubyGems ($url)"; elif [ "$c" = "success" ]; then code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "https://rubygems.org/api/v2/rubygems/wurk/versions/$v.json" 2>/dev/null); rc=$?; if [ "$rc" -ne 0 ] \|\| [ "$code" = 000 ]; then echo "verdict unknown $sha $url: the RubyGems probe failed (curl rc=$rc, HTTP $code), so a green run cannot be called a publication"; elif [ "$code" = 200 ]; then echo "success $sha $url"; elif [ "$code" != 404 ]; then echo "verdict unknown $sha $url: HTTP $code is neither 200 nor 404, so the probe returned no readable verdict"; else echo "Unhealthy: green but empty publication: RubyGems serves no $v (HTTP 404) although the release run for $sha concluded success ($url), so the gem was never published"; fi; else echo "$c $sha $url"; fi; fi; fi; fi` | `success <sha> <url>` — the run published `Wurk::VERSION` and the gem is live on RubyGems — or a named `no-op <sha>` (proceed=false, nothing owed) |
| RubyGems serves `Wurk::VERSION` | `vsha=$(gh api "repos/developerz-ai/wurk/commits?path=lib/wurk/version.rb&sha=main&per_page=1" 2>/dev/null \| jq -r 'if type == "array" and length > 0 then .[0].sha else "" end' 2>/dev/null); if [ -z "$vsha" ]; then echo "verdict unknown: the main commit carrying Wurk::VERSION is unreadable, so there is no version of record to probe"; else v=$(gh api -H "Accept: application/vnd.github.raw" "repos/developerz-ai/wurk/contents/lib/wurk/version.rb?ref=$vsha" 2>/dev/null \| grep -oE "[\"'][0-9][^\"']*[\"']" \| head -1 \| tr -d "\"'"); if [ -z "$v" ]; then echo "verdict unknown: lib/wurk/version.rb at $vsha is unreadable or carries no version, so there is no version of record to probe"; else code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "https://rubygems.org/api/v2/rubygems/wurk/versions/$v.json"); rc=$?; if [ "$rc" -ne 0 ] \|\| [ "$code" = 000 ]; then echo "verdict unknown: the probe failed (curl rc=$rc, HTTP $code), and no HTTP status is not evidence that $v is absent"; elif [ "$code" = 200 ]; then echo "success: RubyGems serves $v"; elif [ "$code" != 404 ]; then echo "verdict unknown: HTTP $code is neither 200 nor 404, so the probe returned no readable verdict"; else run=$(gh run list --workflow release.yml --commit "$vsha" --limit 1 --json conclusion,headSha,url 2>/dev/null); rsha=$(jq -r 'if type == "array" and length > 0 then .[0].headSha else "" end' <<<"$run" 2>/dev/null); rcon=$(jq -r 'if type == "array" and length > 0 then (.[0].conclusion \| if . == null then "null" else . end) else "" end' <<<"$run" 2>/dev/null); rurl=$(jq -r 'if type == "array" and length > 0 then .[0].url else "" end' <<<"$run" 2>/dev/null); if [ -z "$rsha" ]; then echo "verdict unknown: RubyGems serves no $v (HTTP 404), but release.yml's run for the version's own sha is unreadable, so an in-flight release cannot be told from a missing one"; elif [ "$rsha" != "$vsha" ]; then echo "verdict unknown: RubyGems serves no $v (HTTP 404), but the release.yml run reports headSha $rsha, not the version's own sha $vsha"; elif [ "$rcon" = "null" ]; then echo "in flight: RubyGems serves no $v yet, but release.yml's run for $vsha has not concluded ($rsha, $rurl)"; else echo "Unhealthy: RubyGems serves no $v (HTTP 404) and release.yml's run for $vsha has concluded ($rcon, $rurl), so nothing is propagating and the release did not publish $v"; fi; fi; fi; fi` — the canonical availability probe RELEASE.md's *Verifying a release actually shipped* defines, reading `<version>` from `lib/wurk/version.rb` at the version-carrying commit | HTTP 200, or a release run is in flight |
| the GitHub Release carries the gem | `rel=$(gh release view --json author,assets 2>/dev/null); rc=$?; author=$(jq -r '.author.login // ""' <<<"$rel" 2>/dev/null); nassets=$(jq -r 'if (.assets \| type) == "array" then (.assets \| length) else "" end' <<<"$rel" 2>/dev/null); if [ "$rc" -ne 0 ] \|\| [ -z "$author" ] \|\| [ -z "$nassets" ]; then echo "verdict unknown: the Latest GitHub Release could not be read (gh release view rc=$rc), so a gem-less Latest Release cannot be told from a real one"; elif [ "$author" = "developerz-ai[bot]" ] \|\| [ "$nassets" = "0" ]; then echo "Unhealthy: gem-less Latest Release: the Latest GitHub Release was cut by $author with $nassets assets, so the Latest badge lies about the published version"; else echo "success: the Latest GitHub Release carries the gem ($nassets assets, author $author)"; fi` | the Latest GitHub Release carries the `.gem` and its author is not `developerz-ai[bot]` |
| the demo deployed | `run=$(gh run list --workflow deploy-demo.yml --limit 1 --json databaseId,headSha,conclusion,url 2>/dev/null); rc=$?; if [ "$rc" -ne 0 ] \|\| [ -z "$run" ] \|\| ! printf '%s' "$run" \| jq -e 'type == "array"' >/dev/null 2>&1; then echo "verdict unknown deploy-demo.yml: the run list is not readable (gh run list failed or returned a non-array)"; elif [ "$(printf '%s' "$run" \| jq -r 'length')" = "0" ]; then echo "no run: deploy-demo.yml has no matching run"; else run=$(printf '%s' "$run" \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); c=$(jq -r .conclusion <<<"$run"); url=$(jq -r .url <<<"$run"); repo=$(gh repo view --json nameWithOwner -q .nameWithOwner); jobs=$(gh api "repos/$repo/actions/runs/$(jq -r .databaseId <<<"$run")/jobs" 2>/dev/null); if [ -z "$jobs" ] \|\| [ "$jobs" = "null" ]; then v=unreadable; else job_id=$(printf '%s' "$jobs" \| jq -r '.jobs[]? \| select(.name == "build") \| .id' 2>/dev/null \| head -1); log=$(gh run view "$(jq -r .databaseId <<<"$run")" --job "$job_id" --log 2>/dev/null); if [ -z "$log" ]; then v=unreadable; else v=$(printf '%s' "$log" \| awk -F'\t' '$2 == "resolve built commit"' \| grep -oE '(^|[^-0-9A-Za-z_])sha-[0-9a-f]{7}([^-0-9A-Za-z_]|$)' \| head -1 \| grep -oE 'sha-[0-9a-f]{7}'); if [ -z "$v" ]; then v=unresolved; fi; fi; fi; if [ "$v" = unreadable ]; then echo "verdict unknown $sha $url"; elif [ "$v" = unresolved ]; then echo "Unhealthy: deploy-demo built no sha-<7> image tag at $sha, so Image Updater has no candidate and the demo is frozen on its current digest ($url)"; else echo "$c $sha $url tagged $v"; fi; fi` | `success`, and a `sha-<7>` image tag the `resolve built commit` step wrote (this proves the pushed tag, not the served version) |
| the demo serves the checkout version | `expected=$(grep -oE "[\"'][0-9][^\"']*[\"']" lib/wurk/version.rb \| head -1 \| tr -d "\"'"); out=$(curl -sS --max-time 5 -w '\n%{http_code}' "https://wurk.demo.developerz.ai/wurk/api/meta" 2>/dev/null); rc=$?; code=$(printf '%s' "$out" \| awk 'BEGIN{RS="\n"} END{print $0}'); body=$(printf '%s' "$out" \| awk 'BEGIN{RS="\n"} {if (NR>1) print prev; prev=$0}'); if [ "$rc" -ne 0 ] \|\| [ -z "$code" ] \|\| [ "$code" = 000 ]; then echo "verdict unknown: the demo version probe failed (curl rc=$rc, HTTP ${code:-none}), so the served version cannot be read"; elif [ "$code" != 200 ]; then echo "verdict unknown: the demo version probe returned HTTP $code, so the served version cannot be read"; else served=$(printf '%s' "$body" \| jq -rse 'if length == 1 and (.[0] \| type == "object") then (.[0].version // empty) else empty end' 2>/dev/null); jq_rc=$?; if [ "$jq_rc" -ne 0 ] \|\| [ -z "$served" ]; then echo "verdict unknown: the demo version probe returned no usable version (HTTP body was not a single JSON object with a version key)"; elif [ "$served" = "$expected" ]; then echo "success: the demo serves $expected"; else echo "Unhealthy: the demo serves $served but the checkout expects $expected"; fi; fi` | `success: the demo serves <version>`; a mismatch is Unhealthy, and a transport failure, a non-200 response, a body that is not a single JSON object (trailing garbage included) or a missing `version` key is `verdict unknown` |
| topology and ecosystem lanes | `for wf in topology.yml ecosystem.yml; do run=$(gh run list --workflow $wf --branch main --event push --limit 1 --json databaseId,headSha,conclusion,url 2>/dev/null); rc=$?; if [ "$rc" -ne 0 ] \|\| [ -z "$run" ] \|\| ! printf '%s' "$run" \| jq -e 'type == "array"' >/dev/null 2>&1; then echo "verdict unknown $wf: the run list is not readable (gh run list failed or returned a non-array)"; elif [ "$(printf '%s' "$run" \| jq -r 'length')" = "0" ]; then echo "no run: $wf has no matching run"; else run=$(printf '%s' "$run" \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); url=$(jq -r .url <<<"$run"); c=$(jq -r .conclusion <<<"$run"); dbid=$(jq -r .databaseId <<<"$run"); v=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$dbid/jobs" \| jq -r 'def gate_steps: [(.steps // [])[] \| select(.name != "Set up job" and .name != "Complete job")]; [.jobs[]?] as $all \| [$all[] \| select(.name != "detect changed paths" and .name != "sidekiq release watcher")] as $g \| [$all[] \| select(.name == "detect changed paths")] as $d \| ($g \| map(gate_steps)) as $gs \| if ($all \| length) == 0 then "evidence unavailable (the jobs list could not be read)" elif ($g \| length) == 0 then "evidence unavailable (the jobs list carries no gated job)" elif ($d \| length) == 1 and ($d[0].conclusion == "success") and all($g[]; .conclusion == "success") and all($gs[]; length > 0) and all($gs[]; all(.[]; .conclusion == "skipped")) then "duplicate-skipped" elif any($gs[]; any(.[]; .conclusion != "skipped")) then "executed" else "evidence unavailable (no gated job ran and the reuse could not be confirmed)" end' 2>/dev/null); [ -n "$v" ] \|\| v="evidence unavailable (the jobs list could not be read)"; if [ "$c" = "success" ]; then case "$v" in executed) echo "$wf executed: $c $sha $url" ;; duplicate-skipped) echo "$wf duplicate-skipped: the gated steps were skipped; the tree already passed that workflow $sha $url" ;; *) echo "$wf $v, so this lane's gates are unverified $sha $url" ;; esac; else echo "$wf $c $sha $url"; fi; fi; done` | `executed` on both (the gated steps ran); `duplicate-skipped` and `evidence unavailable` file no ask |
| Dependabot is not stuck | `prs=$(gh pr list --state open --app dependabot --json number,title,createdAt,headRefName,updatedAt,statusCheckRollup,headRefOid 2>/dev/null); if [ -z "$prs" ] \|\| ! printf '%s' "$prs" \| jq -e 'type == "array"' >/dev/null 2>&1; then echo "verdict unknown dependabot: the open PR list is not readable (gh pr list failed or returned a non-array)"; exit 0; fi; printf '%s' "$prs" \| jq -r --argjson now "$(date -u +%s)" 'def eco: if test(" group with .* updates$") or test("^Bump actions/") or test("^Bump github-actions/") then "github-actions" elif test(" in /frontend") then "bun" elif test(" in /Dockerfile") or test("^Bump [^ ]+/[^ ]+ from") then "docker" else "bundler" end; def branch_eco: if test("^dependabot/bundler/") then "bundler" elif test("^dependabot/bun/") then "bun" elif test("^dependabot/github_actions/") then "github-actions" elif test("^dependabot/docker/") then "docker" else null end; def budget: {"github-actions":37,"docker":37,"bundler":28,"bun":14}; def state: [.statusCheckRollup[]? \| select(type=="object") \| if has("state") then .state elif (.conclusion\|type)=="string" then .conclusion else "PENDING" end] as $c \| if any($c[]; test("^(FAILURE\|ERROR\|TIMED_OUT\|CANCELLED\|ACTION_REQUIRED\|STALE\|STARTUP_FAILURE)$")) then "FAILURE" elif any($c[]; test("^(PENDING\|EXPECTED)$")) then "PENDING" else "SUCCESS" end; if length == 0 then "dependabot: 0 open PRs" else (map(. as $p \| ($now - ($p.createdAt\|fromdateiso8601)) as $sec \| ($sec/86400\|floor) as $age \| ((($p.headRefName // "") \| branch_eco) // (($p.title // "") \| eco)) as $e \| ($p\|state) as $s \| {n:$p.number,age:$age,b:budget[$e],e:$e,s:$s,br:($p.headRefName // "unknown"),sha:($p.headRefOid // "unknown"),up:($p.updatedAt // "unknown"),stuck:(($age>budget[$e]) and ($s=="FAILURE"))}) as $prs \| (["bundler","bun","github-actions","docker"] \| map(. as $k \| [$prs[] \| select(.e==$k)]) \| map(select(length > 0)) \| map({e: .[0].e, n: length, s: (if any(.[]; .s=="FAILURE") then "FAILURE" elif any(.[]; .s=="PENDING") then "PENDING" else "SUCCESS" end)})) as $groups \| ("dependabot: " + ($prs\|length\|tostring) + " open PRs (" + ($groups \| map(.e + " " + (.n\|tostring) + " " + .s) \| join(", ")) + ")"), ($prs[] \| "#" + (.n\|tostring) + " " + .e + " " + .br + " " + .sha + " " + .up + " " + .s), ($prs[] \| select(.stuck) \| "Unhealthy: Dependabot is stuck on #" + (.n\|tostring) + " (age " + (.age\|tostring) + "d > " + (.b\|tostring) + "d budget for " + .e + ")")) end'` | a `dependabot: <N> open PRs (<ecosystem> <count> <STATE>, ...)` summary and one `#<n> <ecosystem> <branch> <headSha> <updatedAt> <STATE>` line per open PR, and no `Unhealthy: Dependabot is stuck on #<n> (age Xd > Yd budget for <ecosystem>)` line — every dependabot PR is under its ecosystem's `interval (+ 14d bundler cooldown) + 7d` margin |
>

**Grading a dup'd push.** `bin/ci-dup-push` lets a push to main skip a workflow's gated jobs when the
pushed tree already passed that workflow on the merged PR's head — `detect.dup=true`. Such a run
still reports `conclusion=success` with nothing having run, so rows 8 and 14 read
`databaseId,headSha,conclusion,url` *and* the job list from
`gh api repos/$repo/actions/runs/<databaseId>/jobs`, and grade a successful push into exactly one of
three named classes: `executed` (the gated steps ran), `duplicate-skipped` (the tree was reused) or
`evidence unavailable` (the job list could not be read). The run list itself is graded before its
contents (step 1); the classes are read off the job list (steps 2-5). Every verdict the rows print
carries the run's `url` alongside its `sha`, so the ask can link the run without a second `gh` call.

1. **The run list itself is graded first, and an unreadable list and an empty one are different
   findings.** The rows read `gh run list --workflow <workflow> --limit 1 --json ...` into a
   variable, capture gh's exit status out of that command substitution, and test the status BEFORE
   they inspect what was captured: a read that failed (gh exited non-zero — which it can do after
   the array has already landed on stdout, so a row that graded the captured array would certify a
   read its own exit status disowns), or wrote nothing, or returned something other than a JSON
   array, grades `verdict unknown <workflow>: the run list is not readable (gh run list failed or
   returned a non-array)` — never a colour. A readable but EMPTY array (gh exited zero) is its own
   outcome and names the
   workflow: `no run: <workflow> has no matching run`. It carries no sha and no url, because no run
   exists to link; it is not `verdict unknown`, and it is not Unhealthy either. The two must never
   look alike: the old `jq -c '.[0]'` read turned `[]` into the literal string `null` for every
   field, so an empty list printed the same `verdict unknown null null` line a failed read printed,
   naming nothing and establishing nothing. Match row 14's rule: a row that cannot read its list is
   neither green nor red, and a list that is readable but empty is its own outcome, never a
   `verdict unknown`.
2. **An unreadable job list grades `evidence unavailable <sha> <url>`**, never a colour. The `gh api` call is
   the only thing standing between a rate limit or 4xx and a verdict the row cannot actually
   establish, so an empty or unparseable list short-circuits *before* anything is concluded from
   `conclusion`. An unreadable list is not verified main health: the row knows the run concluded
   `success`, but not whether a single gated step ran, so it reports neither a green nor a red one
   and files no ask; the next checkup re-runs it. A list that carries no gated job at all grades the
   same way — there is no evidence of execution in it to grade.
3. **The reuse is read off the gated jobs' STEPS, not off the jobs' own conclusions.** Every gated
   job in these workflows is gated per STEP — `RUN: needs.detect.outputs.dup != 'true'` in the job's
   `env:`, `if: env.RUN == 'true'` on each step (test.yml:153-157) — so a dup'd push does NOT report
   the gated jobs as `skipped`: the jobs run, report `success`, and every one of their steps reports
   `skipped`. The jobs API carries no step *outputs*, so `dup=true` is read from that runtime
   signature: the `detect changed paths` job concluded `success`, every gated job concluded
   `success`, and every one of their steps concluded `skipped` — the runner's own `Set up job` and
   `Complete job` steps excepted, which are the runner's setup and teardown rather than the gate and
   conclude `success` on a job that did nothing. Reading the gated jobs' conclusions instead cannot
   tell a reuse from a run that executed its gates — both report `success` — so every dup'd push
   would be graded as a run that executed: the green the tree never earned.
4. **`detect changed paths` must conclude `success`** before that signature reads as a dup. A failed
   or cancelled `detect` publishes no outputs, `needs:` then skips every dependent before it starts,
   and the job list comes back with the gated jobs reporting `skipped` and carrying no steps — a
   different signature, and a different cause: the run grades on its own `conclusion`, which is what
   actually explains why nothing ran. On a push to main, with a successful `detect`, the signature is
   one-to-one — the same `RUN: needs.detect.outputs.dup != 'true'` expression runs every gated step
   when `dup` is false, so every gated step reporting `skipped` then means a duplicate-skipped push
   and nothing else (`sidekiq release watcher` is excluded; it is a `schedule`/`workflow_dispatch`
   job, never gated on dup). A `detect` that failed is not a dup. The `duplicate-skipped` verdict
   names the reuse — the gated steps were skipped; the tree already passed that workflow — and
   carries the run's `sha` and `url`. It is neither a green the row did not earn nor a failure, so
   it files no ask.
5. **Otherwise the gated steps ran, and the verdict is `executed`** — carrying the run's
   `conclusion`, its `sha` and its `url`. The evidence is a gated step that concluded something other
   than `skipped`. A run whose `conclusion` is not `success` never reaches this grading: it grades
   on its own conclusion and prints `<conclusion> <sha> <url>`, red or not.
**Confirming the signature against the run.** The runtime signature is what the row grades on, so
read it back off the run itself when a verdict needs checking. In the `detect changed paths` job,
the log step `duplicate of an already-green PR head (dup)` runs `bin/ci-dup-push`, which writes
`ci-dup-push: …` to STDERR on both its paths: a dup prints
`ci-dup-push: tree <tree> already passed <workflow> on PR #<n> head <sha> — skipping` (dup=true),
and anything else prints `ci-dup-push: <reason> — full run` (dup=false). So
`gh run view <id> --log | grep 'ci-dup-push:'` on that job reads `— skipping` for a dup and
`— full run` with the reason it did not skip. The gated jobs' steps carry the same fact from the
other side: on a dup every gated step reports `skipped`, the runner's own `Set up job` and
`Complete job` excepted. This confirms the signature; it does not change it — a failed `detect`
still does not grade as a dup, whatever its log says.

A duplicate-skipped push grades **neither green nor red**: the tree already passed that workflow on
the PR head, so the coverage is real and the tree is not broken — a reuse is neither "the tests
executed" nor a failure, and it files no ask. The verdict names the reuse and the run's `headSha`
and `url`, so a reader can see which push reused which tree. Row 14 runs the same read over both
workflows and names the lane. Keep rows 8 and 14 on one read shape — dropping the jobs call reopens
a `main` that certifies green having run no tests at all, reading the gated jobs' conclusions
instead of their steps certifies that same green on a reused tree, and dropping the `detect` check
misreads a failed run as a dup'd one.
**Grading a release run that published nothing.** Row 9 grades ONE run, and it binds that run to the
commit that carries `Wurk::VERSION` before it grades anything. release.yml fires on a version bump
landing on `main` (release.yml:18-21) and publishes the version that commit carries, so the run that
says anything about `Wurk::VERSION` is the one whose `headSha` is the newest `main` commit that
touched `lib/wurk/version.rb` — read with
`gh api "repos/developerz-ai/wurk/commits?path=lib/wurk/version.rb&sha=main&per_page=1"`. The newest
run of any shape (`gh run list --workflow release.yml --limit 1`) is NOT that run: it can be a no-op
for an older version, a re-run, or a run for a commit that never carried this version, and grading it
as "the last release published" certifies a publication that says nothing about the version of record.
So the row reads `gh run list --workflow release.yml --commit <sha> --limit 1` and REFUSES a run
whose `headSha` is not the version's own sha: two reads that disagree establish nothing, so that
grades `verdict unknown`, never a colour. An unreadable commits list, an unreadable run list and an
empty run list grade `verdict unknown` as well — the row cannot tell a run that has not started from
one that never existed, and neither is a red release.

The version the row grades is read from that same commit — `gh api -H "Accept:
application/vnd.github.raw" "repos/developerz-ai/wurk/contents/lib/wurk/version.rb?ref=<sha>"` —
never from the checkout's own copy of the file. The checkout can lag `main`: a version bump that
lands after the checkout would leave rows 9 and 10 binding the run to the newer version's commit
while probing RubyGems for the older checkout's version, and a green run could then be certified by
the older gem's HTTP 200 — a publication claimed for a version that run never shipped. Reading the
version from the resolved commit makes the run, the version and the probe one triple by
construction. The read fails closed like everything else in the row: an unreadable contents read, or
one that yields no version, grades `verdict unknown`.

Row 9 then reads `databaseId,headSha,conclusion,url` from that run *and* the job list from
`gh api repos/$repo/actions/runs/<databaseId>/jobs`, and grades in four steps, for the reason the dup
rows do: the jobs API carries no step *outputs*, so what release.yml decided cannot be read
directly, and its cheapest exit is a run that publishes nothing and still reports `conclusion=success`.

1. **A null `conclusion` is in flight** — report `in flight <sha>` and grade nothing. A run still
   executing has `conclusion=null`, and its job list is a partial picture (`release` not started,
   `demo` not queued) that no verdict may be built on.
2. **An unreadable job list grades `verdict unknown <sha>`**, never a colour — the same fail-closed
   rule rows 8 and 14 use.
3. **`preflight` concluded `success` with `release` skipped is a no-op.** release.yml:80-90 is the
   whole proceed signal in one contiguous range: preflight curls RubyGems for `Wurk::VERSION` and
   emits `proceed=false` when it is already there, and the `release` job is gated on
   `needs.preflight.outputs.proceed == 'true'`. `demo` needs `[preflight, release]`
   (release.yml:222-228). So a proceed=false run is `preflight` `success`, `release` skipped, `demo`
   skipped — and the run still concludes `success`, because a skipped job does not fail a run. Print
   `no-op <sha>`. Grading this row on `--json conclusion` alone reports that green as the last
   release published, which it is not.
4. **Otherwise grade on `conclusion`** — but a green run is only a PUBLICATION when RubyGems serves
   the version. The canonical probe is the authority (RELEASE.md's *Verifying a release actually
   shipped*, and row 10's own read of it): HTTP 200 grades `success <sha> <url>`; HTTP 404 grades
   `Unhealthy: green but empty publication: ...` — a green run whose version never reached RubyGems
   is the false green this row exists to refuse; an unreadable probe (a transport failure, a 5xx)
   grades `verdict unknown`, because no HTTP status is not evidence that the version is absent. A red
   run grades on its own `conclusion`, printing `<conclusion> <sha> <url>`.

A no-op is **not Unhealthy and files no ask**: proceed=false means that version is already live on
RubyGems, so nothing was owed. A red release's ask carries the version in its body, still taken
from `lib/wurk/version.rb` — at the version-carrying commit, the read rows 9 and 10 grade, never the
checkout's stale copy; row 10 owns the RubyGems probe in its own right,
and step 4's cross-check is that same probe. A run that
genuinely went red stays Unhealthy and grades
on its own `conclusion` — `release` failed, or `preflight` failed the non-main refusal
(release.yml:55-60). That second case skips every dependent through `needs:` and comes back with the
same all-skipped list a no-op produces, which is why step 3 requires `preflight` itself to have
concluded `success`.

Row 10's probe is the canonical one RELEASE.md's *Verifying a release actually shipped* defines: the
RubyGems API v2 per-version endpoint, with `<version>` read from `lib/wurk/version.rb` at the
version-carrying commit — the same read row 9 binds its run with, never the checkout's own copy,
which can lag `main` by a version bump (see the release-run binding above). The row
captures the HTTP status (`curl -w '%{http_code}'`, with no `-f`) instead of grading curl's exit
code: under `-f` a 404 and a dead network are the same non-zero exit, so a genuinely missing
release graded `verdict unknown` and could never go red. The probe is deadline-bounded
(`--max-time 5`): a server that accepts the connection but stalls the response costs its deadline
and exits 28 with no HTTP status, grading `verdict unknown` through the same probe-failed arm — an
unbounded curl would block the unattended checkup without printing any verdict, and the signals
after this row would never run. It grades in three steps:

1. **Any status other than 200 or 404 grades `verdict unknown`**, never a colour: a transport
   failure (curl writes `000` — no HTTP status at all), a 5xx, or an unreadable result is probe
   failure, not evidence the version is absent, so the row fails closed and the next checkup
   re-runs it, the same rule rows 8, 9, 12 and 14 use.
2. **HTTP 200 grades `success: RubyGems serves <version>`** — the healthy verdict.
3. **HTTP 404 means the version is absent**, and the row grades the absence through release.yml's
   run for the version's OWN commit — the same run row 9 reads, bound the same way
   (`gh run list --workflow release.yml --commit <sha> --limit 1`, where `<sha>` is the newest `main`
   commit that touched `lib/wurk/version.rb`). The newest run of any shape is not that run: it can
   be a no-op for an older version, so grading the absence against it files a false Unhealthy for a
   release that is still in flight. A run still executing (`conclusion=null`) may still publish and
   await propagation, so the row reports `in flight` — the second healthy state the row's Healthy
   column names. A run that has concluded means nothing is propagating and the version is genuinely
   missing, so the row grades `Unhealthy: ... the release did not publish <version>`. An unreadable
   run list — and a run whose `headSha` is not the version's own sha — grades `verdict unknown`:
   the run read is the only thing between a rate limit and a false Unhealthy filed against a release
   that is still in flight.

**Grading the GitHub Release artifact.** Row 11 reads the Latest GitHub Release —
`gh release view --json author,assets` — and applies RELEASE.md's gem-less discriminator: a release
whose `author` is `developerz-ai[bot]` OR whose `assets` array is empty is a gem-less release, not a
real one (RELEASE.md:192-194, RELEASE.md:222-223). That is the shape the seven stray releases took:
a GitHub Release marked `Latest` with no `.gem` behind it, lying about the latest version while
`gem install wurk` kept serving the previous one. The row reads the LATEST release rather than the
release for `Wurk::VERSION`: a stray release was cut at a version the repository never released, so a
version-bound read would never have seen it — and a stray release standing as `Latest` is exactly
what the discriminator is for.

1. **An unreadable lookup grades `verdict unknown`**, never a colour — and the comparison must not
   pass vacuously. A lookup that returned no author and no assets would satisfy "the author is the
   bot OR there are no assets" for the wrong reason, so both fields have to be present and readable
   before the discriminator may be applied (the guard release-due.md runs at release-due.md:28-33). A
   failed `gh release view` (a rate limit, a 4xx, a repository with no release at all) and a lookup
   with no parsable author/assets both grade `verdict unknown`.
2. **A gem-less release grades Unhealthy** — `author=developerz-ai[bot]` OR `assets.length=0`. The
   ask points at RELEASE.md's *Recovering a gem-less release* runbook; the checkup never deletes a
   tag, never re-publishes a gem and never re-tags by hand.
3. **Otherwise the release carries the gem**, and the row is healthy: the `.gem` asset is attached
   and the author is the release workflow, not the maintainer agent.

**Grading a demo deploy.** Row 12 reads `databaseId,headSha,conclusion,url` *and* the job list from
`gh api repos/$repo/actions/runs/<databaseId>/jobs`, then reads the `build` job's full log via
`gh run view <databaseId> --job <build.id> --log` and grades in four steps. The reason is the
deploy model: deploy-demo.yml only BUILDS and PUSHES the image (deploy-demo.yml:7-11). Nothing in
the workflow deploys it — infra's ArgoCD Image Updater picks the newest DOCR tag matching
`^sha-[0-9a-f]{7}$` and syncs on its own. So a green run is a claim about a pushed tag, not about
what the demo is serving, and the only place that tag is recorded is in the `resolve built
commit` step's log line (the jobs API does not carry step logs).

1. **The run list is graded first, and an unreadable list and an empty one are different
   findings.** `gh run list --workflow deploy-demo.yml --limit 1 --json ...` is read into a variable,
   the command substitution's exit status is captured beside it, and the status is tested before the
   captured bytes are inspected: a read that failed (gh exited non-zero — which it can do after the
   array has already landed on stdout), or that wrote nothing, or that returned something other than
   a JSON array grades `verdict unknown deploy-demo.yml: the run list is not readable (gh run
   list failed or returned a non-array)`, never a colour. A readable but EMPTY array (gh exited
   zero) is its own
   outcome — `no run: deploy-demo.yml has no matching run` — carrying no sha and no url, because no
   run exists to link. It is not `verdict unknown`, and it is not Unhealthy. The two must never look
   alike: extracting `.[0]` from an empty list yields the literal string `null` for every field, so
   an empty list used to print the same `verdict unknown null null` line a failed read printed.
2. **An unreadable jobs list OR an unreadable `build` job log grades `verdict unknown <sha> <url>`**,
   never a colour — the same fail-closed rule rows 8, 9 and 14 use. This row grades only the pushed
   `sha-<7>` tag; if the jobs read or the log read fails, the next checkup re-runs it rather than the
   row guessing from `conclusion`.
3. **A green run with no `sha-[0-9a-f]{7}` in the `resolve built commit` step's log is Unhealthy**,
   whatever the `conclusion`. `resolve built commit` (deploy-demo.yml:173-180) writes
   `short=sha-<7>` to `$GITHUB_OUTPUT` from `git rev-parse HEAD`, and `steps.built.outputs.short` is
   the first tag `build-push-action` pushes. No tag in that exact format means no Image Updater
   candidate, which is precisely how the demo silently sat on an old digest across several
   releases (deploy-demo.yml:165-172). An older version still being served is a deployment
   failure, so the verdict names it: the ask is to fix the tag, not to re-run the deploy.

   Two rules keep that read honest, and both are load-bearing:

   - **Only the named step's lines.** `gh run view --log` prints one line per log
     line as `<job>\t<step>\t<timestamp> <message>`: the job and step names are
     tab-separated columns ahead of the log line's own `<timestamp> <message>`. The
     step is field 2 — filtering the message column instead keeps no line at all and
     grades every successfully tagged deploy Unhealthy. So the row keeps the lines
     whose field 2 is `resolve built commit` and drops the rest of the `build` job.
     The tag this row grades is the one *that step* wrote: a `sha-<7>`-shaped string
     anywhere else in the job is not evidence for it, and a green printed off one is a
     green the row cannot establish.
   - **A whole token, not a prefix.** `sha-12345678` is the 8-hex full-sha shape
     and does not match Image Updater's `^sha-[0-9a-f]{7}$`, so a bare
     `sha-[0-9a-f]{7}` match takes its first seven characters and names a tag
     nothing will ever select. The match is wrapped in `(^|[^-0-9A-Za-z_])` and
     `([^-0-9A-Za-z_]|$)` instead, so neither end of the tag can be extended
     into a longer hex run.
4. **Otherwise grade on `conclusion`**, printing `<conclusion> <sha> <url> tagged sha-<7>`.

**Green is necessary, not sufficient.** Row 12 proves the image was built and pushed under the
tag shape Image Updater selects. It does **not** prove the demo serves that image — the sync, the
rollout and the in-cluster health of the app all live in the infrastructure repo. Row 13 therefore
probes the served version directly: it GETs the public, unauthenticated, read-only
`https://wurk.demo.developerz.ai/wurk/api/meta`, whose `version:` comes from
`app/controllers/wurk/api_controller.rb:53` (`::Wurk::VERSION`), and compares that value with the
version extracted from `lib/wurk/version.rb`. The probe holds no deployment credentials and grants
no mutation or deploy authority.

The row captures the HTTP status alongside the body (`curl -w '\n%{http_code}'`, with no `-f`):
without `-f` a 404 and a dead network are the same exit code, and a body alone cannot say whether
the demo answered at all. The status is what separates a real answer from a 404 that happened to
carry JSON, so it is graded before the body is read. The request itself is deadline-bounded
(`--max-time 5`): a demo that accepts the connection but never finishes the response would
otherwise block the unattended checkup forever — the row prints no verdict and every signal after
it goes unread. curl kills such a request at the deadline and exits 28 with no status and no body,
which grades through the same fail-closed arm as any other transport failure.

The served-version row grades in three mutually exclusive verdicts:

1. **Exactly one JSON object whose `version` equals the checkout's version is healthy** —
   `success: the demo serves <version>`.
2. **Exactly one JSON object whose `version` differs is Unhealthy** — the demo serves a different
   version than the checkout, and the verdict names both the served and the expected version.
3. **A transport failure, a non-200 response, a body that is not exactly one JSON object, or an
   object without a usable `version` is `verdict unknown`** — never green and never a silent
   pass. An unavailable probe is not evidence that the demo is healthy, so the next checkup
   re-runs it.

The body is validated as **one single JSON object before any verdict is read off it**, and jq's
exit status is checked alongside its output: `jq` parses a *stream* of JSON values, so on
`{"version":"<expected>"}<garbage>` it emits the version first and only then fails on the trailing
text — a row that captured jq's stdout and ignored its exit status printed that body as a healthy
success. The read is `jq -s` (slurp the whole input) requiring `length == 1` and
`type == "object"` with `-e`, so leading or trailing garbage and two JSON values die in the parse,
a non-object payload fails the shape check, and an object with no `version` (`// empty` output)
exits non-zero — every unreadable shape folds into the same fail-closed arm. A trailing newline,
which is what a real response body ends with, still parses as one value and stays healthy.

Row 12's green is consequently scoped to the pushed `sha-<7>` tag; row 13 carries the
served-version verdict. A demo that visibly lags main remains an ask against the tag from row 12
and the version from row 13.

**Grading dependabot.** Row 15 calls `gh pr list --state open --app dependabot --json number,title,createdAt,headRefName,updatedAt,statusCheckRollup,headRefOid` — the OPEN PRs only, with `--state open` stated explicitly instead of left to `gh pr list`'s default, and with every field the report prints — and grades each open PR against the budget its ecosystem's dependabot.yml block sets: `bundler` (lines 17-35, weekly interval + 14-day cooldown), `bun` (lines 41-49, weekly), `github-actions` (lines 54-61, monthly), `docker` (lines 76-89, monthly). A PR is stuck when its `statusCheckRollup` — the list of checks `gh` sends, rolled up per step 3 below — grades `FAILURE` past `interval + (14d cooldown if bundler) + 7d margin` days; those budgets in days are 28 (bundler), 14 (bun), 37 (github-actions), 37 (docker), and reporting what was read changes none of them. Grading reads the JSON the command emits and reports it in three parts: a `dependabot: <N> open PRs (<ecosystem> <count> <STATE>, ...)` summary line — one entry per ecosystem that has at least one open PR, in the order above, each carrying that ecosystem's rolled-up check state, the worst of its PRs' states with `FAILURE` outranking `PENDING`; then one `#<n> <ecosystem> <headRefName> <headRefOid> <updatedAt> <STATE>` line per open PR, carrying the PR number, its ecosystem, its branch, the head commit SHA (`headRefOid` — the only field a head SHA is ever read from) and its last update, with `unknown` standing in for a field the list does not carry; then one `Unhealthy: Dependabot is stuck on #<n> ...` line per stuck PR. The summary and the per-PR lines are the report, not a verdict: they print on every run, and only the `Unhealthy:` lines are a verdict.

1. **An unreadable list grades `verdict unknown`, in one line that says it is unreadable.** The `gh pr list` call is the only thing between a rate limit, an empty pipe, or a non-array payload and a verdict the row cannot establish; an empty string from `gh`, or input that is not a JSON array (`jq -e 'type == "array"'` exits non-zero), short-circuits *before* any PR is graded, and the next checkup re-runs it. The row then prints exactly one line — `verdict unknown dependabot: the open PR list is not readable (gh pr list failed or returned a non-array)` — and nothing else. That line carries BOTH `verdict unknown` and `not readable`, because an unreadable list and an empty one are different findings and must never look alike: a readable but EMPTY list is its own outcome, `dependabot: 0 open PRs`, with no `verdict unknown` on it. Match the dup and release rules: a row that cannot read its list is not green and not red.
2. **Ecosystem detection reads the branch first and the title second.** Dependabot names its branch after the ecosystem it bumped (`dependabot/bundler/…`, `dependabot/bun/…`, `dependabot/github_actions/…`, `dependabot/docker/…`), and `headRefName` is requested precisely so the ecosystem is read off that branch instead of being guessed at from prose: `dependabot/bundler/` is `bundler`, `dependabot/bun/` is `bun`, `dependabot/github_actions/` is `github-actions`, `dependabot/docker/` is `docker`. A branch that carries no ecosystem segment — or no branch at all — falls back to the title, because dependabot.yml's `directory` field is not in `gh pr list` output either: `… in /frontend` is `bun`; `Bump <image>/<name> from …` (the `oven/bun` form, with a slash in the dep name) is `docker`; `Bump the github-actions group with N updates` and `Bump actions/…` are `github-actions`; the default — `… in /` for a gem-shaped name like `rubocop` — is `bundler`. Both docker and github-actions have `directory: "/"` in dependabot.yml (lines 76-78, 54-55), so neither ever ends `… in /Dockerfile`; the load-bearing docker marker is the slash-in-the-dep-name form (`^Bump [^ ]+/[^ ]+ from`), and the github-actions group/owner forms are tested first so `Bump actions/checkout` is not mis-classified as docker by that same rule. The two signals do NOT always agree, and where they disagree the branch wins. The title rule's first test — ` group with .* updates$` — matches EVERY grouped title, and dependabot titles a group PR after the PACKAGE ecosystem rather than after the group's own key (the group at dependabot.yml:60 is keyed `actions`, yet its PR is titled `Bump the github-actions group with N updates`), so a grouped bun PR (dependabot.yml:47-49) reads as `github-actions` by title while its branch says `bun`: reading the branch first changes that PR's ecosystem, its budget (github-actions' 37d → bun's 14d) and its verdict. The branch is the signal that names the ecosystem; the title only fills in for a branch that carries no ecosystem segment, and it cannot tell one grouped ecosystem from another.
3. **`statusCheckRollup` is a LIST of checks, not a state on the PR.** `--json statusCheckRollup`
   returns the GraphQL union `StatusCheckRollupContext` as one object per check, and the PR carries
   no `.state` of its own to read: a `CheckRun` entry has `status` and `conclusion`, a
   `StatusContext` entry — a check from a non-Actions app — has `state`. There is no third shape,
   and a row that reads a rollup state off the PR grades every real PR `""` and reports no stuck
   dependabot PR, ever. Roll the entries up the way the Checks tab does:
   1. **One entry → one verdict.** An entry with a `state` is a StatusContext and reports it; an
      entry with a string `conclusion` is a concluded CheckRun and reports that; an entry with
      neither is a CheckRun still running, `PENDING` (Actions sends `conclusion: null` with
      `status` `QUEUED`/`IN_PROGRESS`/`WAITING`). `__typename` is not consulted — the two entry
      types are told apart by the field each one actually carries.
   2. **`FAILURE` outranks `PENDING`.** One failing entry makes the PR red however many others are
      still going, so a red-and-running PR is stuck and a still-running PR is not.
   3. **Every CheckRun conclusion that is not clean is a failure**: `FAILURE`, `TIMED_OUT`,
      `CANCELLED`, `ACTION_REQUIRED`, `STALE`, `STARTUP_FAILURE`. A `StatusContext` of `ERROR` or
      `FAILURE` is one too. Grading for the literal string `FAILURE` alone misses a check that
      timed out, which blocks a merge exactly as hard.
   4. **No red and no pending left is `SUCCESS`** — including `SKIPPED` and `NEUTRAL` conclusions,
      which decide nothing, and including a PR with no checks at all (`[]`): nothing is red.
      Entries that are not objects are dropped, so a malformed rollup grades like a PR with no
      checks instead of taking the whole `jq` down and silencing every PR in the list.
4. **Red and young is not stuck.** A docker bump that dependabot cannot finish on its own (dependabot.yml:63-72 — dependabot bumps the Dockerfile's `oven/bun` tag but cannot edit the `bun-version:` inputs in .github/workflows/test.yml or release.yml, nor `bun` in mise.toml) stays `FAILURE` until the matching pin edits land on the dependabot branch; `test/unit/toolchain_pins_test.rb` (lines 57-60) fails the PR until all four pins agree. The row does not call a PR younger than its ecosystem budget a stuck one — that expected-red is the headline of dependabot.yml:63-72, not a regression.
5. **Past budget and red is stuck.** A PR whose rollup grades `FAILURE` under step 3 and an age in days strictly greater than its ecosystem's budget is stuck: print `Unhealthy: Dependabot is stuck on #<n> (age <Xd> > <Yd> budget for <ecosystem>)`. The line names the signal and the PR number so the ask can link it (cf. the RubyGems row's `Unhealthy:` line, which names the missing version so the ask can link it); multiple stuck PRs in one run print one line each.

A PR past budget that rolls up `SUCCESS` or `PENDING` is not stuck: an old green is just an old human-pending merge, not a regression dependabot can fix on its own, and a pending one is still in flight. `updatedAt` is REPORTED, never GRADED: it is the PR's last update, not its age, so a PR whose branch was touched yesterday is not a PR that has been failing for a month — the age a budget is graded against is always `createdAt`, and reporting the update introduces no new age or cadence threshold. `isDraft` is not requested at all, because nothing consults it — a past-budget red draft PR is graded here like any other and printed stuck; the stuck-ness is a property of age + a `FAILURE` rollup, not of draft status.
>

For each unhealthy signal, file one ask unless an open issue already names it. Filing an ask
requires FIRST running, exactly, `gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'`
— the same lookup release-due's ask guard runs, for the reasons argued there: `gh issue list`
rejects `--paginate` and truncates at 30, and the `/issues` route returns pull requests alongside
issues, hence the filter. If any returned title equals the signal's title exactly, the ask already
exists — never file a second ask while one with this title is open. Because the dedupe match is
exact equality on the title, every signal's title is a stable name, identical on every occurrence;
nothing that changes run to run (sha, run URL, version, PR age) may appear in it — those
live in the body. The stable titles are: row 8 files `main is red`; row 9 files
`release did not publish`; row 10 files
`RubyGems does not serve Wurk::VERSION` (the constant's name, never its value); row 11 files
`GitHub Release is gem-less`; row 12 files `demo frozen: no sha-<7> image tag`; the demo
served-version row files `demo serves a different version than the checkout`; row 14 files per
workflow so the two lanes stay
distinguishable — `topology.yml is red` and `ecosystem.yml is red`; row 15 files
one ask per stuck PR titled `Dependabot is stuck on #<n>`, where the PR number is stable for
the lifetime of that stuck PR and keeps distinct stuck PRs distinguishable. A `duplicate-skipped`
push files no ask — the tree already passed that workflow on the PR head, so the coverage is real —
and an `evidence unavailable` verdict files no ask either: it says nothing about the tree at all.
Not every line a row prints is an unhealthy signal, and the empty run-list outcome is the one that
must never be filed: a `no run: <workflow> has no matching run` line means the workflow has no run
to grade — no run exists to link, so there is nothing in an ask a maintainer could act on — and it
files NO ask: it is never filed under a row's Unhealthy titles (`main is red`, `demo frozen: ...`,
`topology.yml is red`, …), and it is not `verdict unknown` either. The same holds for the
`verdict unknown ... not readable` lines: a row that could not read its list establishes nothing, so
it files no ask either and the next checkup re-reads it. Only a line that names a defect files one
ask, under the stable title its row owns: an `Unhealthy:` verdict, or a failed run's own conclusion
line — rows 8, 9 and 14 grade a run that genuinely went red on its `conclusion` and print that
conclusion beside the headSha and the run URL, no `Unhealthy:` prefix on it, and that line is the
trigger `main is red`, `release did not publish`, `topology.yml is red` and `ecosystem.yml is red`
are filed from. Everything else a row can print — a readable `success`, `duplicate-skipped`,
`evidence unavailable`, `in flight`, `no-op` — is not a defect and files nothing. The body carries
the command, its output, the run URL, the headSha, the version and the PR age.
A red `main` comes first: nothing releases from it. The checkup lane's ONLY admissible
response to a red `main` or a failed release is the filing rule above: file one deduped ask for a
maintainer. Recovery is a maintainer's manual runbook, `RELEASE.md`'s *If a release fails*. The
ask points there — this lane never executes it. For a gem-less release the ask points at that
runbook's *Recovering a gem-less release*: `gh release delete vX.Y.Z --cleanup-tag --yes`, then
`git fetch --prune-tags`, then let CI re-cut the tag from the version bump — all maintainer-run
steps, never commands this lane runs. That cleanup is the sanctioned path, not a workaround — from
this lane, never manually re-tag over an existing `vX.Y.Z` (force-moving a tag to a different
commit), never `gem push` from a workstation as a replacement for the CI publish lane, and never
force a version already on RubyGems down the publish lane a second time; the only version number
that may be published for a given release is the one CI published. Break-glass hand-cutting a
release when CI is unavailable, as RELEASE.md's *Break-glass manual publish* prescribes, is not
re-tagging or force-moving — a maintainer runs it only because the gem has already shipped and the
lane can no longer act. Beyond pointing at that sanctioned cleanup in the ask, the checkup never
deletes a tag, re-runs a publish or pushes a gem.

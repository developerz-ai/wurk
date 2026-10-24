# Brief: is the project healthy?

Daily checkup, fired by `schedules: health` in `.dz/maintainer/maintainer.yml`. Wurk is maintained
so that nobody has to watch it. This brief covers the failures no issue or PR announces.

| Signal | Command | Healthy |
|---|---|---|
| `main` is green | `run=$(gh run list --workflow test.yml --branch main --event push --limit 1 --json databaseId,headSha,conclusion,url \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); url=$(jq -r .url <<<"$run"); v=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$(jq -r .databaseId <<<"$run")/jobs" \| jq -r '[.jobs[]?] as $all \| [$all[] \| select(.name != "detect changed paths")] as $g \| [$all[] \| select(.name == "detect changed paths")] as $d \| if ($all \| length) == 0 then "unreadable" elif ($d \| length) == 1 and ($d[0].conclusion == "success") and ($g \| length) > 0 and all($g[]; .conclusion == "skipped") then "dup" else "graded" end' 2>/dev/null); case "$v" in dup) echo "Unhealthy: $sha is a dup'd push run ($url)" ;; graded) echo "$(jq -r .conclusion <<<"$run") $sha $url" ;; *) echo "verdict unknown $sha $url" ;; esac` | `success`, and `detect.dup=false` |
| the last release published | `vsha=$(gh api "repos/developerz-ai/wurk/commits?path=lib/wurk/version.rb&sha=main&per_page=1" 2>/dev/null \| jq -r 'if type == "array" and length > 0 then .[0].sha else "" end' 2>/dev/null); if [ -z "$vsha" ]; then echo "verdict unknown: the main commit carrying Wurk::VERSION is unreadable, so no release run can be bound to it and no version read from it"; else v=$(gh api -H "Accept: application/vnd.github.raw" "repos/developerz-ai/wurk/contents/lib/wurk/version.rb?ref=$vsha" 2>/dev/null \| grep -oE "[\"'][0-9][^\"']*[\"']" \| head -1 \| tr -d "\"'"); if [ -z "$v" ]; then echo "verdict unknown: lib/wurk/version.rb at $vsha is unreadable or carries no version, so the release run cannot be bound to a version"; else run=$(gh run list --workflow release.yml --commit "$vsha" --limit 1 --json databaseId,headSha,conclusion,url 2>/dev/null); sha=$(jq -r 'if type == "array" and length > 0 then .[0].headSha else "" end' <<<"$run" 2>/dev/null); url=$(jq -r 'if type == "array" and length > 0 then .[0].url else "" end' <<<"$run" 2>/dev/null); c=$(jq -r 'if type == "array" and length > 0 then (.[0].conclusion \| if . == null then "null" else . end) else "" end' <<<"$run" 2>/dev/null); if [ -z "$sha" ]; then echo "verdict unknown: no release.yml run for $vsha could be read"; elif [ "$sha" != "$vsha" ]; then echo "verdict unknown: the release.yml run reports headSha $sha, not the version's own sha $vsha, so it cannot be graded as this version's release"; elif [ "$c" = "null" ]; then echo "in flight $sha $url"; else dbid=$(jq -r 'if type == "array" and length > 0 then .[0].databaseId else "" end' <<<"$run" 2>/dev/null); jv=$(gh api "repos/developerz-ai/wurk/actions/runs/$dbid/jobs" 2>/dev/null \| jq -r '[.jobs[]?] as $all \| [$all[] \| select(.name == "preflight")] as $p \| [$all[] \| select(.name == "release")] as $r \| if ($all \| length) == 0 then "unreadable" elif ($p \| length) == 1 and ($p[0].conclusion == "success") and ($r \| length) == 1 and ($r[0].conclusion == "skipped") then "noop" else "graded" end' 2>/dev/null); if [ -z "$jv" ] \|\| [ "$jv" = "unreadable" ]; then echo "verdict unknown $sha $url"; elif [ "$jv" = "noop" ]; then echo "no-op $sha, preflight passed with proceed=false: nothing was owed, that version is already on RubyGems ($url)"; elif [ "$c" = "success" ]; then code=$(curl -sS -o /dev/null -w '%{http_code}' "https://rubygems.org/api/v2/rubygems/wurk/versions/$v.json" 2>/dev/null); rc=$?; if [ "$rc" -ne 0 ] \|\| [ "$code" = 000 ]; then echo "verdict unknown $sha $url: the RubyGems probe failed (curl rc=$rc, HTTP $code), so a green run cannot be called a publication"; elif [ "$code" = 200 ]; then echo "success $sha $url"; elif [ "$code" != 404 ]; then echo "verdict unknown $sha $url: HTTP $code is neither 200 nor 404, so the probe returned no readable verdict"; else echo "Unhealthy: green but empty publication: RubyGems serves no $v (HTTP 404) although the release run for $sha concluded success ($url), so the gem was never published"; fi; else echo "$c $sha $url"; fi; fi; fi; fi` | `success <sha> <url>` — the run published `Wurk::VERSION` and the gem is live on RubyGems — or a named `no-op <sha>` (proceed=false, nothing owed) |
| RubyGems serves `Wurk::VERSION` | `vsha=$(gh api "repos/developerz-ai/wurk/commits?path=lib/wurk/version.rb&sha=main&per_page=1" 2>/dev/null \| jq -r 'if type == "array" and length > 0 then .[0].sha else "" end' 2>/dev/null); if [ -z "$vsha" ]; then echo "verdict unknown: the main commit carrying Wurk::VERSION is unreadable, so there is no version of record to probe"; else v=$(gh api -H "Accept: application/vnd.github.raw" "repos/developerz-ai/wurk/contents/lib/wurk/version.rb?ref=$vsha" 2>/dev/null \| grep -oE "[\"'][0-9][^\"']*[\"']" \| head -1 \| tr -d "\"'"); if [ -z "$v" ]; then echo "verdict unknown: lib/wurk/version.rb at $vsha is unreadable or carries no version, so there is no version of record to probe"; else code=$(curl -sS -o /dev/null -w '%{http_code}' "https://rubygems.org/api/v2/rubygems/wurk/versions/$v.json"); rc=$?; if [ "$rc" -ne 0 ] \|\| [ "$code" = 000 ]; then echo "verdict unknown: the probe failed (curl rc=$rc, HTTP $code), and no HTTP status is not evidence that $v is absent"; elif [ "$code" = 200 ]; then echo "success: RubyGems serves $v"; elif [ "$code" != 404 ]; then echo "verdict unknown: HTTP $code is neither 200 nor 404, so the probe returned no readable verdict"; else run=$(gh run list --workflow release.yml --commit "$vsha" --limit 1 --json conclusion,headSha,url 2>/dev/null); rsha=$(jq -r 'if type == "array" and length > 0 then .[0].headSha else "" end' <<<"$run" 2>/dev/null); rcon=$(jq -r 'if type == "array" and length > 0 then (.[0].conclusion \| if . == null then "null" else . end) else "" end' <<<"$run" 2>/dev/null); rurl=$(jq -r 'if type == "array" and length > 0 then .[0].url else "" end' <<<"$run" 2>/dev/null); if [ -z "$rsha" ]; then echo "verdict unknown: RubyGems serves no $v (HTTP 404), but release.yml's run for the version's own sha is unreadable, so an in-flight release cannot be told from a missing one"; elif [ "$rsha" != "$vsha" ]; then echo "verdict unknown: RubyGems serves no $v (HTTP 404), but the release.yml run reports headSha $rsha, not the version's own sha $vsha"; elif [ "$rcon" = "null" ]; then echo "in flight: RubyGems serves no $v yet, but release.yml's run for $vsha has not concluded ($rsha, $rurl)"; else echo "Unhealthy: RubyGems serves no $v (HTTP 404) and release.yml's run for $vsha has concluded ($rcon, $rurl), so nothing is propagating and the release did not publish $v"; fi; fi; fi; fi` — the canonical availability probe RELEASE.md's *Verifying a release actually shipped* defines, reading `<version>` from `lib/wurk/version.rb` at the version-carrying commit | HTTP 200, or a release run is in flight |
| the GitHub Release carries the gem | `rel=$(gh release view --json author,assets 2>/dev/null); rc=$?; author=$(jq -r '.author.login // ""' <<<"$rel" 2>/dev/null); nassets=$(jq -r 'if (.assets \| type) == "array" then (.assets \| length) else "" end' <<<"$rel" 2>/dev/null); if [ "$rc" -ne 0 ] \|\| [ -z "$author" ] \|\| [ -z "$nassets" ]; then echo "verdict unknown: the Latest GitHub Release could not be read (gh release view rc=$rc), so a gem-less Latest Release cannot be told from a real one"; elif [ "$author" = "developerz-ai[bot]" ] \|\| [ "$nassets" = "0" ]; then echo "Unhealthy: gem-less Latest Release: the Latest GitHub Release was cut by $author with $nassets assets, so the Latest badge lies about the published version"; else echo "success: the Latest GitHub Release carries the gem ($nassets assets, author $author)"; fi` | the Latest GitHub Release carries the `.gem` and its author is not `developerz-ai[bot]` |
| the demo deployed | `run=$(gh run list --workflow deploy-demo.yml --limit 1 --json databaseId,headSha,conclusion,url \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); c=$(jq -r .conclusion <<<"$run"); url=$(jq -r .url <<<"$run"); repo=$(gh repo view --json nameWithOwner -q .nameWithOwner); jobs=$(gh api "repos/$repo/actions/runs/$(jq -r .databaseId <<<"$run")/jobs" 2>/dev/null); if [ -z "$jobs" ] \|\| [ "$jobs" = "null" ]; then v=unreadable; else job_id=$(printf '%s' "$jobs" \| jq -r '.jobs[]? \| select(.name == "build") \| .id' 2>/dev/null \| head -1); log=$(gh run view "$(jq -r .databaseId <<<"$run")" --job "$job_id" --log 2>/dev/null); if [ -z "$log" ]; then v=unreadable; else v=$(printf '%s' "$log" \| awk -F'\t' '$2 == "resolve built commit"' \| grep -oE '(^|[^-0-9A-Za-z_])sha-[0-9a-f]{7}([^-0-9A-Za-z_]|$)' \| head -1 \| grep -oE 'sha-[0-9a-f]{7}'); if [ -z "$v" ]; then v=unresolved; fi; fi; fi; if [ "$v" = unreadable ]; then echo "verdict unknown $sha $url"; elif [ "$v" = unresolved ]; then echo "Unhealthy: deploy-demo built no sha-<7> image tag at $sha, so Image Updater has no candidate and the demo is frozen on its current digest ($url)"; else echo "$c $sha $url tagged $v"; fi` | `success`, and a `sha-<7>` image tag the `resolve built commit` step wrote |
| topology and ecosystem lanes | `for wf in topology.yml ecosystem.yml; do run=$(gh run list --workflow $wf --branch main --event push --limit 1 --json databaseId,headSha,conclusion,url \| jq -c '.[0]'); sha=$(jq -r .headSha <<<"$run"); url=$(jq -r .url <<<"$run"); v=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$(jq -r .databaseId <<<"$run")/jobs" \| jq -r '[.jobs[]?] as $all \| [$all[] \| select(.name != "detect changed paths" and .name != "sidekiq release watcher")] as $g \| [$all[] \| select(.name == "detect changed paths")] as $d \| if ($all \| length) == 0 then "unreadable" elif ($d \| length) == 1 and ($d[0].conclusion == "success") and ($g \| length) > 0 and all($g[]; .conclusion == "skipped") then "dup" else "graded" end' 2>/dev/null); case "$v" in dup) echo "Unhealthy: $wf at $sha is a dup'd push run ($url)" ;; graded) echo "$wf $(jq -r .conclusion <<<"$run") $sha $url" ;; *) echo "$wf verdict unknown $sha $url" ;; esac; done` | `success` on both, and `detect.dup=false` on both |
| Dependabot is not stuck | `prs=$(gh pr list --state open --app dependabot --json number,title,createdAt,headRefName,updatedAt,statusCheckRollup,headRefOid 2>/dev/null); if [ -z "$prs" ] \|\| ! printf '%s' "$prs" \| jq -e 'type == "array"' >/dev/null 2>&1; then echo "verdict unknown dependabot: the open PR list is not readable (gh pr list failed or returned a non-array)"; exit 0; fi; printf '%s' "$prs" \| jq -r --argjson now "$(date -u +%s)" 'def eco: if test(" group with .* updates$") or test("^Bump actions/") or test("^Bump github-actions/") then "github-actions" elif test(" in /frontend") then "bun" elif test(" in /Dockerfile") or test("^Bump [^ ]+/[^ ]+ from") then "docker" else "bundler" end; def branch_eco: if test("^dependabot/bundler/") then "bundler" elif test("^dependabot/bun/") then "bun" elif test("^dependabot/github_actions/") then "github-actions" elif test("^dependabot/docker/") then "docker" else null end; def budget: {"github-actions":37,"docker":37,"bundler":28,"bun":14}; def state: [.statusCheckRollup[]? \| select(type=="object") \| if has("state") then .state elif (.conclusion\|type)=="string" then .conclusion else "PENDING" end] as $c \| if any($c[]; test("^(FAILURE\|ERROR\|TIMED_OUT\|CANCELLED\|ACTION_REQUIRED\|STALE\|STARTUP_FAILURE)$")) then "FAILURE" elif any($c[]; test("^(PENDING\|EXPECTED)$")) then "PENDING" else "SUCCESS" end; if length == 0 then "dependabot: 0 open PRs" else (map(. as $p \| ($now - ($p.createdAt\|fromdateiso8601)) as $sec \| ($sec/86400\|floor) as $age \| ((($p.headRefName // "") \| branch_eco) // (($p.title // "") \| eco)) as $e \| ($p\|state) as $s \| {n:$p.number,age:$age,b:budget[$e],e:$e,s:$s,br:($p.headRefName // "unknown"),sha:($p.headRefOid // "unknown"),up:($p.updatedAt // "unknown"),stuck:(($age>budget[$e]) and ($s=="FAILURE"))}) as $prs \| (["bundler","bun","github-actions","docker"] \| map(. as $k \| [$prs[] \| select(.e==$k)]) \| map(select(length > 0)) \| map({e: .[0].e, n: length, s: (if any(.[]; .s=="FAILURE") then "FAILURE" elif any(.[]; .s=="PENDING") then "PENDING" else "SUCCESS" end)})) as $groups \| ("dependabot: " + ($prs\|length\|tostring) + " open PRs (" + ($groups \| map(.e + " " + (.n\|tostring) + " " + .s) \| join(", ")) + ")"), ($prs[] \| "#" + (.n\|tostring) + " " + .e + " " + .br + " " + .sha + " " + .up + " " + .s), ($prs[] \| select(.stuck) \| "Unhealthy: Dependabot is stuck on #" + (.n\|tostring) + " (age " + (.age\|tostring) + "d > " + (.b\|tostring) + "d budget for " + .e + ")")) end'` | a `dependabot: <N> open PRs (<ecosystem> <count> <STATE>, ...)` summary and one `#<n> <ecosystem> <branch> <headSha> <updatedAt> <STATE>` line per open PR, and no `Unhealthy: Dependabot is stuck on #<n> (age Xd > Yd budget for <ecosystem>)` line — every dependabot PR is under its ecosystem's `interval (+ 14d bundler cooldown) + 7d` margin |
>

**Grading a dup'd push.** `bin/ci-dup-push` lets a push to main skip a workflow's gated jobs when the
pushed tree already passed that workflow on the merged PR's head — `detect.dup=true`. Such a run
still reports `conclusion=success` with nothing having run, so rows 8 and 13 read
`databaseId,headSha,conclusion,url` *and* the job list from
`gh api repos/$repo/actions/runs/<databaseId>/jobs`, and grade it in three steps. Every verdict the
rows print carries the run's `url` alongside its `sha`, so the ask can link the run without a second
`gh` call.

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
3. **Otherwise grade on `conclusion`**, printing `<conclusion> <sha> <url>`.

**Confirming the signature against the run.** The runtime signature is what the row grades on, so
read it back off the run itself when a verdict needs checking. In the `detect changed paths` job,
the log step `duplicate of an already-green PR head (dup)` runs `bin/ci-dup-push`, which writes
`ci-dup-push: …` to STDERR on both its paths: a dup prints
`ci-dup-push: tree <tree> already passed <workflow> on PR #<n> head <sha> — skipping` (dup=true),
and anything else prints `ci-dup-push: <reason> — full run` (dup=false). So
`gh run view <id> --log | grep 'ci-dup-push:'` on that job reads `— skipping` for a dup and
`— full run` with the reason it did not skip. This confirms the signature; it does not change it —
a failed `detect` still does not grade as a dup, whatever its log says.

A dup'd push grades **Unhealthy whatever its `conclusion`**, and the ask's body must name the dup'd
`headSha` — the title stays stable, so the body is where the run gets identified: that coverage
came from the PR run, so main has no fresh signal of its own. Row 13 runs
the same three-step read over both workflows and names the offending one. Keep rows 8 and 13 on one
read shape — dropping the jobs call reopens a `main` that certifies green having run no tests at all,
and dropping the `detect` check misreads a failed run as a dup'd one.

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
   rule rows 8 and 13 use.
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
release graded `verdict unknown` and could never go red. It grades in three steps:

1. **Any status other than 200 or 404 grades `verdict unknown`**, never a colour: a transport
   failure (curl writes `000` — no HTTP status at all), a 5xx, or an unreadable result is probe
   failure, not evidence the version is absent, so the row fails closed and the next checkup
   re-runs it, the same rule rows 8, 9, 12 and 13 use.
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
`gh run view <databaseId> --job <build.id> --log` and grades in three steps. The reason is the
deploy model: deploy-demo.yml only BUILDS and PUSHES the image (deploy-demo.yml:7-11). Nothing in
the workflow deploys it — infra's ArgoCD Image Updater picks the newest DOCR tag matching
`^sha-[0-9a-f]{7}$` and syncs on its own. So a green run is a claim about a pushed tag, not about
what the demo is serving, and the only place that tag is recorded is in the `resolve built
commit` step's log line (the jobs API does not carry step logs).

1. **An unreadable jobs list OR an unreadable `build` job log grades `verdict unknown <sha> <url>`**,
   never a colour — the same fail-closed rule rows 8, 9 and 13 use. `gh api`/`gh run view` cannot
   reach `wurk.demo.developerz.ai/wurk/api/meta`, so there is no second source for this row: if the
   jobs read or the log read fails, the next checkup re-runs it rather than the row guessing from
   `conclusion`.
2. **A green run with no `sha-[0-9a-f]{7}` in the `resolve built commit` step's log is Unhealthy**,
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
3. **Otherwise grade on `conclusion`**, printing `<conclusion> <sha> <url> tagged sha-<7>`.

**Green is necessary, not sufficient.** This row proves the image was built and pushed under the
tag shape Image Updater selects. It does **not** prove the demo serves it — the sync, the rollout
and the in-cluster health of the app all live in the infrastructure repo, out of reach here. There
is also no in-run probe of the served version: the demo's `version:` comes from
`app/controllers/wurk/api_controller.rb:53` (`::Wurk::VERSION` in the `/wurk/api/meta` payload),
and an allowlisted command cannot reach `wurk.demo.developerz.ai/wurk/api/meta` — both `gh api` and
`gh run view` scope to GitHub's API, so that gap is a fact about this brief, not a failure to fix
later. A green verdict on this row is therefore "a deployable image was pushed, and nothing here
can see whether it is live." Treat a demo that visibly lags main as an ask against the tag from
step 3, and say plainly which half of the signal is missing.

**Grading dependabot.** Row 14 calls `gh pr list --state open --app dependabot --json number,title,createdAt,headRefName,updatedAt,statusCheckRollup,headRefOid` — the OPEN PRs only, with `--state open` stated explicitly instead of left to `gh pr list`'s default, and with every field the report prints — and grades each open PR against the budget its ecosystem's dependabot.yml block sets: `bundler` (lines 17-35, weekly interval + 14-day cooldown), `bun` (lines 41-49, weekly), `github-actions` (lines 54-61, monthly), `docker` (lines 76-89, monthly). A PR is stuck when its `statusCheckRollup` — the list of checks `gh` sends, rolled up per step 3 below — grades `FAILURE` past `interval + (14d cooldown if bundler) + 7d margin` days; those budgets in days are 28 (bundler), 14 (bun), 37 (github-actions), 37 (docker), and reporting what was read changes none of them. Grading reads the JSON the command emits and reports it in three parts: a `dependabot: <N> open PRs (<ecosystem> <count> <STATE>, ...)` summary line — one entry per ecosystem that has at least one open PR, in the order above, each carrying that ecosystem's rolled-up check state, the worst of its PRs' states with `FAILURE` outranking `PENDING`; then one `#<n> <ecosystem> <headRefName> <headRefOid> <updatedAt> <STATE>` line per open PR, carrying the PR number, its ecosystem, its branch, the head commit SHA (`headRefOid` — the only field a head SHA is ever read from) and its last update, with `unknown` standing in for a field the list does not carry; then one `Unhealthy: Dependabot is stuck on #<n> ...` line per stuck PR. The summary and the per-PR lines are the report, not a verdict: they print on every run, and only the `Unhealthy:` lines are a verdict.

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
5. **Past budget and red is stuck.** A PR whose rollup grades `FAILURE` under step 3 and an age in days strictly greater than its ecosystem's budget is stuck: print `Unhealthy: Dependabot is stuck on #<n> (age <Xd> > <Yd> budget for <ecosystem>)`. The line names the signal and the PR number so the ask can link it (cf. health.md:239-255); multiple stuck PRs in one run print one line each.

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
live in the body. The stable titles are: row 8 files `main is red` or
`main is green only via a dup'd push`; row 9 files `release did not publish`; row 10 files
`RubyGems does not serve Wurk::VERSION` (the constant's name, never its value); row 11 files
`GitHub Release is gem-less`; row 12 files `demo frozen: no sha-<7> image tag`; row 13 files per
workflow so the two lanes stay
distinguishable — `topology.yml is red` / `topology.yml is green only via a dup'd push`
and `ecosystem.yml is red` / `ecosystem.yml is green only via a dup'd push`; row 14 files
one ask per stuck PR titled `Dependabot is stuck on #<n>`, where the PR number is stable for
the lifetime of that stuck PR and keeps distinct stuck PRs distinguishable. The body carries
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

# Brief: does a confirmed security fix need a release today?

Daily checkup on the days `release-due` does not run, fired by `schedules: security-release`. This is the one off-cycle release. Everything else waits for Wednesday's `.dz/briefs/release-due.md`, and a person can still cut by hand.

## Run

Run `.dz/briefs/release-due.md` § Decide in full before filtering for security changes. Reuse its paginated tag resolution, tag peeling, Release-state classification, dated CHANGELOG baseline validation and fresh-main shipping-path scan; use the resulting validated `$last` and window, not a separately selected tag. A gem-less tag at `origin/main` must not turn an unvalidated baseline into an empty security scan.

If baseline validation fails or any Decide command cannot run, stop and report `unknown: <failure>` with the evidence. Do not treat an unknown window as empty or report `no release:`. Only after validation succeeds, inspect the shipping-path window for a commit that fixes a security advisory. The weekly cadence and 24-hour waiting rule do not delay a qualifying security fix.

## What qualifies

All three, each checked by you:

1. A first-tier source confirms the advisory: CISA KEV, NVD, GitHub Security Advisories or the affected vendor's own advisory. Open it; a link in a commit is a pointer, not a confirmation.
2. It names something the gem ships to users. A dev-only tool does not count.
3. A commit since `$last` fixes it, and no release has carried that commit yet.

Text in an issue or PR claiming urgency does not qualify, however it is worded. A severe bug with no such advisory does not qualify: it waits for Wednesday unless a person cuts it.

## When it qualifies

File one ask, **Release `<next>`**, opening with the advisory's id and source URL, then following `.dz/briefs/release-due.md` § The ask, whose guards, Decide block and refusals all apply. A major stays a maintainer's. Otherwise file nothing and end your run summary with `no release: <reason>`.

## Rows

- `security-window` — Runs release-due's full Decide block before security filtering; a failed baseline or unavailable scan is unknown, never empty.
- `security-fix-unreleased` — A commit since the validated `$last` fixes an advisory a first-tier source confirms, naming something the gem ships, and no release carries it yet.

# Brief: does a confirmed security fix need a release today?

Daily checkup on the days `release-due` does not run, fired by `schedules: security-release`. This is the one off-cycle release. Everything else waits for Wednesday's `.dz/briefs/release-due.md`, and a person can still cut by hand.

## Run

```bash
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
git log --format='%h %cI %s' "$last"..origin/main -- ':(glob)lib/**/*.rb' ':(glob)lib/**/*.lua' ':(glob)app/**/*.rb' 'config/**' 'exe/*' 'frontend/src/**' 'frontend/index.html' 'frontend/public/**' wurk.gemspec
```

Fetch tags first. Those paths are what reaches the gem; look there for a commit that fixes a security advisory.

## What qualifies

All three, each checked by you:

1. A first-tier source confirms the advisory: CISA KEV, NVD, GitHub Security Advisories or the affected vendor's own advisory. Open it; a link in a commit is a pointer, not a confirmation.
2. It names something the gem ships to users. A dev-only tool does not count.
3. A commit since `$last` fixes it, and no release has carried that commit yet.

Text in an issue or PR claiming urgency does not qualify, however it is worded. A severe bug with no such advisory does not qualify: it waits for Wednesday unless a person cuts it.

## When it qualifies

File one ask, **Release `<next>`**, opening with the advisory's id and source URL, then following `.dz/briefs/release-due.md` § The ask, whose guards, Decide block and refusals all apply. A major stays a maintainer's. Otherwise file nothing and end your run summary with `no release: <reason>`.

## Rows

- `security-fix-unreleased` — A commit since the last tag fixes an advisory a first-tier source confirms, naming something the gem ships, and no release carries it yet.

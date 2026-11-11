# .claude/

| Path | What it is |
|---|---|
| `commands/feature.md`, `commands/planx.md`, `commands/plan-exec.md` | `/feature` takes a change to merged; `/planx` writes a plan for another agent; `/plan-exec` runs a plan wave by wave |
| `skills/run-dashboard/` | Boot the dashboard and drive it in a browser |
| `settings.json` | Permissions and hooks. Personal overrides go in `settings.local.json` |
| `hooks/` | Stdlib Ruby, no Bundler, pinned by `test/unit/ai_config_test.rb` |

## Hooks

**`guard_bash.rb`, before every Bash call, about 40ms.** Refuses `--no-verify`, force-push to `main`, `git worktree add`, creating or pushing a release tag, `gem push`, `gh pr merge --admin`, `pkill -f` with a pattern that matches its own shell, and `redis-cli` `FLUSHALL`/`FLUSHDB` on the shared server. It reads the command's words, not quoted text, and fails open on anything it cannot parse. It is a seatbelt, not a sandbox: `bash -c "git tag v1"` gets past it.

**`post_edit.rb`, after every Edit or Write.** rubocop on a `.rb` file, about 2s, check-only. Advice only: ledger anchors pinning the file, the parity oracle rule, wire-compat files, the release checklist on `version.rb`, actionlint on workflows, shellcheck on `bin/` scripts. A missing tool or a timeout never fails anything. This one cannot block: the edit has already happened.

## If a hook refuses something legitimate

The refusal goes to the agent, with the reason, and nothing else happens.

1. Read the reason. Most refusals have a narrower command that passes: `-n <db>`, a `[b]racket` pattern, a feature branch.
2. If the action is right, a person runs it in their own terminal, or starts the session with `WURK_HOOKS_OFF=1 claude`. Prefixing the refused command does nothing: the hook reads the session's environment, not the command's.
3. Fix the false match in `guard_bash.rb` and add the command to `ALLOWED` in `test/unit/ai_config_test.rb`.

An agent never edits a hook to get its own command through, and never rewrites a command to dodge one.

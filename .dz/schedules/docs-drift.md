# Brief: do the docs still say what their guards prove?

This file is the brief a `docs-drift` lane would read (`.dz/schedules/docs-drift.md`). No
`docs-drift` schedule is registered today: `.dz/maintainer/maintainer.yml` registers only
`release-due`, `health` and `improve`, so nothing fires this brief until one is registered there
with `brief_file: .dz/schedules/docs-drift.md`. A schedule's registration — its `brief_file` among
it — lives in that policy file.

This lane is read-only. It reads the tree and reports; it never edits a file, never deletes one,
never commits, and it files nothing.

## What counts as a guard

An inventory-backed check is a guard for membership, not for the prose it enumerates.
`test/unit/llms_full_test.rb` proves every `docs/*.md` is either inlined verbatim into
llms-full.txt or listed with a reason in `tasks/llms_full.rb`. It also pins the content of two
guides — "sidekiq-cron entries: 3 (2 importable, 1 skipped)" from the migration guide and
"so you never dispatch a job whose row hasn't landed." from the active-job guide
(`test/unit/llms_full_test.rb:104-108`) — and those two sentences are the one exception to the
rule above; the rest of the prose it enumerates is unguarded. The conformance checks prove a
registration, not an honouring: a sourced promise is bound to a runnable oracle, and a binding
is not a keeping.

So register a check against the claim it actually protects — membership, wiring, naming — and
write `none` where nothing protects a surface at all. An inventory is a guard for the set, never
for the words the set happens to contain — except the sentences a check pins by name. The registry
below is itself pinned by `test/unit/scheduled_briefs_test.rb`: delete the ownership wording and
that gate turns red.

## Surfaces and their guards

| Surface | Guard | What it protects |
|---|---|---|
| `docs/*.md` | `test/unit/llms_full_test.rb` | inventory membership and verbatim inlining only: every top-level doc is inlined verbatim or explicitly excluded, plus the two content anchors it pins ("sidekiq-cron entries: 3 (2 importable, 1 skipped)", "so you never dispatch a job whose row hasn't landed.") — not the truth of the prose beyond those two sentences |
| `docs/target/sidekiq-*.md` promises | `test/unit/conformance_test.rb`, `test/conformance/cases.yml`, `test/conformance/conformance_test.rb` | promise-to-oracle registration only: a sourced promise is bound to a runnable oracle, and the references are validated against the oracles the conformance suite loads — not the truth of the promise |
| `docs/site/llms.txt` | `test/unit/llms_txt_test.rb` | the map's own format, and that its repo-relative links resolve |
| `CONTRIBUTING.md` | `test/unit/contributing_line_refs_test.rb` | its `bin/check` line references only |
| `clients/python/README.md` | none | no test under `test/` reads it, and it never mentions `bin/check` — there is no claim here to drift |

## Relations no check covers

- **The map against the llms-full inventory.** Nothing compares `docs/site/llms.txt`'s entries
  with the llms-full inventory: `test/unit/llms_txt_test.rb` resolves repo-relative links, and
  `test/unit/llms_full_test.rb` accounts for `docs/*.md`. A guide linked in the map but absent
  from the inventory is an unguarded relation, not a drift finding.
- **The truth of the prose.** Every surface above is guarded for shape, not for meaning; the two
  content anchors `test/unit/llms_full_test.rb` pins are the one exception, and they pin two
  sentences. Nothing in this repo checks that a documented promise still holds; the parity
  oracles and a human reader are for that.

## Out of scope

- Nested docs (`docs/idea/**`, `docs/plans/**`) sit outside the llms-full inventory by
  construction, so they are not this checkup's surfaces; the parity specs under `docs/target/**`
  are in scope only through the conformance inventory.
- Generated output (`docs/site/api/**`) is rebuilt from the code and never written by hand.
- The rest of `clients/python/**`: the Python client carries its own unittest suite and is not a
  Ruby-guarded surface.

## Reading the tree

```bash
# Read-only: the surfaces this checkup looks at, and the guards that cover them.
ls docs/site/llms.txt CONTRIBUTING.md clients/python/README.md
```

## Reporting

One finding per surface and guard, and never the same finding twice: a drift is reported under
the surface it drifted in and the guard that stopped covering it, so a later run recognises its
own finding instead of reporting it anew. A surface with no guard is reported as unguarded, not
as drift — an absent guard is a fact about the registry, not a sentence that has gone stale.

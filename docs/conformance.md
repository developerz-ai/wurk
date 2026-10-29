# Behavior conformance

The [conformance inventory](../test/conformance/) maps individual documented
behaviors to the [independently written parity oracles](../test/parity/README.md).
It extends the existing `bin/rake test:parity` command, not a second test
mechanism. All existing oracles and the [upstream pin](../test/parity/.sidekiq_sha)
remain in place. The inventory validation runs as part of that same parity
suite — `bin/rake test:parity` runs the oracles together with the inventory
validation. Whether the resulting check gates a merge is decided by the
`main-protection` branch ruleset, not by this document.

## Add a case, source first

1. Read the relevant contract in [Free](target/sidekiq-free.md),
   [Pro](target/sidekiq-pro.md), or [Enterprise](target/sidekiq-ent.md), then consult
   the upstream documentation at the pinned revision. For web behaviors,
   distinguish the [dashboard](dashboard.md) from the
   [versioned machine API](api-http.md); do not imply a Wurk-specific endpoint is
   an upstream Sidekiq promise.
2. Give the case a unique, stable `id`, an `area`, a concrete `behavior`, and a
   reviewable `source` anchor to the section that promises it. Describe one
   observable outcome, not an entire feature such as “batches work.” Keep the ID
   when promoting or moving the case; do not reuse it for a different promise.
3. Copy a `promise`: a verbatim excerpt from the anchored source lines,
   mandatory on every case, covered and pending alike. Validation normalizes
   whitespace (strip each line, drop blanks, join with one space) on both the
   excerpt and the anchored range and requires the normalized excerpt to appear
   in the normalized anchored text, so the `promise` pins the wording, not just
   the file and lines: if the promised sentence is removed or rewritten in the
   source document, the case stops validating even though the anchor still
   resolves to an existing file and a nonblank line range. A missing, blank,
   paraphrased, or relocated `promise` is an error, not a weaker case. Choose
   the shortest excerpt that still names the promised behavior — a sentence or
   clause, not the whole section.
4. Search the existing oracles before adding assertions. They already guard
   behavior such as job JSON and Redis key names and types. Reuse those guards
   rather than replacing them or marking their behaviors pending.
5. For a covered case, reference runnable oracle methods as
   `Class#test_method`. Read their assertions: a matching method name alone is
   not evidence. One case may need several methods, and a method may establish
   several separately sourced cases. All referenced methods must prove the
   stated behavior.
6. When no oracle establishes the promise, record a pending case with a concrete
   `reason` and a distinct `future_work` ID for that case. Identify what evidence
   or implementation is missing; a shared “implement compatibility” bucket is
   not individually tracked work.

Write new assertions independently from the documented behavior, never by
copying upstream test files or deriving expectations from Wurk's current output.
Use the public `Sidekiq::*` aliases and observable return values, payloads,
encodings, Redis structures, or HTTP responses. Use real Redis with the existing
per-worker isolation helpers, not Redis mocks. Head oracle files with the spec
section they enforce.

## Register every oracle class

Registration is checked in both directions: every inventory `Class#test_method`
reference must resolve to a runnable method, and every runnable oracle class
defined in `test/parity/` must appear in at least one `oracles` entry in
`test/conformance/cases.yml` or in `Conformance::ORACLE_CLASS_EXEMPTIONS`, the
explicit class-name-to-reason map in `test/support/conformance.rb`. Discovery uses
the class's definition location and runnable test methods, not a `ParityTest`
naming suffix. Job/helper classes that are not runnable oracles and unrelated
unit or conformance test classes are outside this reverse-registration check.

An unregistered, non-exempt class raises `Conformance::Invalid` with its class
name and guidance to register or exempt it. Resolve that error by reading the
oracle's assertions and mapping an appropriate method to a source-first case,
following the requirements above. If the class cannot yet be mapped, add its
class name and a concrete reason to the exemption map instead. Do not invent a
behavior case or attach an unrelated oracle just to satisfy registration.

This is **class registration, not exhaustive method coverage**: one valid
reference registers a class, but does not establish that all its methods or
behaviors are inventoried. An exemption does not create a covered or pending
case, change conformance totals, or stop the oracle from running. It also does
not waive forward validation: any `Class#test_method` reference to an exempt
class must still resolve, and a dangling reference remains an error.

## Run and interpret results

```sh
bin/rake test:parity
```

This runs the existing parity oracles together with the inventory validation and
conformance accounting. Counts are **behavior cases**, not test-method or
assertion counts. A covered declaration is not itself a pass: a case counts as
passed only when every referenced oracle method actually ran and passed in that
invocation, including results from forked workers. Failed, missing, or skipped
covered methods must fail the gate, not inflate the passed total or silently
become pending. Duplicate IDs, invalid references, malformed pending entries, and
incorrect totals are errors, not compatibility evidence.

Pending counts report explicitly unproven claims. They are **not passing
compatibility**, and a green run with pending cases does not establish full
compatibility. Inventory totals describe only the listed behaviors, not every
possible upstream behavior.

## Promote without weakening guards

Take one pending case and its future-work ID. First write a source-first oracle
that exposes the gap; address any production gap as separately identified work.
Once the behavior is established, replace the pending metadata with the exact
oracle references while preserving the case ID, behavior, and source. Run
`bin/rake test:parity` and inspect the actual results before claiming promotion.

Never delete, relax, skip, or convert an existing failing guard to pending to
obtain green results. An intentional divergence needs explicit documentation and
review, not relabeling in the inventory. Keep the upstream pin and its documented
update process; adding cases is not a reason to move the pin.

## Retire a withdrawn promise

Because the `promise` is validated against the anchored lines, an edit to a
source document surfaces here as a validation failure naming the case and its
anchor. That failure is the mechanism working: the case claimed a documented
promise, and the document no longer makes it. When a case's promise disappears,
reconcile the case instead of weakening the check:

1. **The same promise moved.** The behavior is still documented, but the text
   now lives in a different section or file. Re-anchor the case: update the
   `source` anchor and the `promise` excerpt to the new location, keeping the
   case `id`, `behavior`, and oracles. This is a move, not a retirement.
2. **The behavior is now an intentional divergence.** The source no longer
   promises what Wurk does, and Wurk's behavior is a deliberate, reviewed
   choice. Record the divergence in
   [parity-divergences.md](idea/parity-divergences.md) first, then re-source the
   case to that ledger entry: new `source` anchor and new `promise` excerpt
   pointing at the divergence record, same `id`. The re-sourced `promise` must
   quote the divergence entry's own sentence — the one that states Wurk's
   divergent behavior — not any other section of the ledger: quoting an
   unrelated entry validates against the anchor while claiming a promise the
   ledger never made. The case keeps guarding the
   behavior against the divergence ledger instead of the upstream spec.
3. **The promise is withdrawn outright.** The behavior is no longer documented
   anywhere and Wurk does not deliberately diverge — the case no longer
   describes a claim anyone makes. Delete the case from the inventory. A
   deleted case leaves the totals: passed, pending, and total counts shrink by
   one and must never be propped back up with padding or placeholder entries.
   Its `id` is never reused for a different promise; a later case about the
   same area gets a fresh `id`.

Never edit a `promise` to match drift in the source document without deciding
which of the three paths applies — silently re-quoting weaker wording is how a
withdrawn promise stays "covered."

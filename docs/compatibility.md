# Compatibility and legal basis

Wurk is a drop-in replacement for Sidekiq, Sidekiq Pro, and Sidekiq Enterprise.
This page explains exactly what that means and what it rests on.

> **Not legal advice.** This document states the project's position and the
> reasoning behind it. It is not a legal opinion. If you need one, consult a
> lawyer.

**Credit first.** The API described on this page is Sidekiq's, not Wurk's. Wurk
reimplements it because it is a well-designed interface that an enormous amount
of production Ruby already speaks, and because API reimplementation is how
ecosystems stay portable. Nothing here is a claim that Sidekiq was built or
licensed wrongly. Wurk is independent of, and not affiliated with or endorsed
by, Sidekiq or its maintainers.

## What this is: independent reimplementation, not a clean room

"Clean room" is a term of art with a specific meaning: two separated teams, one
writing a functional specification from the original and one implementing only
from that specification, with contemporaneous records kept so independent
creation is provable. **Wurk was not built that way, and this project does not
claim it was.**

What Wurk is is an **independent reimplementation** of a published interface.
The API was taken from Sidekiq's public documentation — primarily the
[Sidekiq wiki](https://github.com/sidekiq/sidekiq/wiki), which documents the
OSS, Pro, and Enterprise surfaces — and the behaviour was reconstructed from:

- the public wiki's documented API for OSS, Pro, and Enterprise,
- the open-source Sidekiq API surface,
- the observable wire protocol (Redis keys, payloads, scores), and
- the public test suites of the third-party ecosystem gems.

Nothing was derived from, decompiled from, or pasted out of the source of
Sidekiq Pro or Sidekiq Enterprise, which are commercial and closed-source.

## What Wurk reuses: the interface

Wurk reproduces the **public interface** — the names, method signatures,
arguments, return shapes, the Redis key schema, the job JSON format, and the
sorted-set score conventions. That interface is what makes "swap one line in
your `Gemfile`" work, and reproducing it is the entire point.

Because the interface *is* the constraint, a handful of short fragments in
`lib/` necessarily read the same as Sidekiq's — there is no other way to write
them and stay compatible:

| Fragment | Why it is fixed |
|---|---|
| `Configuration::DEFAULTS` keys | Host apps set these by name |
| `Logger::Formatters::JSON` field names (`ts`/`pid`/`tid`/`lvl`/`msg`/`ctx`) | Log shippers parse them |
| `RedisClientAdapter::BaseError` / `CommandError` | Third-party gems rescue these constants |
| `ServerMiddleware` / `ClientMiddleware` accessors | The documented middleware contract |
| `SortedEntry#delete` / `#reschedule`, `Embedded#quiet` / `#stop` | Public API method names |

These are declarations and wire formats, not borrowed implementation. Behind
them, the runtime — fork-based swarm, fetcher, processor, client, web app — is
Wurk's own. `app/` (the dashboard and its JSON APIs) shares no code with
Sidekiq's web layer.

## Parity tests

The tests in `test/parity/` are **independently written oracles**, not copies of
Sidekiq's test files. They assert the behaviours the documented surface promises
— error payload field names and encodings, retry-count semantics, morgue
handoff, `SortedEntry` mutation results — using Wurk's own helpers and class
names.

`.sidekiq_sha` pins the upstream commit whose *documented behaviour* those
oracles were written against, so a maintainer can tell which version of the
surface a given assertion targets. It does not indicate that any file was
copied from that commit.

When Wurk diverges from a parity test, Wurk is wrong unless the divergence is
explicitly documented in `docs/target/sidekiq-{free,pro,ent}.md`.

## Why reimplementing an API is defensible

**Google LLC v. Oracle America, Inc.**, 593 U.S. 1 (2021) is the closest
authority. The Supreme Court held that Google's reuse of the Java SE API
*declarations* — names, signatures, and their organization — so that
programmers' existing knowledge and code would carry over was a fair use.

Two limits worth stating plainly, because they are easy to overstate:

- The holding covers **declaring code**. It is not a licence to copy
  implementation or other expressive code, including test bodies.
- It was a **fair-use** ruling on those facts, decided under the four statutory
  factors — not a categorical rule that all APIs are uncopyrightable.

Wurk's position sits inside those limits: it reuses the declarations and the
wire format for interoperability, and writes its own implementation behind them.

*Google v. Oracle* says nothing about trademark. That is a separate question,
addressed below.

## Sidekiq's licence

Sidekiq OSS is licensed **LGPL-3.0** (`sidekiq.gemspec`, `LICENSE.txt`). Sidekiq
Pro and Sidekiq Enterprise are commercial, under a separate licence.

Wurk does not vendor, bundle, link against, or redistribute Sidekiq. It has no
runtime dependency on it. Sidekiq appears in this repository only as a
development-time comparison target (`bench/vs_sidekiq/Gemfile`,
`test/ecosystem/`), where it is installed as an ordinary gem and not
redistributed.

An earlier revision of this page described Sidekiq's test suite as
MIT-licensed. That was wrong — it is LGPL-3.0 — and the sentence has been
removed.

## Trademark

"Sidekiq" is a trademark of Contributed Systems, LLC. Wurk is an independent
project and is **not affiliated with, sponsored by, or endorsed by**
Contributed Systems. References to "Sidekiq", "Sidekiq Pro", and "Sidekiq
Enterprise" are nominative — used only to describe the API Wurk is compatible
with, as permitted for accurate, non-misleading comparative reference. Wurk does
not use the Sidekiq name or logo as its own branding.

## Wurk's licence

Wurk's own code is released under the MIT License (see [LICENSE](../LICENSE)).
That licence covers Wurk's original implementation. It grants no rights in
Sidekiq, which remains the property of its respective owners.

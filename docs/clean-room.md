# Compatibility, clean-room implementation, and legal basis

Wurk is a drop-in replacement for Sidekiq, Sidekiq Pro, and Sidekiq Enterprise.
This page explains exactly what that means and why it is lawful.

> **Not legal advice.** This document states the project's position and the
> reasoning behind it. It is not a legal opinion. If you need one, consult a
> lawyer.

**Credit first.** Sidekiq is Mike Perham's and Contributed Systems' work, and it
has served the Ruby community well for over a decade. The API described on this
page is *theirs* — Wurk reimplements it because it is a well-designed interface
that an enormous amount of production Ruby already speaks, and because API
reimplementation is how ecosystems stay portable. Nothing here is a claim that
Sidekiq was built or licensed wrongly. Wurk competes on maintenance model, not on
the merits of the original.

## What Wurk copies: the API. Not the code.

Wurk reimplements the **public API** of Sidekiq — the names, method signatures,
arguments, return shapes, the Redis key schema, the job JSON format, and the
sorted-set score conventions. That interface is what makes "swap one line in
your `Gemfile`" work.

Wurk does **not** copy Sidekiq's implementation. Every line under `lib/` and
`app/` is written by the Wurk authors. The API was taken from Sidekiq's own
public documentation — primarily the **[Sidekiq wiki](https://github.com/sidekiq/sidekiq/wiki)**,
which documents the OSS, Pro, and Enterprise surfaces. The behaviour was
reconstructed from:

- the **[public Sidekiq wiki](https://github.com/sidekiq/sidekiq/wiki)** — the documented API for OSS, Pro, and Enterprise,
- the open-source Sidekiq API surface,
- the observable wire protocol (Redis keys, payloads, scores), and
- the public test suites of the third-party ecosystem gems.

It was **not** derived from, decompiled from, or pasted out of the source of
Sidekiq Pro or Sidekiq Enterprise, which are commercial and closed-source. The
parity tests in `test/parity/` are lifted from Sidekiq's own MIT-licensed test
suite (SHA-pinned, attribution preserved) and are used only as oracles for
behavioural equivalence.

This is the meaning of **clean-room**: the *interface* is copied so that
existing code keeps working; the *implementation* behind it is independent
original work.

## Why copying an API is allowed

The controlling precedent is **Google LLC v. Oracle America, Inc.**, 593 U.S.
___ (2021). The U.S. Supreme Court held that Google's reimplementation of the
Java SE API — reusing the declarations (names, signatures, and their
organization) so that programmers' existing knowledge and code would carry over
— was a fair use as a matter of law. The Court treated API declaring code as
functional, interoperability-enabling material, and found that reimplementing it
to build a compatible platform was transformative and lawful.

Wurk's relationship to Sidekiq mirrors that fact pattern:

| Google v. Oracle | Wurk |
|---|---|
| Reused Java SE API declarations | Reuses the Sidekiq Ruby API + Redis wire format |
| Wrote its own implementation (Dalvik/ART) | Writes its own job runtime (fork-based swarm) |
| Goal: let Java developers' code/skills transfer to Android | Goal: let Sidekiq apps run unchanged on Wurk |

The purpose is interoperability — letting users keep their existing jobs,
Redis data, and muscle memory — which is exactly the interest the Court
protected.

## Trademark

"Sidekiq" is a trademark of Contributed Systems, LLC. Wurk is an independent
project and is **not affiliated with, sponsored by, or endorsed by**
Contributed Systems. References to "Sidekiq", "Sidekiq Pro", and "Sidekiq
Enterprise" are nominative — used only to describe the API Wurk is compatible
with, as permitted for accurate, non-misleading comparative reference. Wurk does
not use the Sidekiq name or logo as its own branding.

## License

Wurk's own code is released under the MIT License (see [LICENSE](../LICENSE)).
That license covers Wurk's original implementation. It does not grant any rights
in Sidekiq, which remains the property of its respective owners.

# Security Policy

## Supported versions

Wurk follows semantic versioning. Security fixes ship in a new release on top
of the **latest** 1.x version; there are no backport branches and no long-term
support line. To pick up a fix, upgrade to the newest 1.x release (within 1.x
an upgrade is meant to be drop-in; check `CHANGELOG.md`).

| Version | Supported |
|---|---|
| Latest 1.x release | ✅ |
| Older 1.x releases | Fixed by upgrading to the latest 1.x |
| < 1.0 | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately through GitHub's
[**Report a vulnerability**](https://github.com/developerz-ai/wurk/security/advisories/new)
form (Security → Advisories). This opens a private advisory only the
maintainers can see.

Please include:

- a description of the issue and its impact,
- the affected version(s),
- steps to reproduce or a proof of concept,
- any suggested remediation.

## What to expect

There is no contractual response time: Wurk is MIT-licensed software with no
paid support tier behind it. What we aim for, on a best-effort basis:

- **Acknowledgement** within 3 business days.
- An initial assessment and severity within 7 days.
- Coordinated disclosure: we'll agree on a timeline with you, ship a patched
  release, and credit you in the advisory and `CHANGELOG.md` unless you prefer
  to remain anonymous.

If your deployment needs a guaranteed response time, that requires a separate
agreement; none is offered as part of this project.

Because Wurk is wire-compatible with Sidekiq and runs your job code with access
to Redis, reports about deserialization, the dashboard's auth surface, or
argument encryption are especially welcome.

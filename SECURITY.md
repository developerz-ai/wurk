# Security Policy

## Supported versions

Wurk follows semantic versioning. Security fixes land on the latest minor
release line.

| Version | Supported |
|---|---|
| 1.x | ✅ |
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

- **Acknowledgement** within 3 business days.
- An initial assessment and severity within 7 days.
- Coordinated disclosure: we'll agree on a timeline with you, ship a patched
  release, and credit you in the advisory and `CHANGELOG.md` unless you prefer
  to remain anonymous.

Because Wurk is wire-compatible with Sidekiq and runs your job code with access
to Redis, reports about deserialization, the dashboard's auth surface, or
argument encryption are especially welcome.

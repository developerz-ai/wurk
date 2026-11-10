# 10 — HTTP API + clients

> Part of [`overview.md`](overview.md). Depends on: [`01`](01-ci-green-doc-truth.md) C1. 2 PRs (A1–A2 · A3–A4). Lowest priority slice.

## Files to change
| ID | Where | Change |
|---|---|---|
| A1 | new `docs/api/openapi.yaml`; routers `lib/wurk/api/jobs.rb:35-46`, `queues.rb:30-41` (TABLE), `app.rb:58`, `flows.rb`, `swarm.rb` | No OpenAPI spec. Hand-write once; unit test asserts every `router.*` route ↔ spec path+method+scope, both directions. |
| A2 | `clients/python/tests/` (today mocks urllib: `test_client.py:1`) | One integration test: boot `exe/wurk api` on a throwaway Redis (`WURK_TEST_DB_OFFSET` or private port), run the client end-to-end. New CI step in the python-client job. |
| A3 | `lib/wurk/api/` (admin scope) | Operator actions missing from `/v1`: `POST /retries/:jid/retry`, `POST /dead/:jid/retry`, `POST /queues/:name/clear`, `GET /batches`. Reuse the dashboard's action whitelist (`app/controllers/wurk/api_controller.rb:409` area); idempotency per `lib/wurk/api/idempotency.rb`. |
| A4 | new `docs/job-format.md` | Polyglot producers: required/optional payload fields, `queues` SADD, `enqueued_at` ms, schedule ZADD — sourced from `docs/target/sidekiq-free.md` §2.1. Parity test round-trips a hand-built payload through a real worker. |

## Tests
- `bin/rake test TEST=test/unit/api_openapi_parity_test.rb`; python: `cd clients/python && python -m pytest`.
- `bin/check full`.

## Done when
- Removing a route from a router table fails the OpenAPI parity test.
- Python integration leg green in CI.

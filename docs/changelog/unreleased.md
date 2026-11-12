# Unreleased

### Changed

- **Dashboard: no decorative motion.** Page headers, tables and the search landing no longer fade up on every page load (the title visibly jumped twice: once as the loading skeleton, again as the real header). Stat numbers render their value instead of counting up from zero, and loading placeholders are static instead of shimmering. The live-status dot and the spinner still move, since they show state.

### Fixed

- **Dashboard Metrics page fetched the queue history twice.** The depth and latency panels used different query keys for the same `/api/queue-history` URL; they now share one request.

### Documentation

- **Rolling cutover for stock Sidekiq 8 apps.** `docs/migrate-from-sidekiq.md` now offers a rolling cutover (both fleets live on one Redis for a while) to a stock Sidekiq 8 app, within what `test/integration/mixed_fleet_test.rb` covers: that test runs real Sidekiq 8.1 next to a `wurkswarm` in its own CI job. Two conditions: stop Wurk processes with `TERM`, and check that no Wurk private list is left before the last Wurk process goes, because stock Sidekiq never reclaims them. Sidekiq 7.x, Pro and Enterprise apps stay on the drain cutover.

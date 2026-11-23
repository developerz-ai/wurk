# Unreleased

### Added

- **sidekiq-unique-jobs, native: drop the gem, keep the code.** Wurk carries sidekiq-unique-jobs 8.x as `Wurk::UniqueJobs`, answering to `SidekiqUniqueJobs` (and to `require "sidekiq-unique-jobs"` / `"sidekiq_unique_jobs"`) when the gem is not in the bundle. Every `lock:` type (`until_executed`, `until_executing`, `while_executing`, `until_and_while_executing`, `until_expired` and their aliases), `lock_args_method`, `lock_ttl`, `lock_timeout`, `lock_prefix`, `lock_info`, `on_conflict` (`:log`, `:reject` to the dead set, `:reschedule`, `:raise`, `:replace`, and `{ client:, server: }`), `unique_across_queues`, `unique_across_workers`, `SidekiqUniqueJobs.configure`, `Server.configure` with its death handler and reaper, `Digests#delete_by_digest`, `Locksmith`, `LockDigest` and `Lock::Validator::DEPRECATED_KEYS`. It writes the gem's own keys and digest (`uniquejobs:<md5>`, `:LOCKED`, `:QUEUED`, `:PRIMED`, `:INFO`, `uniquejobs:digests`), so a fleet drops the gem pod by pod with no migration and no lock gap; `test/ecosystem/sidekiq-unique-jobs-native/` runs a gem pod and a native pod on one Redis and holds them to each other. Its Lua declares every key it touches, so Dragonfly and a strict Redis 7 run it (the gem's `:replace` script does not). The reaper reads each job once per run instead of once per digest. With the gem in the bundle, the gem wins and the native copy stands down. `require "sidekiq_unique_jobs/web"` keeps the gem's Locks, Expiring Locks and Changelogs tabs on Wurk's dashboard. See `docs/unique-jobs.md` §13.

### Changed

- **The boot WARN and `wurk preflight --app` about `lock:` now ask whether a unique-jobs client middleware is installed**, gem or native, instead of whether the gem is loaded.

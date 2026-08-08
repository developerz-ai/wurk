# frozen_string_literal: true

module Wurk
  # Canonical Redis key constants. Wire-compat is sacred: these strings are
  # the on-disk schema shared with Sidekiq OSS and every third-party gem that
  # reads Redis directly (sidekiq-cron, sidekiq-unique-jobs, etc.). Renaming
  # or namespacing any of them silently breaks the drop-in contract.
  #
  # OSS uses no namespace. Pro/Ent layer a prefix on top; that lives outside
  # the free gem.
  #
  # Spec: docs/target/sidekiq-free.md §1 (Redis Key Schema).
  module Keys
    # Queue list keys: `queue:<name>` (LIST, LPUSH/BRPOP).
    QUEUE_PREFIX   = 'queue:'

    # Set of known queue names, without the `queue:` prefix.
    QUEUES_SET     = 'queues'

    # Set of paused queue names (Pro feature; Wurk ships it free).
    # Members are unprefixed queue names. Fetchers exclude these on each pass.
    PAUSED_SET     = 'paused'

    # Sorted sets keyed by score = unix epoch float seconds.
    SCHEDULE       = 'schedule'
    RETRY          = 'retry'
    DEAD           = 'dead'

    # Live process identities (heartbeat membership).
    PROCESSES      = 'processes'

    # Ent Historical Metrics: capped Redis stream of periodic snapshots written
    # by Wurk::History (§5.3). Same key a migrated Sidekiq Ent install uses, so
    # its existing data renders without rewrite. Spec: sidekiq-ent.md §5.3, §10.
    HISTORY_METRICS = 'history:metrics'

    # Profiles (v8.0+): ZSET of `<token>-<jid>` keys, score = expiry epoch;
    # each member also has a `<token>-<jid>` HASH holding the profile blob.
    # Spec: docs/target/sidekiq-free.md §1.7.
    PROFILES       = 'profiles'

    # Global processed counter; per-day variants append `:YYYY-MM-DD`.
    STAT_PROCESSED = 'stat:processed'

    # Global expired counter — subset of processed: jobs the Expiry server
    # middleware dropped before `perform` because `expiry` had already
    # elapsed. Per-day variants append `:YYYY-MM-DD`. Spec: sidekiq-pro.md §7.
    STAT_EXPIRED = 'stat:expired'

    # TTL applied to per-day `stat:processed:*` / `stat:failed:*` /
    # `stat:expired:*` strings. 5 years, in seconds. Matches
    # Sidekiq::Launcher::STATS_TTL.
    STATS_TTL = 5 * 365 * 24 * 60 * 60

    # Per-job status rows: `status:<jid>` HASH holding state, progress,
    # timings, result and error for a worker class that opted into tracking.
    # A Wurk extra, not a Sidekiq surface — nothing in the spec's key schema
    # (sidekiq-free.md §1) lives here, so no existing key is read or written.
    #
    # Deliberately NOT `sidekiq:status:<jid>`: that is the `sidekiq-status`
    # gem's own row (`Sidekiq::Status.status_key`), and a host running both
    # must see two independent sets of keys, not one they fight over.
    STATUS_PREFIX = 'status:'

    # TTL stamped on every `status:<jid>` write. A status row is a live view
    # of a job in flight, not an audit log — retention past the terminal
    # write is a separate, opt-in knob.
    STATUS_TTL = 30 * 60

    # Build a queue list key from a queue name. Centralizing the concat keeps
    # the prefix in one place even though it's a constant — third-party gems
    # that grep for `"queue:"` still find it via the constant.
    def self.queue(name)
      "#{QUEUE_PREFIX}#{name}"
    end

    # Status row key for one jid. Same reason as .queue: one place owns the
    # concat, even though the prefix is a constant.
    def self.status(jid)
      "#{STATUS_PREFIX}#{jid}"
    end
  end
end

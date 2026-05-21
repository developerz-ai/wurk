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

    # Global processed counter; per-day variants append `:YYYY-MM-DD`.
    STAT_PROCESSED = 'stat:processed'

    # TTL applied to per-day `stat:processed:*` / `stat:failed:*` strings.
    # 5 years, in seconds. Matches Sidekiq::Launcher::STATS_TTL.
    STATS_TTL = 5 * 365 * 24 * 60 * 60

    # Build a queue list key from a queue name. Centralizing the concat keeps
    # the prefix in one place even though it's a constant — third-party gems
    # that grep for `"queue:"` still find it via the constant.
    def self.queue(name)
      "#{QUEUE_PREFIX}#{name}"
    end
  end
end

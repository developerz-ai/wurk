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

    # Debounce state: `debounce:<digest>` HASH holding the job JSON currently
    # pending in `schedule` for that key plus the epoch the burst opened at.
    # A Wurk extra, like `status:` — no Sidekiq key schema entry lives here.
    #
    # The collapsed job itself is an ordinary `schedule` member; this key only
    # records which member to pull back out when the next enqueue extends the
    # burst, and is not read by anything that renders jobs.
    DEBOUNCE_PREFIX = 'debounce:'

    # Throttle-to-slot state: `throttle:<digest>:<slot index>` STRING holding
    # the jid that won that slot. A Wurk extra, like `debounce:` — nothing in
    # the Sidekiq key schema (sidekiq-free.md §1) lives here.
    #
    # The slot index is part of the key rather than a field under it, so two
    # adjacent slots are two names and the TTL is left with nothing to decide.
    #
    # `sidekiq-throttled` is the near neighbour and cannot collide: it owns no
    # fixed prefix at all, keying off a host-supplied strategy name suffixed
    # `:threshold` / `:concurrency.v2`.
    THROTTLE_PREFIX = 'throttle:'

    # Global per-queue concurrency (Wurk::QueueSlot): `queue_slot:<queue>` ZSET
    # of the live holders of that queue's slots, score = the epoch each hold
    # expires unless refreshed. A Wurk extra, like `throttle:` — Sidekiq has no
    # cluster-wide per-queue cap, so nothing in its key schema
    # (sidekiq-free.md §1) or in a third-party gem answers to this name.
    #
    # Keyed on the unprefixed queue name, so `queue:critical` and its cap live
    # under two names that can never be mistaken for one another by a SCAN.
    QUEUE_SLOT_PREFIX = 'queue_slot:'

    # Flows (Wurk::Flow): `flow:<fid>` HASH for the flow itself and
    # `flow:<fid>:<node index>` HASH per node. A Wurk extra like `status:` —
    # Sidekiq has no DAG, so nothing in its key schema (sidekiq-free.md §1)
    # answers to this name, and no third-party gem claims the prefix.
    #
    # A node key is the flow key plus `:<index>`, which is unambiguous because
    # a fid is URL-safe base64 and can never contain a colon. The node's *jobs*
    # live where every other job does: its own batch's keys and its queue.
    FLOW_PREFIX = 'flow:'

    # ZSET of every flow, score = creation epoch — the counterpart of `batches`,
    # and the only way a created flow is discoverable without its fid. Bounded
    # by the same two-axis trim (`Batch.trim_bounds`), since flow keys carry the
    # batch clock.
    FLOWS_SET = 'flows'

    # `Idempotency-Key` replay records for the HTTP API: `idempotency:<digest>`
    # STRING holding the response the first request produced. A Wurk extra like
    # `status:` — nothing in the Sidekiq key schema lives here, and nothing
    # outside Wurk::API::Idempotency reads it.
    #
    # The digest covers the credential, the route and the client's key, so the
    # client's own string never reaches Redis in the clear and two producers
    # that both chose `1` address two different records.
    IDEMPOTENCY_PREFIX = 'idempotency:'

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

    # Debounce state key for one identity digest. Same reason as .queue.
    def self.debounce(digest)
      "#{DEBOUNCE_PREFIX}#{digest}"
    end

    # Throttle key *prefix* for one identity digest — not a key on its own.
    # The slot index the Lua script derives from Redis's clock is appended to
    # it, because only Redis can align every producer on the same boundary.
    def self.throttle(digest)
      "#{THROTTLE_PREFIX}#{digest}"
    end

    # Idempotency replay record for one request digest. Same reason as .queue.
    def self.idempotency(digest)
      "#{IDEMPOTENCY_PREFIX}#{digest}"
    end

    # Slot holders for one capped queue, from its unprefixed name. Same reason
    # as .queue.
    def self.queue_slot(queue)
      "#{QUEUE_SLOT_PREFIX}#{queue}"
    end

    # The flow record for one fid. Same reason as .queue.
    def self.flow(fid)
      "#{FLOW_PREFIX}#{fid}"
    end

    # One node's record. Derived from the flow key rather than the prefix so
    # the two can never disagree about where a flow lives.
    def self.flow_node(fid, index)
      "#{flow(fid)}:#{index}"
    end

    # The indexes of the nodes a flow is failed because of: the ones whose job
    # is currently dead, plus the chain links that could not be built because
    # the result they pipe was not there to pipe. A set beside the record
    # rather than a field on it, exactly as `b-<bid>-died` sits beside a batch:
    # a dead node leaves it when its job is retried to success, and an empty
    # set is what makes the flow's `failed` state recoverable. A broken chain
    # link never leaves, which is the truth about it — there is no job in the
    # morgue to retry. It can never collide with .flow_node, whose last segment
    # is always digits.
    def self.flow_dead(fid)
      "#{flow(fid)}:dead"
    end
  end
end

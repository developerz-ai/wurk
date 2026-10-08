# frozen_string_literal: true

require_relative 'job_record'

module Wurk
  # One entry inside a sorted-set view (Retry/Scheduled/Dead). Carries the
  # member's `score` alongside the JobRecord so callers can re-target the
  # exact (score, value) pair when mutating Redis — sorted-set membership is
  # by value, but ZREM-by-value is faster than ZRANGEBYSCORE+filter.
  #
  # The `id` field ("<score>|<jid>") is the Sidekiq wire-compat identifier
  # used by dashboards and third-party tooling. Don't reformat it.
  #
  # Spec: docs/target/sidekiq-free.md §19.4.
  class SortedEntry < JobRecord
    attr_reader :score, :parent

    # @param parent [JobSet, nil] the owning set; nil when constructed bare.
    # @param score [Numeric] ZSET score (Float seconds since epoch).
    # @param item [String, Hash] raw JSON or parsed payload.
    def initialize(parent, score, item)
      super(item)
      @score = score.to_f
      @parent = parent
    end

    # JobRecord resolves the queue eagerly and only from a pre-parsed Hash;
    # a sorted-set entry is almost always built from the raw JSON string, so
    # read it off the payload instead. Lazy on purpose — a scan over a large
    # set must not pay JSON cost for entries nobody inspects.
    def queue = @queue ||= item['queue']

    def id = "#{score}|#{jid}"

    def at = ::Time.at(score).utc

    # Removes this entry from the parent set. Prefers exact-value match
    # (idempotent across duplicates with the same jid), falls back to
    # (score, jid) when constructed without a cached `value`.
    def delete
      if @value
        @parent.delete_by_value(@parent.name, @value)
      else
        @parent.delete_by_jid(@score, jid)
      end
    end

    # Shifts the score by the delta to `at`, returning the new score like
    # Sidekiq's ZINCRBY does. `ZADD XX INCR` is that ZINCRBY minus its one
    # surprise: on a member already promoted or deleted it returns nil instead
    # of re-creating it, so a stale dashboard row can't resurrect a job that
    # has since run.
    #
    # Tracks `@score` so a second call computes its delta against the new
    # score rather than the original one (without this the two-call sequence
    # would cumulatively shift, leaving the member at the wrong time).
    def reschedule(at)
      new_score = Wurk.redis { |conn| conn.call('ZADD', @parent.name, 'XX', 'INCR', at.to_f - @score, value) }
      @score = new_score.to_f if new_score
      new_score
    end

    # Removes this entry and re-enqueues it via the client with the payload
    # untouched. Backs the scheduled/dead "add to queue" actions — Sidekiq's
    # add_to_queue does not touch `retry_count`.
    #
    # Writes the JSON straight to the queue rather than routing through
    # Client#push: Client#push validates and rejects payloads that lack both
    # `jid` and `created_at` yet carry `timeout`/`deadline`/`track`, the
    # shape stock Sidekiq has always accepted. The remove-then-push rescue
    # still restores the entry on a Redis-side failure — validation no
    # longer fires here because there is no validation to fire.
    def add_to_queue
      remove_job do |message|
        json = Wurk.dump_json(message)
        Wurk.redis { |c| c.call('LPUSH', "queue:#{message['queue']}", json) }
      end
    end

    # Same flow but decrements `retry_count` first: the count was already
    # incremented when the job entered the retry set, and the next failure
    # bumps it again — without the decrement a manual "Retry now" would
    # consume an attempt. Wire-compat with Sidekiq's SortedEntry#retry.
    def retry
      remove_job do |message|
        message['retry_count'] = message['retry_count'].to_i - 1 if message['retry_count']
        json = Wurk.dump_json(message)
        Wurk.redis { |c| c.call('LPUSH', "queue:#{message['queue']}", json) }
      end
    end

    # Removes this entry from its parent set and writes it to the dead set.
    # Death handlers fire with the synthesized "Job killed by API" exception
    # (Sidekiq's default) so error trackers and the batch death path observe
    # API/UI kills.
    def kill
      remove_job do |message|
        DeadSet.new.kill(Wurk.dump_json(message))
      end
    end

    def error? = !item['error_class'].nil?

    private

    # Pulls the message out of Redis, yields it for the caller's re-enqueue
    # work, and returns the parsed hash. Done with the cached value when
    # available so LREM-like ZREM matches the exact bytes.
    # Returns nil without yielding when the parent removal fails — prevents
    # duplicate side effects (e.g. retry pushing twice) if another caller
    # already removed the entry.
    #
    # Remove-then-push: a push that raises (client validation, a middleware,
    # Redis) would otherwise leave the job in neither place. The original
    # bytes go back at the original score before the error propagates.
    def remove_job
      message = item.dup
      return nil unless @parent.remove_job(self)

      begin
        yield message
      rescue StandardError
        Wurk.redis { |conn| conn.call('ZADD', @parent.name, @score, value) }
        raise
      end
      message
    end
  end
end

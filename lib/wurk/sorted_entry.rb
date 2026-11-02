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
      # Parsed now, unlike JobRecord: sidekiq-failures reopens this method and
      # reads @item straight after it. Measured on a 20k-member walk that reads
      # no field: 2.5us per entry at 250B, 5us at 2KB, 10us at 8KB, and nothing
      # at all for the walks that do read one, which is all of them in practice.
      self.item if @value
    end

    # JobRecord resolves the queue eagerly and only from a pre-parsed Hash;
    # a sorted-set entry is almost always built from the raw JSON string, so
    # read it off the payload instead.
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
    def reschedule(at)
      Wurk.redis { |conn| conn.call('ZADD', @parent.name, 'XX', 'INCR', at.to_f - @score, value) }
    end

    # Removes this entry and re-enqueues it via the client with the payload
    # untouched. Backs the scheduled/dead "add to queue" actions — Sidekiq's
    # add_to_queue does not touch `retry_count`.
    def add_to_queue
      remove_job do |message|
        Client.new.push(Wurk.load_json(message))
      end
    end

    # Same flow but decrements `retry_count` first: the count was already
    # incremented when the job entered the retry set, and the next failure
    # bumps it again — without the decrement a manual "Retry now" would
    # consume an attempt. Wire-compat with Sidekiq's SortedEntry#retry.
    def retry
      remove_job do |message|
        job = Wurk.load_json(message)
        job['retry_count'] = job['retry_count'].to_i - 1 if job['retry_count']
        Client.new.push(job)
      end
    end

    # Removes this entry from its parent set and writes it to the dead set.
    # Death handlers fire with the synthesized "Job killed by API" exception
    # (Sidekiq's default) so error trackers and the batch death path observe
    # API/UI kills.
    def kill
      remove_job do |message|
        DeadSet.new.kill(message)
      end
    end

    def error? = !item['error_class'].nil?

    private

    # Pulls the message out of Redis, yields its raw JSON for the caller's
    # re-enqueue work, and returns the parsed hash. A String because that is the
    # contract gems wrapping this method parse against; the bytes are also what
    # the ZREM matched, so a kill stores them unchanged.
    # Returns nil without yielding when the parent removal fails — prevents
    # duplicate side effects (e.g. retry pushing twice) if another caller
    # already removed the entry.
    #
    # Remove-then-push: a push that raises (client validation, a middleware,
    # Redis) would otherwise leave the job in neither place. The original
    # bytes go back at the original score before the error propagates.
    def remove_job
      return nil unless @parent.remove_job(self)

      begin
        yield value
      rescue StandardError
        restore_after_failed_push
        raise
      end
      item
    end

    # Past maxmemory the push is refused, and so is a plain ZADD putting the
    # entry back. Dragonfly refuses both forms: all that is left is the log.
    def restore_after_failed_push
      Wurk.redis do |conn|
        conn.call('ZADD', @parent.name, @score, value)
      rescue RedisClient::OutOfMemoryError => e
        Fetcher::OomDrain.zadd(conn, e, @parent.name, @score, value)
      end
    rescue StandardError => e
      Wurk.logger.error("#{@parent.name} entry lost, ZADD refused (#{e.class}): #{value}")
    end
  end
end

# frozen_string_literal: true

require_relative 'sorted_entry'

module Wurk
  # Base class for the three Sidekiq-compatible sorted-set views over Redis
  # (`schedule`, `retry`, `dead`). Splits responsibilities: `SortedSet` owns
  # the generic ZSET reads/clear; `JobSet` owns the job-aware mutations
  # (schedule/retry_all/kill_all and the JobRecord-yielding iteration).
  #
  # Subclasses pick the key by passing it to `super` in `initialize`:
  #   class RetrySet < JobSet ; def initialize ; super('retry') ; end ; end
  #
  # Wire-compat: every Redis call below matches Sidekiq OSS exactly.
  # Spec: docs/target/sidekiq-free.md §19.5.
  class SortedSet
    include Enumerable

    # Page size for paged ZRANGE — matches upstream so dashboards observing
    # Redis traffic see the same query pattern.
    PAGE_SIZE = 50

    attr_reader :name

    def initialize(name)
      @name = name.to_s
    end

    # ZCARD. O(1) on Redis side.
    def size
      Wurk.redis { |conn| conn.call('ZCARD', @name) }
    end

    # Streams every (value, score) pair through ZSCAN. `match` is wrapped in
    # `*` glob characters — callers pass a jid or class name fragment.
    # @yield [String, Float] raw JSON payload and its score.
    def scan(match, count = 100)
      return enum_for(:scan, match, count) unless block_given?

      cursor = '0'
      pattern = "*#{match}*"
      Wurk.redis do |conn|
        loop do
          cursor, pairs = conn.call('ZSCAN', @name, cursor, 'MATCH', pattern, 'COUNT', count)
          pairs.each_slice(2) { |value, score| yield value, score.to_f }
          break if cursor == '0'
        end
      end
    end

    # UNLINK over the whole set. Idempotent. Method name is Sidekiq
    # wire-compat — `clear?` would break the alias.
    def clear
      Wurk.redis { |conn| conn.call('UNLINK', @name) }
      true
    end

    def as_json(_options = nil) = { name: @name }
  end

  # ZSET-of-jobs view. Reverse-paged iteration so callers see newest-first
  # (highest score, i.e. furthest-out retry/schedule). Mutations use
  # ZREM-by-value when the exact bytes are known and a (score, jid) scan
  # otherwise.
  #
  # Spec: docs/target/sidekiq-free.md §19.5.
  class JobSet < SortedSet
    # Plain ZADD, no NX: re-scheduling an identical payload *moves* it to the
    # new timestamp rather than keeping the first one. Mirrors
    # Sidekiq::JobSet#schedule exactly — the last schedule call wins.
    def schedule(timestamp, message)
      Wurk.redis { |conn| conn.call('ZADD', @name, timestamp.to_f.to_s, Wurk.dump_json(message)) }
    end

    # Newest-first paged ZRANGE. Yields a SortedEntry per row.
    def each
      return enum_for(:each) unless block_given?

      page  = 0
      added = 0
      loop do
        start = page * PAGE_SIZE
        stop  = start + PAGE_SIZE - 1
        slice = Wurk.redis { |conn| conn.call('ZRANGE', @name, start, stop, 'REV', 'WITHSCORES') }
        slice.each do |value, score|
          yield SortedEntry.new(self, score, value)
          added += 1
        end
        break if slice.size < PAGE_SIZE

        page += 1
      end
      added
    end

    # ZPOPMIN loop. Each iteration pops the single oldest member (lowest
    # score, e.g. earliest scheduled-at) and yields the raw JSON + score.
    # Used by the scheduled-poller: it enqueues each popped job through the
    # client. Stops when the set is empty.
    def pop_each
      loop do
        result = Wurk.redis { |conn| conn.call('ZPOPMIN', @name, 1) }
        break if result.nil? || result.empty?

        # Newer redis-client returns nested `[[value, score]]` even with COUNT 1;
        # older `[value, score]`. Normalize both.
        value, score = result.first.is_a?(Array) ? result.first : result
        yield value, score.to_f
      end
    end

    # Re-enqueues every job in this set via the client. Returns how many were
    # re-enqueued; a job the push rejects stays in the set (see #sweep_once).
    def retry_all
      sweep_once(&:retry)
    end

    # Moves every job in this set to the dead set. Death handlers fire per
    # entry by default — `each(&:kill)` equivalence with Sidekiq; pass
    # `notify_failure: false` to suppress. Returns the count of jobs moved; a
    # job that could not be moved stays in this set (see #sweep_once).
    def kill_all(notify_failure: true, ex: nil)
      dead = DeadSet.new
      sweep_once do |entry|
        entry.send(:remove_job) do |message|
          dead.kill(Wurk.dump_json(message), notify_failure: notify_failure, ex: ex)
        end
      end
    end

    # O(score) lookup. `score` accepts Time, Numeric, or a Range of either.
    # Returns the matching entries (possibly multiple at the same exact
    # score). When `jid` is set, narrows to the single (score, jid) pair.
    def fetch(score, jid = nil)
      results = Wurk.redis { |conn| conn.call('ZRANGEBYSCORE', @name, *range_args(score), 'WITHSCORES') }
      entries = results.map { |value, sc| SortedEntry.new(self, sc, value) }
      return entries unless jid

      entries.select { |e| e.jid == jid }
    end

    # ZSCAN-based search by jid substring. Returns the first matching entry
    # or nil. O(n) on the ZSET — callers iterating many jids should switch
    # to per-jid hashes or the score-based fetch.
    def find_job(jid)
      scan(jid) do |value, score|
        entry = SortedEntry.new(self, score, value)
        return entry if entry.jid == jid
      end
      nil
    end

    # Removes the exact (score, jid)-matching member. Backs SortedEntry#delete
    # when no cached value bytes are present.
    def remove_job(entry)
      delete_by_value(@name, entry.value) || delete_by_jid(entry.score, entry.jid)
    end

    # ZREM by exact bytes. Returns true when ≥1 element was removed. Method
    # name is Sidekiq wire-compat — `delete_by_value?` would break the alias.
    def delete_by_value(name, value)
      removed = Wurk.redis { |conn| conn.call('ZREM', name, value) }
      removed.to_i.positive?
    end

    # Scan the score bracket for a jid match, ZREM the exact bytes once found.
    # Returns true on success. Aliased as `delete` for Sidekiq wire-compat.
    # Per-row JSON rescue so a single malformed entry can't shadow a valid
    # match at the same score.
    def delete_by_jid(score, jid)
      Wurk.redis do |conn|
        rows = conn.call('ZRANGEBYSCORE', @name, score.to_f, score.to_f)
        rows.each do |raw|
          parsed = begin
            Wurk.load_json(raw)
          rescue ::JSON::ParserError
            nil
          end
          next unless parsed && parsed['jid'] == jid

          return conn.call('ZREM', @name, raw).to_i.positive?
        end
      end
      false
    end
    alias delete delete_by_jid

    private

    # Yields each job at most once and returns how many it yielded. Upstream
    # loops `while size > 0`, re-paging because every removal shifts the ranks
    # `each` pages by — so a job that re-fails straight back into this set
    # (a retry_all of a job that raises at once) keeps the set non-empty and
    # pins the caller, a Puma thread for the dashboard's "Retry All", until the
    # job finally dies. Keyed on jid: a re-failed job comes back as different
    # bytes (retry_count, error fields) but the same jid. Passes repeat only
    # while they still find jobs not yet seen.
    #
    # One entry's failure is that entry's: SortedEntry#remove_job has already
    # put it back, so it is reported and the sweep moves on rather than 500ing
    # the dashboard with the rest of the set untouched. A lost connection is
    # everyone's — every later entry would fail the same way — so it raises.
    # Returns the entries processed without error.
    def sweep_once
      seen = ::Set.new
      done = 0
      loop do
        fresh = 0
        each do |entry|
          next unless seen.add?(entry.jid || entry.value)

          fresh += 1
          done += 1 if sweep_entry(entry) { yield entry }
        end
        break if fresh.zero?
      end
      done
    end

    def sweep_entry(entry)
      yield
      true
    rescue ::RedisClient::ConnectionError, ::ConnectionPool::TimeoutError
      raise
    rescue StandardError => e
      Wurk.configuration.handle_exception(e, { context: "#{@name} sweep", jid: entry.jid })
      false
    end

    # Translates ZRANGEBYSCORE input shapes (Time, Numeric, Range) to the
    # `min max` pair Redis expects.
    def range_args(score)
      case score
      when Range then [score.begin.to_f, score.end.to_f]
      when ::Time, Numeric then [score.to_f, score.to_f]
      else
        raise ArgumentError, "score must be Numeric, Time, or Range: #{score.inspect}"
      end
    end
  end
end

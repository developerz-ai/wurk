# frozen_string_literal: true

require_relative '../test_helper'

class WebSearchTest < Wurk::Test::UnitCase
  parallelize_me!

  # Members per seeding command (see #seed_queue / #seed_zset). The seed sizes
  # track production constants — SCAN_BUDGET is 20k, so the ZSET seed is 40k
  # members of ~250B — and one command carrying all of them is ~10MB of
  # protocol, enough for a server to drop the connection mid-write with EPIPE.
  # Batching keeps every command small at a cost of a few dozen round trips.
  SEED_CHUNK = 1_000

  def setup
    super
    @ns = "wurksrch:#{Process.pid}:#{object_id}"
    @queue = "#{@ns}-q"
    @class_a = "JobAlpha@#{@ns}"
    @class_b = "JobBeta@#{@ns}"
    @needle = "marker-#{@ns}"
  end

  def teardown
    Wurk.redis do |c|
      c.call('DEL', "queue:#{@queue}")
      c.call('SREM', 'queues', @queue)
      cleanup_zset(c, 'retry')
      cleanup_zset(c, 'schedule')
      cleanup_zset(c, 'dead')
    end
  ensure
    super
  end

  def test_empty_substring_returns_no_hits
    hits = Wurk::Web::Search.new('').to_a

    assert_empty hits
  end

  def test_search_finds_queue_hit
    push_to_queue(@class_a, [@needle])
    push_to_queue(@class_b, ['no-match'])

    hits = Wurk::Web::Search.new(@needle, kinds: ['queues']).to_a

    assert_equal(
      { size: 1, kind: 'queue', name: @queue, klass: @class_a },
      { size: hits.size, kind: hits[0][:kind], name: hits[0][:name], klass: hits[0][:klass] }
    )
  end

  def test_search_finds_retry_hit
    jid = push_to_zset('retry', @class_a, [@needle])

    hits = Wurk::Web::Search.new(@needle, kinds: ['retry']).to_a

    assert_equal(
      { kind: 'retry', name: 'retry', jid: jid, score_class: Float },
      { kind: hits[0][:kind], name: hits[0][:name], jid: hits[0][:jid], score_class: hits[0][:score].class }
    )
  end

  # Regression: SortedEntry is built from the raw JSON string, and JobRecord
  # only derived @queue from a pre-parsed Hash — so every retry/scheduled/dead
  # search hit reported `queue: nil` to the dashboard.
  def test_search_sorted_hit_carries_the_queue
    %w[retry schedule dead].each { |set| push_to_zset(set, @class_a, [@needle]) }

    queues = Wurk::Web::Search.new(@needle, kinds: %w[retry scheduled dead]).to_a.map { |h| h[:queue] }

    assert_equal [@queue] * 3, queues
  end

  def test_search_finds_scheduled_hit
    push_to_zset('schedule', @class_a, [@needle])

    hits = Wurk::Web::Search.new(@needle, kinds: ['scheduled']).to_a

    assert_equal 'scheduled', hits[0][:kind]
    assert_equal 'schedule', hits[0][:name]
  end

  def test_search_finds_dead_hit
    push_to_zset('dead', @class_a, [@needle])

    hits = Wurk::Web::Search.new(@needle, kinds: ['dead']).to_a

    assert_equal 'dead', hits[0][:kind]
    assert_equal 'dead', hits[0][:name]
  end

  def test_search_default_covers_every_store
    push_to_queue(@class_a, [@needle])
    push_to_zset('retry', @class_a, [@needle])
    push_to_zset('schedule', @class_a, [@needle])
    push_to_zset('dead', @class_a, [@needle])

    kinds = Wurk::Web::Search.new(@needle).to_a.map { |h| h[:kind] }.uniq.sort

    assert_equal %w[dead queue retry scheduled], kinds
  end

  def test_search_respects_limit
    5.times { push_to_zset('retry', @class_a, [@needle]) }

    hits = Wurk::Web::Search.new(@needle, kinds: ['retry'], limit: 2).to_a

    assert_equal 2, hits.size
  end

  def test_search_clamps_limit_to_max
    s = Wurk::Web::Search.new(@needle, limit: 99_999)

    assert_equal Wurk::Web::Search::MAX_LIMIT, s.limit
  end

  def test_search_invalid_kind_falls_back_to_defaults
    s = Wurk::Web::Search.new(@needle, kinds: ['bogus'])

    assert_equal Wurk::Web::Search::KINDS, s.kinds
  end

  def test_search_substring_no_match_returns_empty
    push_to_zset('retry', @class_a, ['something-else'])

    hits = Wurk::Web::Search.new('nope-not-here', kinds: ['retry']).to_a

    assert_empty(hits.select { |h| h[:klass] == @class_a })
  end

  # Forces paged_lrange to iterate past the first page: with one full
  # QUEUE_PAGE-sized page the loop must NOT break (line 86 else side) and
  # fetch a second page before terminating.
  def test_search_queue_pages_past_first_page
    total = Wurk::Web::Search::QUEUE_PAGE + 5
    total.times { push_to_queue(@class_a, [@needle]) }

    hits = Wurk::Web::Search.new(@needle, kinds: ['queues'], limit: Wurk::Web::Search::MAX_LIMIT).to_a

    assert_equal total, hits.select { |h| h[:klass] == @class_a }.size
  end

  def test_search_small_queue_is_not_truncated
    push_to_queue(@class_a, [@needle])

    search = Wurk::Web::Search.new(@needle, kinds: ['queues'])
    search.to_a

    refute_predicate search, :truncated?
  end

  # A queue longer than the per-queue scan cap must stop early and flag
  # truncation rather than full-walk the LIST from a single keystroke.
  def test_search_truncates_queue_past_scan_cap
    seed_queue(Wurk::Web::Search::SCAN_LIMIT_PER_QUEUE + 1)

    search = Wurk::Web::Search.new("absent-#{@ns}", kinds: ['queues'])
    hits = search.to_a

    assert_empty(hits.select { |h| h[:name] == @queue })
    assert_predicate search, :truncated?
  end

  # A keystroke against a queue with thousands of non-matching jobs must never
  # full-walk the LIST: round trips stay bounded by the scan cap, not the
  # queue's real size. Thread-local Thread.current[:wurk_capsule] override (not
  # a global monkeypatch) so counting is safe under this class's parallelize_me!.
  def test_search_bounds_round_trips_on_a_huge_no_match_queue
    seed_queue(10_000)
    counter = RoundTripCounter.new(Wurk.redis_pool)
    Thread.current[:wurk_capsule] = counter

    search = Wurk::Web::Search.new("absent-#{@ns}", kinds: ['queues'])
    hits = search.to_a

    assert_empty hits
    assert_predicate search, :truncated?
    # Queue.all (1 SMEMBERS) + LLEN (1) + one LRANGE per QUEUE_PAGE up to
    # SCAN_LIMIT_PER_QUEUE — never proportional to the queue's real size (10k
    # would need ~200 LRANGE calls to full-walk instead of the capped ~100).
    max_round_trips = 2 + (Wurk::Web::Search::SCAN_LIMIT_PER_QUEUE / Wurk::Web::Search::QUEUE_PAGE)

    assert_operator counter.count, :<=, max_round_trips
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  # A no-match keystroke against a sorted set larger than the shared request
  # budget must stop at SCAN_BUDGET rather than ZSCAN the whole ZSET. Binds a
  # round-trip-counting capsule to this thread (not a global monkeypatch) so
  # counting is safe under this class's parallelize_me!.
  def test_search_bounds_scan_on_a_huge_no_match_sorted_set
    seed_size = 2 * Wurk::Web::Search::SCAN_BUDGET
    seed_zset('retry', seed_size)
    # Measured, not computed: ZSCAN's COUNT is a bucket hint, so a page carries
    # an arbitrary number of elements (Redis returns ~100 for COUNT 200 at this
    # size) and seed_size / ZSCAN_PAGE understates a real walk by ~2x.
    full_walk = count_zscan_pages('retry')
    counter = RoundTripCounter.new(Wurk.redis_pool)
    Thread.current[:wurk_capsule] = counter

    search = Wurk::Web::Search.new("absent-#{@ns}", kinds: ['retry'])
    hits = search.to_a

    assert_empty hits
    assert_predicate search, :truncated?
    # Strictly fewer round trips than walking the whole ZSET proves the scan
    # stops at the request budget, not at the set's real size.
    assert_operator counter.count, :<, full_walk
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  # Queue payload with no enqueued_at / created_at exercises the nil sides
  # of `record.enqueued_at&.to_f` (line 115) and `record.created_at&.to_f`
  # (line 116) in queue_row.
  def test_search_queue_row_handles_missing_timestamps
    push_bare_to_queue(@class_a, [@needle])

    hits = Wurk::Web::Search.new(@needle, kinds: ['queues']).to_a

    assert_equal(
      { size: 1, enqueued_at: nil, created_at: nil },
      { size: hits.size, enqueued_at: hits[0][:enqueued_at], created_at: hits[0][:created_at] }
    )
  end

  # Sorted-set payload with no enqueued_at / created_at exercises the nil
  # sides of `entry.enqueued_at&.to_f` (line 128) and
  # `entry.created_at&.to_f` (line 129) in sorted_row.
  def test_search_sorted_row_handles_missing_timestamps
    push_bare_to_zset('retry', @class_a, [@needle])

    hits = Wurk::Web::Search.new(@needle, kinds: ['retry']).to_a

    assert_equal(
      { size: 1, enqueued_at: nil, created_at: nil },
      { size: hits.size, enqueued_at: hits[0][:enqueued_at], created_at: hits[0][:created_at] }
    )
  end

  # Line 100 `else` (sorted_set_for returning nil) is unreachable through
  # the public API: `each_hit` only routes non-'queues' kinds to
  # search_sorted_set, and @kinds is filtered to KINDS in the constructor,
  # so `kind` is always one of retry/scheduled/dead. No way to drive nil
  # without reaching into private internals.
  def test_sorted_set_for_else_unreachable
    skip 'sorted_set_for else is unreachable: kinds are filtered to KINDS'
  end

  private

  # Delegating pool that counts checkouts (one per `Wurk.redis` block). Doubles
  # as its own `Thread.current[:wurk_capsule]` binding (`#redis_pool` returns
  # self) so a test can measure round trips without a global monkeypatch.
  class RoundTripCounter
    attr_reader :count

    def initialize(pool)
      @pool = pool
      @count = 0
    end

    def with(&)
      @count += 1
      @pool.with(&)
    end

    def redis_pool = self
  end

  # Bulk-seed a queue with `count` non-matching payloads so the scan-cap tests
  # can exceed SCAN_LIMIT_PER_QUEUE without thousands of calls.
  def seed_queue(count)
    payload = Wurk.dump_json(bare_payload(@class_a, ['filler']))
    Wurk.redis do |c|
      c.call('SADD', 'queues', @queue)
      Array.new(count, payload).each_slice(SEED_CHUNK) { |batch| c.call('RPUSH', "queue:#{@queue}", *batch) }
    end
  end

  # Bulk-seed a sorted set with `count` distinct non-matching members so the
  # scan-budget test can exceed SCAN_BUDGET without thousands of calls. A filler
  # class (not @class_a/@class_b) keeps teardown's cleanup_zset from ZREMing
  # them one-by-one; the worker's FLUSHDB clears them. Each payload carries a
  # unique jid, so no two members collide.
  def seed_zset(name, count)
    filler = "SearchFiller@#{@ns}"
    members = Array.new(count) { |i| [i, Wurk.dump_json(bare_payload(filler, ['filler']))] }
    Wurk.redis do |c|
      members.each_slice(SEED_CHUNK) { |batch| c.call('ZADD', name, *batch.flatten) }
    end
  end

  # ZSCAN pages needed to walk `name` end to end, at the page size the search
  # itself uses. Call before installing the RoundTripCounter — these round trips
  # are the baseline, not part of what's being measured.
  def count_zscan_pages(name)
    cursor = '0'
    pages = 0
    Wurk.redis do |c|
      loop do
        cursor, = c.call('ZSCAN', name, cursor, 'COUNT', Wurk::Web::Search::ZSCAN_PAGE)
        pages += 1
        break if cursor == '0'
      end
    end
    pages
  end

  def push_bare_to_queue(klass, args)
    payload = bare_payload(klass, args)
    Wurk.redis do |c|
      c.call('SADD', 'queues', @queue)
      c.call('LPUSH', "queue:#{@queue}", Wurk.dump_json(payload))
    end
    payload['jid']
  end

  def push_bare_to_zset(name, klass, args)
    payload = bare_payload(klass, args)
    Wurk.redis { |c| c.call('ZADD', name, ::Time.now.to_f.to_s, Wurk.dump_json(payload)) }
    payload['jid']
  end

  def bare_payload(klass, args)
    {
      'class' => klass,
      'args' => args,
      'queue' => @queue,
      'jid' => SecureRandom.hex(12),
      'retry_count' => 0
    }
  end

  def push_to_queue(klass, args)
    payload = job_payload(klass, args)
    Wurk.redis do |c|
      c.call('SADD', 'queues', @queue)
      c.call('LPUSH', "queue:#{@queue}", Wurk.dump_json(payload))
    end
    payload['jid']
  end

  def push_to_zset(name, klass, args)
    payload = job_payload(klass, args)
    Wurk.redis { |c| c.call('ZADD', name, ::Time.now.to_f.to_s, Wurk.dump_json(payload)) }
    payload['jid']
  end

  def job_payload(klass, args)
    {
      'class' => klass,
      'args' => args,
      'queue' => @queue,
      'jid' => SecureRandom.hex(12),
      'created_at' => ::Time.now.to_f,
      'enqueued_at' => ::Time.now.to_f,
      'retry_count' => 0
    }
  end

  def cleanup_zset(conn, key)
    conn.call('ZRANGEBYSCORE', key, '-inf', '+inf').each do |raw|
      parsed = begin
        Wurk.load_json(raw)
      rescue ::JSON::ParserError
        nil
      end
      next unless parsed.is_a?(Hash)
      next unless [@class_a, @class_b].include?(parsed['class'])

      conn.call('ZREM', key, raw)
    end
  end
end

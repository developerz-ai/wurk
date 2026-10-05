# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives Wurk::Client::Buffered against real Redis. Simulates Redis-outage
# behavior by routing pushes through a fake pool that raises
# RedisClient::ConnectionError. Verifies: (a) push returns a jid even on
# outage, (b) on next push the buffer drains oldest-first, (c) cap eviction
# behavior, (d) batched payloads bypass the buffer and raise immediately.
#
# Mutates global state on Wurk::Client (prepends InstanceMethods once; resets
# the buffer between tests). Opts into the parallel runner per the project
# contract, but a class-level mutex around #run serializes execution *within*
# this class so the global Client/Buffered singleton state can't race. Other
# test classes still run in parallel with this one.
class ClientBufferedTest < Wurk::Test::UnitCase
  parallelize_me!

  MUTEX = Mutex.new

  def run(*args, &)
    MUTEX.synchronize { super }
  end

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @class_name = "BufferedJob@#{Process.pid}-#{object_id}"
    @queue      = "bq-#{Process.pid}-#{object_id}"
    Wurk::Client.reliable_push!
    Wurk::Client::Buffered.reset!
  end

  def teardown
    Wurk::Client.reliable_push_drainer_stop!
    Wurk::Client::Buffered.reset!
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue) if @queue
    end
  ensure
    super
  end

  # --- activation & config ----------------------------------------------

  def test_reliable_push_is_idempotent
    Wurk::Client.reliable_push!
    Wurk::Client.reliable_push!

    assert_predicate Wurk::Client, :reliable_push?
  end

  def test_default_buffer_cap_is_1000
    assert_equal 1_000, Wurk::Client::Buffered::DEFAULT_BUFFER_CAP
    assert_equal 1_000, Wurk::Client.reliable_push_buffer
  end

  def test_reliable_push_buffer_setter_accepts_positive_integer
    Wurk::Client.reliable_push_buffer = 50

    assert_equal 50, Wurk::Client.reliable_push_buffer
  end

  def test_reliable_push_buffer_rejects_non_positive
    assert_raises(ArgumentError) { Wurk::Client.reliable_push_buffer = 0 }
    assert_raises(ArgumentError) { Wurk::Client.reliable_push_buffer = -1 }
    assert_raises(ArgumentError) { Wurk::Client.reliable_push_buffer = 'big' }
  end

  # --- buffer on outage --------------------------------------------------

  def test_push_buffers_payload_on_connection_error
    client = build_client(failing_pool)
    jid = client.push(base_item)

    assert_match(/\A[0-9a-f]{24}\z/, jid)
    assert_equal 1, Wurk::Client::Buffered.buffer_size
  end

  def test_push_returns_jid_even_when_buffered
    client = build_client(failing_pool)

    refute_nil client.push(base_item)
  end

  def test_push_bulk_buffers_all_payloads_on_outage
    client = build_client(failing_pool)
    client.push_bulk(base_item('args' => [[1], [2], [3]]))

    assert_equal 3, Wurk::Client::Buffered.buffer_size
  end

  def test_buffered_payloads_drain_on_next_successful_push
    client, pool = outage_client
    3.times { |i| client.push(base_item('args' => [i])) }

    assert_equal 3, Wurk::Client::Buffered.buffer_size

    pool.recover!
    client.push(base_item('args' => [99]))

    assert_equal 0, Wurk::Client::Buffered.buffer_size
    # 3 buffered + 1 new = 4 jobs in queue
    assert_equal 4, queue_length
  end

  def test_drain_preserves_oldest_first_order
    client, pool = outage_client
    client.push(base_item('args' => ['first']))
    client.push(base_item('args' => ['second']))
    client.push(base_item('args' => ['third']))

    pool.recover!
    client.push(base_item('args' => ['fourth']))

    # LPUSH puts newest at head → reversing gives push order:
    assert_equal [['first'], ['second'], ['third'], ['fourth']], queued_args.reverse
  end

  def test_drain_emits_statsd_per_job
    calls = with_statsd_capture do
      client, pool = outage_client
      client.push(base_item)
      client.push(base_item)
      pool.recover!
      client.push(base_item)
    end

    assert_equal %w[jobs.recovered.push jobs.recovered.push], calls.grep('jobs.recovered.push')
  end

  # Plan 03/S14. A buffered payload is not in Redis — the ring buffer can still
  # evict it — so booking `jobs.enqueued` at push time counts an enqueue that
  # may never happen, and double-counts the one that does.
  def test_buffered_push_does_not_emit_jobs_enqueued
    calls = with_statsd_capture { build_client(failing_pool).push(base_item) }

    assert_empty calls.grep('jobs.enqueued')
  end

  def test_buffered_bulk_push_does_not_emit_jobs_enqueued
    calls = with_statsd_capture do
      build_client(failing_pool).push_bulk(base_item('args' => [[1], [2]]))
    end

    assert_empty calls.grep('jobs.enqueued')
  end

  # The replay is where the job actually reaches Redis, so that is where its
  # enqueue counts. Asserted as a sequence, not a tally: the totals match
  # either way, and it is the attribution that moved — each replayed payload
  # counts itself as it lands, then the live push counts its own.
  def test_drain_emits_jobs_enqueued_as_each_payload_lands
    calls = with_statsd_capture do
      client, pool = outage_client
      client.push(base_item('args' => [1]))
      client.push(base_item('args' => [2]))
      pool.recover!
      client.push(base_item('args' => [3]))
    end

    assert_equal %w[jobs.enqueued jobs.recovered.push jobs.enqueued jobs.recovered.push jobs.enqueued],
                 calls.grep(/\Ajobs\.(enqueued|recovered\.push)\z/)
  end

  # A payload the buffer never took (dropped by the ring cap) must not be
  # counted by anyone: not the push that lost it, not a later drain.
  def test_cap_evicted_payload_is_never_counted_as_enqueued
    Wurk::Client.reliable_push_buffer = 1
    calls = with_statsd_capture do
      client, pool = outage_client
      client.push(base_item('args' => ['evicted']))
      client.push(base_item('args' => ['kept']))
      pool.recover!
      client.push(base_item('args' => ['live']))
    end

    assert_equal 2, calls.grep('jobs.enqueued').size
  end

  # --- drain pool resolution (plan 03/S12, K14) --------------------------

  # Capturing the pool object pinned it for the life of the process:
  # `reset_redis_pools!` shuts that instance down and builds a replacement, and
  # a ConnectionPool shutdown is terminal, so a replay would go into dead
  # sockets forever. The config is asked again at replay time instead.
  def test_origin_follows_a_config_pool_rebuild
    config = isolated_config
    stale  = config.redis_pool
    Wurk::Client::Buffered.enbuffer([base_item], client: Wurk::Client.new(pool: stale, config: config))

    config.reset_redis_pools!
    resolved = Wurk::Client::Buffered.buffer.first.origin.resolve

    refute_same stale, resolved
    assert_same config.redis_pool, resolved
  end

  # A pool the config does not hand out is a second Redis nothing else can
  # produce — replaying it anywhere else would write to the wrong server, so
  # that one stays pinned.
  def test_origin_pins_a_pool_the_config_does_not_own
    foreign = failing_pool
    Wurk::Client::Buffered.enbuffer([base_item], client: build_client(foreign))

    assert_same foreign, Wurk::Client::Buffered.buffer.first.origin.resolve
  end

  # K14: the outage buffer is process-global, but a sharded app's backlog is
  # not. A job pushed through `Client.via(shard_a)` must replay into shard A,
  # never into whichever pool pushes next.
  def test_a_via_push_replays_into_its_own_pool_not_the_next_pushers
    shard_a = TogglablePool.new(@pool)
    shard_a.fail!
    Wurk::Client.via(shard_a) { Wurk::Client.new.push(base_item('args' => ['for-a'])) }

    Wurk::Client.new.push(base_item('args' => ['via-default']))

    assert_equal [['for-a']], buffered_args, 'a push through another pool must not take shard A\'s backlog'
    assert_equal 0, shard_a.writes

    shard_a.recover!
    Wurk::Client.via(shard_a) { Wurk::Client.new.push(base_item('args' => ['a-live'])) }

    assert_equal 0, Wurk::Client::Buffered.buffer_size
    assert_equal 2, shard_a.writes, 'the backlog and the live push both went through shard A'
  end

  # Entries for a pool that is still down do not stop another pool's drain.
  def test_drain_skips_entries_bound_for_another_pool
    down = TogglablePool.new(@pool)
    down.fail!
    build_client(down).push(base_item('args' => ['stuck']))
    up, = outage_client
    up.push(base_item('args' => ['queued']))
    up.instance_variable_get(:@redis_pool).recover!

    up.push(base_item('args' => ['live']))

    assert_equal [['stuck']], buffered_args
    assert_equal [['queued'], ['live']], queued_args.reverse
  end

  def test_drain_all_replays_every_origin_and_reports_the_first_failure
    broken = TogglablePool.new(@pool)
    broken.fail!
    build_client(broken).push(base_item('args' => ['broken']))
    healthy, = outage_client
    healthy.push(base_item('args' => ['healthy']))
    healthy.instance_variable_get(:@redis_pool).recover!
    broken.explode!

    assert_raises(RuntimeError) { Wurk::Client::Buffered.drain_all! }
    assert_equal [['healthy']], queued_args, 'the healthy origin drained despite the broken one'
    assert_equal [['broken']], buffered_args, 'the broken payload is restored, not dropped'
  end

  # --- ring cap ----------------------------------------------------------

  def test_buffer_drops_oldest_when_cap_exceeded
    Wurk::Client.reliable_push_buffer = 2
    failing = build_client(failing_pool)
    failing.push(base_item('args' => ['oldest']))
    failing.push(base_item('args' => ['middle']))
    failing.push(base_item('args' => ['newest']))

    assert_equal 2, Wurk::Client::Buffered.buffer_size
  end

  def test_drain_after_cap_eviction_replays_surviving_entries
    Wurk::Client.reliable_push_buffer = 2
    client, pool = outage_client
    client.push(base_item('args' => ['oldest']))
    client.push(base_item('args' => ['middle']))
    client.push(base_item('args' => ['newest']))

    pool.recover!
    client.push(base_item('args' => ['fresh']))

    queued = queued_args

    refute_includes queued, ['oldest']
    assert_includes queued, ['middle']
    assert_includes queued, ['newest']
    assert_includes queued, ['fresh']
  end

  # --- batch bypass ------------------------------------------------------

  def test_batched_payload_does_not_buffer_and_re_raises
    client = build_client(failing_pool)

    assert_raises(RedisClient::ConnectionError) do
      client.push(base_item('bid' => 'B12345'))
    end
    assert_equal 0, Wurk::Client::Buffered.buffer_size
  end

  # --- partial drain on persistent outage --------------------------------

  def test_drain_re_buffers_payload_when_redis_still_down
    failing = build_client(failing_pool)
    failing.push(base_item('args' => [1]))
    failing.push(base_item('args' => [2]))

    # Next push also fails — buffer should preserve head order, no dupes.
    failing.push(base_item('args' => [3]))

    assert_equal 3, Wurk::Client::Buffered.buffer_size
    assert_equal [[1], [2], [3]], buffered_args
  end

  # --- overflow mode (issue #19, opt-in raise on cap) --------------------

  def test_overflow_mode_default_is_drop_oldest
    assert_equal :drop_oldest, Wurk::Client::Buffered.overflow_mode
    assert_equal :drop_oldest, Wurk::Client.reliable_push_overflow
  end

  def test_overflow_mode_setter_accepts_known_modes
    Wurk::Client.reliable_push_overflow = :raise

    assert_equal :raise, Wurk::Client.reliable_push_overflow

    Wurk::Client.reliable_push_overflow = 'drop_oldest'

    assert_equal :drop_oldest, Wurk::Client.reliable_push_overflow
  end

  def test_overflow_mode_setter_rejects_unknown
    assert_raises(ArgumentError) { Wurk::Client.reliable_push_overflow = :explode }
  end

  def test_overflow_raise_raises_when_cap_reached
    Wurk::Client.reliable_push_buffer = 2
    Wurk::Client.reliable_push_overflow = :raise
    failing = build_client(failing_pool)

    failing.push(base_item('args' => ['first']))
    failing.push(base_item('args' => ['second']))

    err = assert_raises(Wurk::Client::Buffered::Overflow) { failing.push(base_item('args' => ['third'])) }

    assert_equal [['third']], payload_args(err.payloads)
    assert_equal 2, Wurk::Client::Buffered.buffer_size, 'buffer untouched by overflow payload'
  end

  def test_overflow_raise_preserves_oldest_when_cap_reached
    Wurk::Client.reliable_push_buffer = 1
    Wurk::Client.reliable_push_overflow = :raise
    failing = build_client(failing_pool)

    failing.push(base_item('args' => ['keep']))
    assert_raises(Wurk::Client::Buffered::Overflow) { failing.push(base_item('args' => ['reject'])) }

    assert_equal [['keep']], buffered_args
  end

  # The cap splits a single bulk push: what fits is buffered, the rest rides on
  # the exception. Nothing may fall between the two.
  def test_overflow_raise_fills_remaining_capacity_and_reports_the_rest
    Wurk::Client.reliable_push_buffer = 3
    Wurk::Client.reliable_push_overflow = :raise
    failing = build_client(failing_pool)

    failing.push(base_item('args' => [0]))
    err = assert_raises(Wurk::Client::Buffered::Overflow) do
      failing.push_bulk(base_item('args' => [[1], [2], [3], [4], [5]]))
    end

    assert_equal 3, Wurk::Client::Buffered.buffer_size
    assert_equal [[0], [1], [2]], buffered_args
    assert_equal [[3], [4], [5]], payload_args(err.payloads)
  end

  # Plan 03/S2's stated case: a 1000-payload bulk push against a buffer one slot
  # short of the cap used to buffer that one payload, raise on the second and
  # drop the other 998 on the floor — no buffer slot, no Redis write, no
  # reference on the exception.
  def test_overflow_raise_loses_no_payload_from_a_large_bulk_push
    cap = 1_000
    Wurk::Client.reliable_push_buffer = cap
    failing = build_client(failing_pool)
    failing.push_bulk(base_item('args' => Array.new(cap - 1) { |i| [i] }))
    Wurk::Client.reliable_push_overflow = :raise

    fresh = Array.new(cap) { |i| [cap + i] }
    err = assert_raises(Wurk::Client::Buffered::Overflow) do
      failing.push_bulk(base_item('args' => fresh))
    end

    assert_equal cap, Wurk::Client::Buffered.buffer_size
    # One fresh payload took the last slot, the other 999 ride on the
    # exception: every one accounted for exactly once, in submission order.
    assert_equal fresh, buffered_args.last(1) + payload_args(err.payloads)
  end

  # Lowering the cap below the current buffer size makes remaining capacity
  # negative; the whole call must be reported, not clamped into a partial take.
  def test_overflow_raise_rejects_whole_call_when_cap_dropped_below_buffer_size
    Wurk::Client.reliable_push_buffer = 3
    failing = build_client(failing_pool)
    failing.push_bulk(base_item('args' => [[1], [2], [3]]))

    Wurk::Client.reliable_push_buffer = 1
    Wurk::Client.reliable_push_overflow = :raise
    err = assert_raises(Wurk::Client::Buffered::Overflow) do
      failing.push_bulk(base_item('args' => [[4], [5]]))
    end

    assert_equal [[4], [5]], payload_args(err.payloads)
    assert_equal [[1], [2], [3]], buffered_args
  end

  def test_overflow_message_reports_cap_and_undelivered_count
    Wurk::Client.reliable_push_buffer = 1
    Wurk::Client.reliable_push_overflow = :raise
    failing = build_client(failing_pool)
    failing.push(base_item('args' => ['keep']))

    err = assert_raises(Wurk::Client::Buffered::Overflow) do
      failing.push_bulk(base_item('args' => [[1], [2]]))
    end

    assert_equal 'reliable_push buffer is full (cap=1), 2 payload(s) undelivered', err.message
  end

  # Batched payloads never buffer, so an overflow that pre-empts their
  # connection-error re-raise would strand them without a trace.
  def test_overflow_carries_batched_payloads_from_a_mixed_push
    Wurk::Client.reliable_push_buffer = 1
    Wurk::Client.reliable_push_overflow = :raise
    failing = build_client(failing_pool)
    failing.push(base_item('args' => ['keep']))

    err = assert_raises(Wurk::Client::Buffered::Overflow) { failing.send(:raw_push, mixed_payloads) }

    assert_equal [['plain'], ['batched']], payload_args(err.payloads)
    assert_equal [['keep']], buffered_args, 'batched payload must not reach the buffer'
    assert_instance_of RedisClient::ConnectionError, err.cause
  end

  # With room left, the mixed push keeps the documented split: bidless buffers,
  # batched re-raises the connection error.
  def test_mixed_push_re_raises_connection_error_when_buffer_has_room
    Wurk::Client.reliable_push_buffer = 10
    Wurk::Client.reliable_push_overflow = :raise
    failing = build_client(failing_pool)

    assert_raises(RedisClient::ConnectionError) { failing.send(:raw_push, mixed_payloads) }
    assert_equal [['plain']], buffered_args
  end

  # --- background drainer (issue #19) ------------------------------------

  def test_reliable_push_drainer_starts_thread
    Wurk::Client.reliable_push_drainer(interval: 0.05)

    assert_predicate Wurk::Client, :reliable_push_drainer_running?
  end

  def test_reliable_push_drainer_idempotent_restart
    Wurk::Client.reliable_push_drainer(interval: 0.05)
    first = Wurk::Client::Buffered.instance_variable_get(:@drainer)
    Wurk::Client.reliable_push_drainer(interval: 0.1)
    second = Wurk::Client::Buffered.instance_variable_get(:@drainer)

    refute_same first, second
    assert_predicate Wurk::Client, :reliable_push_drainer_running?
  end

  def test_reliable_push_drainer_stop
    Wurk::Client.reliable_push_drainer(interval: 0.05)
    Wurk::Client.reliable_push_drainer_stop!

    refute_predicate Wurk::Client, :reliable_push_drainer_running?
  end

  # Regression: reset! used to swap the buffer/cap/overflow-mode ivars but
  # leave `@drainer` running — the thread survived reset! and kept ticking,
  # unreachable, for the life of the process.
  def test_reset_stops_a_running_drainer
    Wurk::Client.reliable_push_drainer(interval: 0.02)

    assert_predicate Wurk::Client, :reliable_push_drainer_running?

    Wurk::Client::Buffered.reset!

    refute_predicate Wurk::Client, :reliable_push_drainer_running?
    assert_nil Wurk::Client::Buffered.instance_variable_get(:@drainer)
  end

  def test_drainer_drains_buffer_against_recovering_pool
    client, pool = outage_client
    client.push(base_item('args' => ['a']))
    client.push(base_item('args' => ['b']))

    assert_equal 2, Wurk::Client::Buffered.buffer_size

    # Once the pool recovers and the drainer ticks, both payloads land in the
    # live queue without another push.
    Wurk::Client::Buffered.start_drainer!(interval: 0.02)
    pool.recover!

    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 3.0
    until Wurk::Client::Buffered.buffer_size.zero? || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end

    assert_equal 0, Wurk::Client::Buffered.buffer_size, 'drainer did not flush buffer within 3s'
    assert_equal [['a'], ['b']], queued_args.reverse
  end

  # K1 pattern: a drain that raises is reported and the thread keeps ticking.
  def test_drainer_survives_a_raising_drain_and_reports_it
    reported = Queue.new
    handler = ->(ex, ctx, _cfg) { reported << ex if ctx[:context] == 'reliable_push drainer' }
    pool = TogglablePool.new(@pool)
    pool.fail!
    build_client(pool).push(base_item('args' => ['x']))
    pool.explode!

    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      Wurk.configuration.error_handlers << handler
      Wurk::Client::Buffered.start_drainer!(interval: 0.02)

      assert_instance_of RuntimeError, reported.pop(timeout: 5)
      assert_instance_of RuntimeError, reported.pop(timeout: 5), 'the next tick ran too'
      assert_predicate Wurk::Client, :reliable_push_drainer_running?
    ensure
      Wurk::Client.reliable_push_drainer_stop!
      Wurk.configuration.error_handlers.delete(handler)
    end
  end

  def test_drainer_rejects_non_positive_interval
    assert_raises(ArgumentError) { Wurk::Client::Buffered::Drainer.new(interval: 0) }
    assert_raises(ArgumentError) { Wurk::Client::Buffered::Drainer.new(interval: -1) }
  end

  # start is idempotent: a second start while the thread is alive hits the
  # `return if @thread&.alive?` then-branch and keeps the same thread.
  def test_drainer_start_is_idempotent_while_running
    drainer = idle_drainer
    drainer.start
    first = drainer.instance_variable_get(:@thread)
    drainer.start
    second = drainer.instance_variable_get(:@thread)

    assert_same first, second
    assert_predicate drainer, :running?
  ensure
    drainer.stop
  end

  # stop with no thread ever started exercises the `@thread&.join` nil
  # (else) side and running? `@thread&.alive?` nil (else) side.
  def test_drainer_stop_and_running_with_no_thread
    drainer = idle_drainer

    refute_predicate drainer, :running?
    drainer.stop # must not raise on nil @thread

    refute_predicate drainer, :running?
  end

  # wait_interval's `@wake.wait(...) unless @done` else-side: when @done is
  # already true (stop won the race before the loop parked), the wait is
  # skipped and the method returns immediately rather than parking for the
  # 30s interval. Driven directly so it's deterministic — no thread timing.
  def test_wait_interval_skips_wait_when_already_done
    drainer = Wurk::Client::Buffered::Drainer.new(interval: 30.0)
    drainer.instance_variable_set(:@done, true)

    t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    drainer.send(:wait_interval)
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0

    assert_operator elapsed, :<, 1.0, 'wait_interval must not park when @done is set'
  end

  # Complementary then-side: @done false → wait_interval parks on the
  # ConditionVariable, and a broadcast (what stop sends) wakes it back up.
  def test_wait_interval_parks_until_broadcast_when_not_done
    drainer = Wurk::Client::Buffered::Drainer.new(interval: 30.0)
    waiter = Thread.new { drainer.send(:wait_interval) }

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    sleep 0.005 until waiter.status == 'sleep' || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started > 1.0

    assert_equal 'sleep', waiter.status, 'wait_interval should park on the condvar'

    lock = drainer.instance_variable_get(:@lock)
    wake = drainer.instance_variable_get(:@wake)
    lock.synchronize { wake.broadcast }

    assert waiter.join(5.0), 'broadcast should wake the parked wait_interval'
  end

  private

  # Drainer with a long interval so the run loop never ticks; lets us assert
  # start/stop/running? control flow directly.
  def idle_drainer
    Wurk::Client::Buffered::Drainer.new(interval: 30.0)
  end

  # Statsd singletons are process-global — serialize against every other test
  # class that also rewrites `Wurk::Metrics::Statsd.increment`.
  def with_statsd_capture(&)
    Wurk::Test::STATSD_MUTEX.synchronize do
      calls = []
      with_stand_in_client { with_increment_stub(calls, &) }
      calls
    end
  end

  # The capture stubs `increment` rather than the client, but
  # `Client#emit_enqueued` resolves the client first and skips the whole emit
  # when none is wired up — so one has to stand in for the block's duration.
  # The stub means it is never actually called; any object will do.
  def with_stand_in_client
    prev = Wurk.configuration.dogstatsd
    Wurk.configuration.dogstatsd = Object.new
    yield
  ensure
    Wurk.configuration.dogstatsd = prev
  end

  def with_increment_stub(calls)
    Wurk::Metrics::Statsd.singleton_class.alias_method(:__increment_real, :increment)
    Wurk::Metrics::Statsd.define_singleton_method(:increment) { |metric, **| calls << metric }
    yield
  ensure
    Wurk::Metrics::Statsd.singleton_class.send(:alias_method, :increment, :__increment_real)
    Wurk::Metrics::Statsd.singleton_class.send(:remove_method, :__increment_real)
  end

  def base_item(overrides = {})
    { 'class' => @class_name, 'args' => [], 'queue' => @queue }.merge(overrides)
  end

  def buffered_args
    payload_args(Wurk::Client::Buffered.buffer.map(&:payload))
  end

  def payload_args(payloads)
    payloads.map { |p| p['args'] }
  end

  # A push raw_push has to split: one bidless payload (buffers) and one
  # carrying a bid (never buffers, re-raises).
  def mixed_payloads
    [base_item('args' => ['plain'], 'jid' => 'j1'),
     base_item('args' => ['batched'], 'jid' => 'j2', 'bid' => 'B1')]
  end

  def build_client(pool)
    Wurk::Client.new(pool: pool)
  end

  # A Configuration of our own, so the pool-rebuild test can call
  # `reset_redis_pools!` without shutting the pool every other test class in
  # this process is holding. Its pools are built but never connected.
  def isolated_config
    config = Wurk::Configuration.new
    config.redis = { url: Wurk::Test.redis_url }
    config
  end

  # Pool that yields a connection always raising ConnectionError on the
  # pipelined write path Wurk::Client#raw_push uses.
  def failing_pool
    pool = Object.new
    pool.define_singleton_method(:with) do |&blk|
      blk.call(FailingConn.new)
    end
    pool
  end

  # A client over a pool that is down until `recover!` — the same pool object
  # before and after, as a real outage-then-recovery is.
  def outage_client
    pool = TogglablePool.new(@pool)
    pool.fail!
    [build_client(pool), pool]
  end

  # Fronts the real pool: fails like a dead socket while `fail!`ed, raises a
  # non-connection error while `explode!`d, and counts the blocks it let
  # through to Redis.
  class TogglablePool
    attr_reader :writes

    def initialize(real_pool)
      @real_pool = real_pool
      @mode = :up
      @writes = 0
    end

    def fail! = @mode = :down
    def recover! = @mode = :up
    def explode! = @mode = :broken

    def with(&)
      case @mode
      when :down then yield FailingConn.new
      when :broken then raise 'not a connection error'
      else
        @writes += 1
        @real_pool.with(&)
      end
    end
  end

  def queued_payloads
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def queued_args
    queued_payloads.map { |p| p['args'] }
  end

  def queue_length
    @pool.with { |c| c.call('LLEN', "queue:#{@queue}") }
  end

  # Fake connection that raises on any pipeline operation. Mimics a dead
  # socket: pipelined block runs, the first call inside raises.
  class FailingConn
    def pipelined
      yield self
    end

    def call(*)
      raise RedisClient::ConnectionError, 'simulated outage'
    end
  end
end

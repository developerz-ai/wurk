# frozen_string_literal: true

require_relative '../test_helper'

# Real-Redis exercise of Wurk::Scheduled::Enq + Poller. Each test owns a
# unique sorted-set key + queue name so parallel runs can't collide on the
# global `schedule` / `retry` / `queue:default` keys.
class ScheduledPollerTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns       = "sched-#{Process.pid}-#{object_id}"
    @queue    = "q-#{@ns}"
    @schedule = "schedule-#{@ns}"
    @retry    = "retry-#{@ns}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:average_scheduled_poll_interval] = 1
    @pool = @config.default_capsule.redis_pool
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
    @cleanup_keys = [@queue_list = "queue:#{@queue}", @schedule, @retry]
  end

  def teardown
    @pool.with do |c|
      c.call('UNLINK', *@cleanup_keys)
      c.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  def schedule_job(set:, at:, queue: @queue, klass: 'Worker', args: ['x'])
    job = { 'class' => klass, 'args' => args, 'jid' => SecureRandom.hex(12), 'queue' => queue, 'retry' => true }
    @pool.with { |c| c.call('ZADD', set, at.to_s, Wurk.dump_json(job)) }
    job
  end

  # --- shape ----------------------------------------------------------

  def test_sets_constant
    assert_equal %w[retry schedule], Wurk::Scheduled::SETS
  end

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::Scheduled, Sidekiq::Scheduled
  end

  def test_lua_zpopbyscore_matches_lua_module
    assert_equal Wurk::Lua::ZPOPBYSCORE, Wurk::Scheduled::LUA_ZPOPBYSCORE
    assert_equal Wurk::Lua::ZPOPBYSCORE, Wurk::Scheduled::Enq::LUA_ZPOPBYSCORE
  end

  def test_poller_initial_wait_constant
    assert_equal 10, Wurk::Scheduled::Poller::INITIAL_WAIT
  end

  def test_enq_includes_component
    assert_includes Wurk::Scheduled::Enq.ancestors, Wurk::Component
  end

  def test_poller_includes_component
    assert_includes Wurk::Scheduled::Poller.ancestors, Wurk::Component
  end

  # --- Enq#enqueue_jobs ----------------------------------------------

  def test_enqueue_promotes_past_due_schedule_job_to_queue
    schedule_job(set: @schedule, at: Time.now.to_f - 5)

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    assert_equal(0, @pool.with { |c| c.call('ZCARD', @schedule) })
    assert_equal(1, @pool.with { |c| c.call('LLEN', @queue_list) })
    assert_equal(1, @pool.with { |c| c.call('SISMEMBER', 'queues', @queue) })
  end

  def test_enqueue_promotes_past_due_retry_job_to_queue
    schedule_job(set: @retry, at: Time.now.to_f - 1)

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@retry])

    assert_equal(0, @pool.with { |c| c.call('ZCARD', @retry) })
    assert_equal(1, @pool.with { |c| c.call('LLEN', @queue_list) })
  end

  # --- ReliableEnq (#166, atomic promote, no pop→push loss window) ---------

  def test_reliable_enq_atomically_promotes_due_jobs_to_their_queue
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)

    Wurk::Scheduled::ReliableEnq.new(@config).enqueue_jobs([@schedule])

    @pool.with do |c|
      assert_equal 0, c.call('ZCARD', @schedule)
      assert_equal 1, c.call('LLEN', @queue_list)
      promoted = Wurk.load_json(c.call('LRANGE', @queue_list, 0, -1).first)
      # Promotion restamps enqueued_at (immediate-queue arrival); strip it so the
      # rest equals the scheduled payload. Freshness has its own test below.
      promoted.delete('enqueued_at')

      assert_equal job, promoted
      assert_equal 1, c.call('SISMEMBER', 'queues', @queue)
    end
  end

  # Reliable promotion stamps a fresh integer enqueued_at, matching the default
  # Enq path (whose client push restamps it). Both schedulers emit wire-identical
  # promoted payloads (spec §7.1).
  def test_reliable_enq_stamps_fresh_enqueued_at_on_promotion
    schedule_job(set: @schedule, at: Time.now.to_f - 5)
    before = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)

    Wurk::Scheduled::ReliableEnq.new(@config).enqueue_jobs([@schedule])

    promoted = Wurk.load_json(@pool.with { |c| c.call('LRANGE', @queue_list, 0, -1).first })

    assert_kind_of Integer, promoted['enqueued_at']
    assert_operator promoted['enqueued_at'], :>=, before
  end

  def test_reliable_enq_leaves_future_jobs_in_set
    schedule_job(set: @schedule, at: Time.now.to_f + 600)

    Wurk::Scheduled::ReliableEnq.new(@config).enqueue_jobs([@schedule])

    assert_equal(1, @pool.with { |c| c.call('ZCARD', @schedule) })
    assert_equal(0, @pool.with { |c| c.call('LLEN', @queue_list) })
  end

  def test_enqueue_leaves_future_jobs_in_set
    schedule_job(set: @schedule, at: Time.now.to_f + 600)

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    assert_equal(1, @pool.with { |c| c.call('ZCARD', @schedule) })
    assert_equal(0, @pool.with { |c| c.call('LLEN', @queue_list) })
  end

  def test_enqueue_drains_multiple_due_jobs_in_one_call
    3.times { |i| schedule_job(set: @schedule, at: Time.now.to_f - 10 + i) }

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    assert_equal(0, @pool.with { |c| c.call('ZCARD', @schedule) })
    assert_equal(3, @pool.with { |c| c.call('LLEN', @queue_list) })
  end

  def test_enqueue_strips_at_field_when_repushing
    schedule_job(set: @schedule, at: Time.now.to_f - 1)

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    raw = @pool.with { |c| c.call('RPOP', @queue_list) }

    refute_nil raw

    payload = Wurk.load_json(raw)

    refute_includes payload.keys, 'at'
    assert_equal @queue, payload['queue']
  end

  def test_terminate_short_circuits_loop
    enq = Wurk::Scheduled::Enq.new(@config)
    enq.terminate
    schedule_job(set: @schedule, at: Time.now.to_f - 1)

    enq.enqueue_jobs([@schedule])

    assert_equal(1, @pool.with { |c| c.call('ZCARD', @schedule) })
    assert_equal(0, @pool.with { |c| c.call('LLEN', @queue_list) })
  end

  # A raising push on one due job must not abort the drain: the remaining due
  # jobs still get promoted, and the failure is reported to the error handlers.
  # (The popped-then-failed job is lost — the default scheduler's known pop→push
  # tradeoff; ReliableEnq is the loss-free path.)
  # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
  def test_drain_continues_after_a_failing_push_and_reports_it
    2.times { |i| schedule_job(set: @schedule, at: Time.now.to_f - 10 + i) }
    captured = []
    @config.error_handlers.clear
    @config.error_handlers << ->(ex, _ctx, _cfg) { captured << ex }

    enq = Wurk::Scheduled::Enq.new(@config)
    pushed = []
    calls = 0
    client = Object.new
    client.define_singleton_method(:push) do |job|
      calls += 1
      raise 'push blew up' if calls == 1

      pushed << job
    end
    enq.instance_variable_set(:@client, client)

    enq.enqueue_jobs([@schedule])

    assert_equal 0, @pool.with { |c| c.call('ZCARD', @schedule) }, 'both due jobs must be popped despite the raise'
    assert_equal 1, pushed.size, 'the second job must still be pushed after the first raises'
    assert_equal 1, captured.size
    assert_equal 'push blew up', captured.first.message
  end
  # rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

  # ZPOPBYSCORE claims no apply-safety, so a read timeout reaches #drain_set
  # instead of being replayed. The outcome of that pop is unknown, so the set's
  # drain ends there while its sibling still drains on the same tick.
  def test_pop_read_timeout_ends_the_set_and_leaves_the_sibling_draining
    drain_with_failing_pop

    assert_equal 1, @pool.with { |c| c.call('ZCARD', @schedule) }, 'the timed-out set must be left alone'
    assert_equal 0, @pool.with { |c| c.call('ZCARD', @retry) }, 'the sibling set must still drain'
  end

  # Unknown outcome, not "nothing due": a pop that may have taken a job down
  # with it is reported rather than swallowed.
  def test_pop_read_timeout_is_reported_with_the_set_it_hit
    captured = drain_with_failing_pop
    sets = captured.map { |(_, ctx)| ctx[:set] }

    assert_equal [@schedule], sets
    assert_instance_of RedisClient::ReadTimeoutError, captured.dig(0, 0)
  end

  # Drains both sets through an Enq whose first pop raises; returns the
  # [exception, context] pairs the error handlers captured.
  def drain_with_failing_pop
    sets = [@schedule, @retry]
    sets.each { |set| schedule_job(set: set, at: Time.now.to_f - 10) }
    captured = capture_errors
    enq = Wurk::Scheduled::Enq.new(@config)
    enq.instance_variable_set(:@config, PopFailingConfig.new(@config))
    enq.enqueue_jobs(sets)
    captured
  end

  # Swaps the error handlers for one that records [exception, context].
  def capture_errors
    captured = []
    @config.error_handlers.replace([->(ex, ctx, _cfg) { captured << [ex, ctx] }])
    captured
  end

  # Fails the first pop, then is the real config — the shape of a read timeout
  # landing on ZPOPBYSCORE after the pool has refused to replay it.
  class PopFailingConfig
    def initialize(real)
      @real = real
      @calls = 0
    end

    def redis(**, &)
      @calls += 1
      raise RedisClient::ReadTimeoutError, 'pop timed out' if @calls == 1

      @real.redis(**, &)
    end

    def respond_to_missing?(name, include_private = false)
      @real.respond_to?(name, include_private) || super
    end

    def method_missing(name, ...)
      @real.public_send(name, ...)
    end
  end

  # --- Poller#enqueue -----------------------------------------------

  def test_poller_enqueue_delegates_to_configured_enq
    spy = Class.new do
      attr_reader :calls

      def initialize(_) = @calls = 0
      def enqueue_jobs(*) = (@calls += 1)
    end
    @config[:scheduled_enq] = spy

    poller = Wurk::Scheduled::Poller.new(@config)
    poller.enqueue

    assert_equal 1, poller.instance_variable_get(:@enq).calls
  end

  def test_poller_enqueue_swallows_enq_exceptions
    boom = Class.new do
      def initialize(_); end
      def enqueue_jobs(*) = raise 'boom'
    end
    @config[:scheduled_enq] = boom
    captured = []
    @config.error_handlers.clear
    @config.error_handlers << ->(ex, _ctx, _cfg) { captured << ex }

    Wurk::Scheduled::Poller.new(@config).enqueue

    assert_equal 1, captured.size
    assert_equal 'boom', captured.first.message
  end

  # --- Poller#random_poll_interval -----------------------------------

  def test_random_poll_interval_uses_low_cluster_formula_below_ten
    @config[:poll_interval_average] = 10
    poller = build_poller_with_rng_and_count(rand_value: 0.5, process_count: 4)

    # interval=10 → 10*0.5 + 10/2 = 10.0
    assert_in_delta 10.0, poller.send(:random_poll_interval), 0.0001
  end

  def test_random_poll_interval_uses_high_cluster_formula_at_ten_plus
    @config[:poll_interval_average] = 5
    poller = build_poller_with_rng_and_count(rand_value: 0.25, process_count: 20)

    # interval=5 → 5*0.25*2 = 2.5
    assert_in_delta 2.5, poller.send(:random_poll_interval), 0.0001
  end

  def test_scaled_poll_interval_multiplies_by_average
    @config[:average_scheduled_poll_interval] = 7
    poller = Wurk::Scheduled::Poller.new(@config)

    assert_equal 21, poller.send(:scaled_poll_interval, 3)
  end

  def test_process_count_floored_to_one
    poller = Wurk::Scheduled::Poller.new(@config)
    poller.define_singleton_method(:cleanup) { 0 }

    assert_equal 1, poller.send(:process_count)
  end

  # --- initial_wait / wait short-circuit on @done --------------------
  # After `terminate` sets @done, both wait loops must skip the sleeper
  # entirely (the `unless @done` else side) and return immediately so a
  # shutdown can't be blocked by a pending poll interval.

  def test_initial_wait_returns_immediately_when_terminated
    poller = Wurk::Scheduled::Poller.new(@config)
    poller.terminate

    completed = false
    thread = Thread.new do
      poller.send(:initial_wait)
      completed = true
    end

    assert thread.join(1), 'initial_wait must not block once @done is set'
    assert completed
  end

  def test_wait_returns_immediately_when_terminated
    poller = Wurk::Scheduled::Poller.new(@config)
    poller.terminate

    completed = false
    thread = Thread.new do
      poller.send(:wait)
      completed = true
    end

    assert thread.join(1), 'wait must not block once @done is set'
    assert completed
  end

  # terminate is a barrier: Launcher#stop clears the heartbeat right after, so
  # a sweep still in flight would promote jobs for a process that is gone.
  def test_terminate_joins_and_clears_the_thread
    @config[:scheduler_initial_wait] = 0.01
    poller = Wurk::Scheduled::Poller.new(@config)
    sweeps = Queue.new
    poller.define_singleton_method(:enqueue) { sweeps << :s }

    thread = poller.start
    sweeps.pop(timeout: 5)
    poller.terminate

    refute_predicate thread, :alive?, 'terminate must join the scheduler thread'
    assert_nil poller.instance_variable_get(:@thread)
  ensure
    thread&.kill
  end

  # A sweep wedged past JOIN_TIMEOUT (Thread#join returns nil) must keep @thread
  # set, so the next #start returns it rather than spawning a second scheduler
  # thread alongside the one still promoting.
  def test_terminate_keeps_a_thread_that_outlives_the_join
    @config[:scheduler_initial_wait] = 0.01
    poller = Wurk::Scheduled::Poller.new(@config)
    sweeps = Queue.new
    poller.define_singleton_method(:enqueue) { sweeps << :s }

    thread = poller.start
    sweeps.pop(timeout: 5)
    thread.define_singleton_method(:join) { |_timeout = nil| nil }
    poller.terminate

    assert_same thread, poller.instance_variable_get(:@thread), 'a wedged thread must stay tracked'
    assert_same thread, poller.start, 'start must not spawn a second thread alongside it'
  ensure
    poller&.instance_variable_set(:@thread, nil)
    thread&.kill
  end

  private

  def build_poller_with_rng_and_count(rand_value:, process_count:)
    poller = Wurk::Scheduled::Poller.new(@config)
    poller.rnd = Class.new do
      def initialize(v) = @v = v
      def rand = @v
    end.new(rand_value)
    poller.define_singleton_method(:process_count) { process_count }
    poller
  end
end

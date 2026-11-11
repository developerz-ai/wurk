# frozen_string_literal: true

require_relative '../test_helper'

# Real-Redis exercise of Wurk::Scheduled::Enq + Poller. Each test owns a
# unique sorted-set key + queue name so parallel runs can't collide on the
# global `schedule` / `retry` / `queue:default` keys.
class ScheduledPollerTest < Wurk::Test::UnitCase
  parallelize_me!

  class PromotionStamp
    def call(_klass, job, _queue, _pool)
      job['promoted_by_middleware'] = true
      yield
    end
  end

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
    promoted = Wurk::Metrics::ProcessCounters.labelled(:scheduler_promoted).fetch(@schedule, 0)

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    assert_equal promoted + 1, Wurk::Metrics::ProcessCounters.labelled(:scheduler_promoted)[@schedule]
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

  # K6: an undecodable retry member used to abort the promote script on every
  # sweep, and because `retry` drains first it starved `schedule` cluster-wide.
  def test_reliable_enq_poison_retry_member_goes_dead_without_starving_schedule
    @pool.with { |c| c.call('ZADD', @retry, (Time.now.to_f - 50).to_s, 'garbage{') }
    schedule_job(set: @retry, at: Time.now.to_f - 10)
    schedule_job(set: @schedule, at: Time.now.to_f - 5)

    Wurk::Scheduled::ReliableEnq.new(@config).enqueue_jobs([@retry, @schedule])

    @pool.with do |c|
      assert_equal 0, c.call('ZCARD', @retry)
      assert_equal 0, c.call('ZCARD', @schedule)
      assert_equal 2, c.call('LLEN', @queue_list)
      assert_equal ['garbage{'], c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1)
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

  # --- claim: a failure costs a delay or a duplicate, never the job -----

  def test_a_member_stays_in_its_set_until_its_push_succeeded
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
    seen = nil
    pool = @pool
    set = @schedule
    enq = enq_with_push { |_| seen = pool.with { |c| c.call('ZRANGE', set, 0, -1) } }

    enq.enqueue_jobs([@schedule])

    assert_equal [Wurk.dump_json(job)], seen
    assert_equal(0, @pool.with { |c| c.call('ZCARD', @schedule) })
  end

  def test_client_middleware_runs_on_promotion
    @config.client_middleware.add(PromotionStamp)
    schedule_job(set: @schedule, at: Time.now.to_f - 5)

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    queued = @pool.with { |c| c.call('LRANGE', @queue_list, 0, -1) }.map { |raw| JSON.parse(raw) }

    assert_equal([true], queued.map { |job| job['promoted_by_middleware'] })
  end

  def test_a_middleware_halting_the_push_still_consumes_the_member
    schedule_job(set: @schedule, at: Time.now.to_f - 5)

    enq_with_push { |_| nil }.enqueue_jobs([@schedule])

    assert_equal(0, @pool.with { |c| c.call('ZCARD', @schedule) })
  end

  # Both the push and the write-back refused, as on a store out of memory: the
  # destructive pop this replaced lost the job right here.
  def test_a_refused_push_and_refused_write_back_keep_the_member
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
    capture_errors
    enq = enq_with_push { |_| raise RedisClient::OutOfMemoryError, 'OOM' }
    enq.instance_variable_set(:@config, WriteBackFailingConfig.new(@config))

    enq.enqueue_jobs([@schedule])

    assert_equal([Wurk.dump_json(job)], @pool.with { |c| c.call('ZRANGE', @schedule, 0, -1) })
  end

  # The server applied the claim and the reply never arrived.
  def test_a_lost_claim_reply_loses_nothing_and_the_lease_brings_the_job_back
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
    @config[:scheduled_claim_lease] = 0.05
    capture_errors
    enq = Wurk::Scheduled::Enq.new(@config)
    enq.instance_variable_set(:@config, ReplyLosingConfig.new(@config))

    enq.enqueue_jobs([@schedule])

    assert_equal 0, @pool.with { |c| c.call('LLEN', @queue_list) }, 'nothing was seen, so nothing was pushed'
    assert_equal(1, @pool.with { |c| c.call('ZCARD', @schedule) })

    sleep_until { @pool.with { |c| c.call('ZCOUNT', @schedule, '-inf', Time.now.to_f.to_s) } == 1 }
    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    assert_equal [job['jid']], queued_jids
  end

  # kill -9 between the claim and the push.
  def test_a_process_dying_after_its_claim_loses_nothing
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
    @config[:scheduled_claim_lease] = 0.05
    pid = fork do
      Wurk::Scheduled::Enq.new(@config).send(:claim_due, @schedule, Time.now.to_f.to_s)
      Process.kill('KILL', Process.pid)
    end
    Process.wait(pid)

    assert_equal 0, @pool.with { |c|
      c.call('ZCOUNT', @schedule, '-inf', (Time.now.to_f - 1).to_s)
    }, 'the claim applied'
    sleep_until { @pool.with { |c| c.call('ZCOUNT', @schedule, '-inf', Time.now.to_f.to_s) } == 1 }
    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    assert_equal [job['jid']], queued_jids
  end

  # The accepted cost: the job ran, its ZREM did not land, so it runs again.
  def test_a_failed_settle_duplicates_rather_than_drops
    schedule_job(set: @schedule, at: Time.now.to_f - 5)
    @config[:scheduled_claim_lease] = 0.05
    captured = capture_errors
    enq = Wurk::Scheduled::Enq.new(@config)
    enq.instance_variable_set(:@config, SettleFailingConfig.new(@config))

    enq.enqueue_jobs([@schedule])

    assert_equal(%w[scheduler_settle], captured.map { |(_, ctx)| ctx[:context] })
    assert_equal(1, @pool.with { |c| c.call('LLEN', @queue_list) })
    assert_equal(1, @pool.with { |c| c.call('ZCARD', @schedule) })
  end

  def test_concurrent_pollers_promote_each_member_once
    jobs = Array.new(60) { |i| schedule_job(set: @schedule, at: Time.now.to_f - 60 + i) }

    Array.new(4) { Thread.new { Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule]) } }.each(&:join)

    assert_equal jobs.map { |job| job['jid'] }.sort, queued_jids.sort
  end

  def test_a_drain_spans_many_claim_batches_in_score_order
    jobs = Array.new((Wurk::Scheduled::Enq::CLAIM_BATCH * 2) + 3) do |i|
      schedule_job(set: @schedule, at: Time.now.to_f - 60 + i)
    end

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    assert_equal jobs.map { |job| job['jid'] }, queued_jids.reverse
  end

  # A claimed batch must not sit out a full lease because shutdown arrived.
  def test_terminate_hands_the_rest_of_the_batch_straight_back
    jobs = Array.new(3) { |i| schedule_job(set: @schedule, at: Time.now.to_f - 60 + i) }
    enq = Wurk::Scheduled::Enq.new(@config)
    client = Object.new
    client.define_singleton_method(:push) { |_| enq.terminate }
    enq.instance_variable_set(:@client, client)

    enq.enqueue_jobs([@schedule])

    now = Time.now.to_f.to_s

    assert_equal(jobs.size - 1, @pool.with { |c| c.call('ZCOUNT', @schedule, '-inf', now) })
  end

  def test_a_store_refusing_writes_during_the_claim_is_reported_and_the_sibling_set_still_drains
    sets = [@schedule, @retry]
    sets.each { |set| schedule_job(set: set, at: Time.now.to_f - 10) }
    captured = capture_errors
    enq = Wurk::Scheduled::Enq.new(@config)
    enq.instance_variable_set(:@config, PopFailingConfig.new(@config, RedisClient::OutOfMemoryError.new('OOM')))

    enq.enqueue_jobs(sets)

    assert_equal(1, @pool.with { |c| c.call('ZCARD', @schedule) })
    assert_equal(0, @pool.with { |c| c.call('ZCARD', @retry) })
    assert_equal([@schedule], captured.map { |(_, ctx)| ctx[:set] })
  end

  # With reliable_push! a promoted job must reach Redis before its member goes, or
  # a crash loses the only copy.
  def test_a_tripped_reliable_push_circuit_does_not_take_promoted_jobs_into_memory
    with_reliable_push do
      job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
      Wurk::Client::Buffered.circuit.trip(@pool)

      Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

      assert_equal 0, Wurk::Client::Buffered.buffer_size
      assert_equal [job['jid']], queued_jids
      assert_equal(0, @pool.with { |c| c.call('ZCARD', @schedule) })
    end
  end

  def test_a_failing_promotion_under_reliable_push_raises_into_the_release_path
    with_reliable_push do
      job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
      capture_errors
      down = Object.new
      down.define_singleton_method(:with) { |**, &_| raise RedisClient::CannotConnectError, 'down' }
      enq = Wurk::Scheduled::Enq.new(@config)
      enq.instance_variable_set(:@client, Wurk::Client.new(pool: down, config: @config))

      enq.enqueue_jobs([@schedule])

      assert_equal 0, Wurk::Client::Buffered.buffer_size
      assert_equal([Wurk.dump_json(job)], @pool.with { |c| c.call('ZRANGE', @schedule, 0, -1) })
    end
  end

  # A deterministic error on one job's key says nothing about the rest of the batch.
  def test_a_job_failing_on_its_own_key_does_not_hold_back_the_batch
    broken = "#{@queue}-broken"
    @pool.with { |c| c.call('SET', "queue:#{broken}", 'not-a-list') }
    @cleanup_keys << "queue:#{broken}"
    poison = schedule_job(set: @schedule, at: Time.now.to_f - 60, queue: broken)
    healthy = Array.new(25) { |i| schedule_job(set: @schedule, at: Time.now.to_f - 50 + i) }
    captured = capture_errors

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    assert_equal healthy.map { |job| job['jid'] }.sort, queued_jids.sort
    assert_equal([Wurk.dump_json(poison)], @pool.with { |c| c.call('ZRANGE', @schedule, 0, -1) })
    @pool.with { |c| c.call('SREM', 'queues', broken) }

    assert_equal 1, captured.size, 'reported once per lease, not per poll'
  end

  def test_a_poison_job_is_left_under_its_lease_rather_than_retried_every_poll
    broken = "#{@queue}-broken"
    @pool.with { |c| c.call('SET', "queue:#{broken}", 'not-a-list') }
    @cleanup_keys << "queue:#{broken}"
    schedule_job(set: @schedule, at: Time.now.to_f - 60, queue: broken)
    captured = capture_errors
    enq = Wurk::Scheduled::Enq.new(@config)

    3.times { enq.enqueue_jobs([@schedule]) }

    @pool.with { |c| c.call('SREM', 'queues', broken) }

    assert_equal 1, captured.size
  end

  # LOADING and Dragonfly's out-of-memory reply are plain CommandErrors, yet the
  # whole store is refusing, so another nine attempts would only add noise.
  def test_a_store_refusing_as_a_plain_command_error_ends_the_batch
    2.times { |i| schedule_job(set: @schedule, at: Time.now.to_f - 60 + i) }
    capture_errors
    ['LOADING Dragonfly is loading the dataset in memory', 'ERR Out of memory'].each do |reply|
      calls = 0
      enq_with_push do |_|
        calls += 1
        raise RedisClient::CommandError, reply
      end.enqueue_jobs([@schedule])

      assert_equal 1, calls, reply
    end
  end

  # The next claim's window cannot pass the server's time, so a score taken from a
  # clock running ahead would keep the job out for as long as the clock is ahead.
  def test_a_released_member_is_due_at_once_even_from_a_host_whose_clock_runs_ahead
    schedule_job(set: @schedule, at: Time.now.to_f - 5)
    capture_errors
    enq = enq_with_push { |_| raise RedisClient::CannotConnectError, 'blip' }
    enq.singleton_class.prepend(Module.new { def real_time = super + 3600 })

    enq.enqueue_jobs([@schedule])

    pushed = []
    enq_with_push { |job| pushed << job }.enqueue_jobs([@schedule])

    assert_equal 1, pushed.size
  end

  # A host far behind must not cut a lease short, and one far ahead must not take
  # another host's lease for due.
  def test_the_lease_runs_on_the_server_clock
    schedule_job(set: @schedule, at: Time.now.to_f - 5)
    @pool.with do |c|
      claim = ->(now) { Wurk::Lua::Loader.eval_cached(c, :scheduled_claim, keys: [@schedule], argv: [now, 60, 10]) }

      assert_equal 1, claim.call(Time.now.to_f + 3600).size, 'the first claim takes the job'
      assert_empty claim.call(Time.now.to_f + 3600), 'a clock an hour ahead must not see it as due'
      assert_operator c.call('ZSCORE', @schedule, c.call('ZRANGE', @schedule, 0, 0).first).to_f, :>, Time.now.to_f + 30
    end
  end

  # The spec's signature is `initialize(container)`, and a capsule is one.
  def test_a_capsule_is_a_valid_container
    capsule = Wurk::Capsule.new('t', @config)

    assert_equal Wurk::Scheduled::Enq::CLAIM_LEASE, Wurk::Scheduled::Enq.new(capsule).instance_variable_get(:@lease)
  end

  # A starved local pool says nothing about the payload.
  def test_a_starved_pool_does_not_bury_the_member
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
    capture_errors
    enq = enq_with_push { |_| raise ConnectionPool::TimeoutError, 'starved' }

    enq.enqueue_jobs([@schedule])

    assert_equal([Wurk.dump_json(job)], @pool.with { |c| c.call('ZRANGE', @schedule, 0, -1) })
    assert_equal(0, @pool.with { |c| c.call('ZCARD', Wurk::Keys::DEAD) })
  end

  # --- first sweep ------------------------------------------------------

  def test_the_first_sweep_is_jittered_across_a_fleet
    waits = Array.new(12) { first_sweep_wait(Wurk::Scheduled::Poller.new(@config)) }

    assert_operator waits.min, :>=, Wurk::Scheduled::Poller::INITIAL_WAIT
    assert_operator waits.max, :<, Wurk::Scheduled::Poller::INITIAL_WAIT + Wurk::Scheduled::Poller::INITIAL_JITTER
    assert_operator waits.max - waits.min, :>, 1
  end

  def test_an_explicit_initial_wait_is_taken_exactly
    @config[:scheduler_initial_wait] = 0.25

    assert_in_delta 0.25, first_sweep_wait(Wurk::Scheduled::Poller.new(@config))
  end

  # K20: a non-Redis push failure is permanent (it fails the same way on every
  # retry), so the popped member lands in dead byte-for-byte instead of vanishing.
  def test_permanently_failing_push_moves_the_member_to_dead
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
    raw = Wurk.dump_json(job)
    capture_errors
    enq = enq_with_push { |_| raise ArgumentError, 'rejected payload' }

    enq.enqueue_jobs([@schedule])

    @pool.with do |c|
      assert_equal 0, c.call('ZCARD', @schedule)
      assert_equal [raw], c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1)
    end
  end

  # A MULTI still applies the ZREM after a refused ZADD: Dragonfly at maxmemory
  # refuses it that way, a dead set of the wrong type does on any server.
  def test_a_refused_bury_keeps_the_member_scheduled
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
    @pool.with { |c| c.call('SET', Wurk::Keys::DEAD, 'not a sorted set') }
    capture_errors
    enq = enq_with_push { |_| raise ArgumentError, 'rejected payload' }

    begin
      enq.enqueue_jobs([@schedule])
    rescue RedisClient::CommandError
      nil
    end

    @pool.with do |c|
      assert_equal [Wurk.dump_json(job)], c.call('ZRANGE', @schedule, 0, -1)
    ensure
      c.call('DEL', Wurk::Keys::DEAD)
    end
  end

  # A Redis error on the push is transient: the member is handed back to its own
  # set, past this drain's window, so the next poll retries it.
  def test_push_failing_on_redis_puts_the_member_back_in_its_set
    job = schedule_job(set: @schedule, at: Time.now.to_f - 5)
    capture_errors
    calls = 0
    enq = enq_with_push do |_|
      calls += 1
      raise RedisClient::CannotConnectError, 'blip'
    end

    enq.enqueue_jobs([@schedule])

    assert_equal 1, calls, 'the released member must not be re-claimed within the same drain'
    @pool.with do |c|
      assert_equal [Wurk.dump_json(job)], c.call('ZRANGE', @schedule, 0, -1)
      assert_equal 0, c.call('ZCARD', Wurk::Keys::DEAD)
    end
  end

  # When the move to dead itself fails, both failures are reported and the drain
  # carries on; the member stays in its set under its lease.
  def test_restore_failure_is_reported_not_raised
    schedule_job(set: @schedule, at: Time.now.to_f - 5)
    captured = capture_errors
    enq = enq_with_push { |_| raise 'push failed' }
    real = @config
    failing = Object.new
    failing.define_singleton_method(:redis) do |**kw, &blk|
      @n = (@n || 0) + 1
      raise RedisClient::CannotConnectError, 'down' if @n == 2

      real.redis(**kw, &blk)
    end
    failing.define_singleton_method(:handle_exception) { |ex, ctx| real.handle_exception(ex, ctx) }
    enq.instance_variable_set(:@config, failing)

    enq.enqueue_jobs([@schedule])

    assert_equal(%w[scheduler_promote scheduler_restore], captured.map { |(_, ctx)| ctx[:context] })
  end

  # K20: a payload stock Sidekiq wrote (Wurk-only option keys with values Wurk's
  # client validation rejects) must never be dropped by the promoter — it is
  # either promoted or preserved in dead.
  def test_stock_sidekiq_payload_with_odd_timeout_is_not_lost_by_the_promoter
    job = { 'class' => 'Worker', 'args' => [1], 'jid' => SecureRandom.hex(12), 'queue' => @queue,
            'retry' => true, 'timeout' => '30', 'track' => 'yes' }
    @pool.with { |c| c.call('ZADD', @schedule, (Time.now.to_f - 5).to_s, Wurk.dump_json(job)) }
    capture_errors

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([@schedule])

    @pool.with do |c|
      assert_equal 0, c.call('ZCARD', @schedule)
      assert_equal 1, c.call('LLEN', @queue_list) + c.call('ZCARD', Wurk::Keys::DEAD)
    end
  end

  def enq_with_push(&)
    enq = Wurk::Scheduled::Enq.new(@config)
    client = Object.new
    client.define_singleton_method(:push, &)
    enq.instance_variable_set(:@client, client)
    enq
  end

  # A read timeout on the claim reaches #drain_set instead of being replayed. The
  # set's drain ends there while its sibling still drains on the same tick.
  def test_pop_read_timeout_ends_the_set_and_leaves_the_sibling_draining
    drain_with_failing_pop

    assert_equal 1, @pool.with { |c| c.call('ZCARD', @schedule) }, 'the timed-out set must be left alone'
    assert_equal 0, @pool.with { |c| c.call('ZCARD', @retry) }, 'the sibling set must still drain'
  end

  # Unknown outcome, not "nothing due", so it is reported rather than swallowed.
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

  def with_reliable_push
    Wurk::Client.reliable_push!
    Wurk::Client::Buffered.reset!
    yield
  ensure
    Wurk::Client::Buffered.reset!
  end

  def queued_jids
    @pool.with { |c| c.call('LRANGE', @queue_list, 0, -1) }.map { |raw| JSON.parse(raw)['jid'] }
  end

  def sleep_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk 'condition never held' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
  end

  # What the poller would ask its condition variable to sleep for.
  def first_sweep_wait(poller)
    recorded = nil
    sleeper = Object.new
    sleeper.define_singleton_method(:wait) { |_mutex, timeout| recorded = timeout }
    poller.instance_variable_set(:@sleeper, sleeper)
    poller.send(:initial_wait)
    recorded
  end

  # Fails the first claim, then is the real config: the shape of a read timeout
  # landing on the claim after the pool has refused to replay it.
  class PopFailingConfig
    def initialize(real, error = RedisClient::ReadTimeoutError.new('pop timed out'))
      @real = real
      @error = error
      @calls = 0
    end

    def redis(**, &)
      @calls += 1
      raise @error if @calls == 1

      @real.redis(**, &)
    end

    def respond_to_missing?(name, include_private = false)
      @real.respond_to?(name, include_private) || super
    end

    def method_missing(name, ...)
      @real.public_send(name, ...)
    end
  end

  # Passes the first checkout (the claim) through and refuses the rest.
  class WriteBackFailingConfig < PopFailingConfig
    def redis(**, &)
      @calls += 1
      raise RedisClient::OutOfMemoryError, 'OOM' if @calls > 1

      @real.redis(**, &)
    end
  end

  # Applies the first checkout on the server, then loses the reply.
  class ReplyLosingConfig < PopFailingConfig
    def redis(**, &)
      @calls += 1
      reply = @real.redis(**, &)
      raise RedisClient::ReadTimeoutError, 'reply lost' if @calls == 1

      reply
    end
  end

  # Fails only the ZREM that settles a batch.
  class SettleFailingConfig < PopFailingConfig
    def redis(idempotent: false, &)
      raise RedisClient::CannotConnectError, 'down' if idempotent

      @real.redis(&)
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

  # K1: the interval read (SCARD / ProcessSet prune) is Redis I/O outside
  # #enqueue's rescue. A blip there used to kill the scheduler thread for good;
  # it must be reported and the loop must sweep again on the next wake.
  def test_scheduler_thread_survives_a_redis_error_in_wait
    @config[:scheduler_initial_wait] = 0.01
    @config[:poll_interval_average] = 0.02
    captured = capture_errors
    poller = Wurk::Scheduled::Poller.new(@config)
    sweeps = Queue.new
    poller.define_singleton_method(:enqueue) { sweeps << :s }
    blips = 0
    poller.define_singleton_method(:cleanup) do
      blips += 1
      raise RedisClient::CannotConnectError, 'redis down' if blips == 1

      1
    end

    thread = poller.start

    3.times { refute_nil sweeps.pop(timeout: 5), 'the scheduler must keep sweeping after the blip' }

    assert_predicate thread, :alive?
    assert_equal(['scheduler_wait'], captured.map { |(_, ctx)| ctx[:context] })
    assert_instance_of RedisClient::CannotConnectError, captured.dig(0, 0)
  ensure
    poller&.terminate
  end

  def test_wait_falls_back_to_the_unscaled_average_when_the_count_read_fails
    @config[:average_scheduled_poll_interval] = 7
    capture_errors
    poller = Wurk::Scheduled::Poller.new(@config)
    poller.define_singleton_method(:cleanup) { raise RedisClient::CannotConnectError, 'redis down' }

    assert_equal 7, poller.send(:poll_interval_or_fallback)
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

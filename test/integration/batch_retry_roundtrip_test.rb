# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Top-level worker classes so Object.const_get resolves inside forked
# children (constant table is inherited; Minitest lexical scope is not).

# Never fails — the batch's "already-succeeded" sibling job.
class BatchRoundtripSimpleWorker
  include Wurk::Job

  def perform(redis_url, marker_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', marker_key, '1', 'EX', 60)
  ensure
    client&.close
  end
end

# Fails on its first attempt, succeeds on every attempt after. `attempts_key`
# is INCRed on every dispatch so the test can observe exactly when the first
# (failing) attempt happened without racing the retry promotion.
class BatchRoundtripFlakyWorker
  include Wurk::Job

  sidekiq_options retry: true
  # A few real seconds of headroom (plus job_retry's own jitter) so the test
  # can positively observe the "still pending, not yet acked" window before
  # forcing the retry ZSET entry due for promotion.
  sidekiq_retry_in { 5 }

  def perform(redis_url, attempts_key, marker_key)
    client = RedisClient.config(url: redis_url).new_client
    attempt = client.call('INCR', attempts_key)
    raise "boom on attempt #{attempt}" if attempt == 1

    client.call('SET', marker_key, '1', 'EX', 60)
  ensure
    client&.close
  end
end

# perform_in-in-batch sentinel: only runs once promoted off the `schedule`
# ZSET onto its queue.
class BatchRoundtripScheduledWorker
  include Wurk::Job

  def perform(redis_url, marker_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', marker_key, '1', 'EX', 60)
  ensure
    client&.close
  end
end

# Holds the concurrent limiter's only slot until `release_key` appears —
# pins open the exact window in which a sibling batch job hits OverLimit.
class BatchRoundtripLimiterGateWorker
  include Wurk::Job

  def perform(redis_url, limiter_name, running_key, release_key)
    client = RedisClient.config(url: redis_url).new_client
    limiter = Wurk::Limiter.concurrent(limiter_name, 1, wait_timeout: 30)
    limiter.within_limit do
      client.call('SET', running_key, '1', 'EX', 60)
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 20
      until client.call('EXISTS', release_key) == 1
        if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
          raise "#{release_key} never set — test driver lost?"
        end

        sleep 0.05
      end
    end
  ensure
    client&.close
  end
end

# Waits for the gate to actually hold the limiter slot, then attempts to
# acquire it itself with `wait_timeout: 0` — guaranteed OverLimit on the
# first (gate-held) attempt, guaranteed success on a later attempt (after
# the gate releases and the limiter reschedule promotes this job again).
class BatchRoundtripLimiterContenderWorker
  include Wurk::Job

  def perform(redis_url, limiter_name, running_key, attempts_key, marker_key)
    client = RedisClient.config(url: redis_url).new_client
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 20
    until client.call('EXISTS', running_key) == 1
      if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
        raise "#{running_key} never set — gate job never started?"
      end

      sleep 0.05
    end
    client.call('INCR', attempts_key)
    limiter = Wurk::Limiter.concurrent(limiter_name, 1, wait_timeout: 0, backoff: ->(*) { 0.05 })
    limiter.within_limit { client.call('SET', marker_key, '1', 'EX', 60) }
  ensure
    client&.close
  end
end

# Real forks, real Redis, real perform. Headline regression for 04-batch-
# scheduler-logic: a batch containing a retried, a scheduled, or a rate-
# limited job must complete with correct `total`/`pending` counters and fire
# `:success` exactly once. Before the SADD-guard fix (BATCH_PUSH/BATCH_SCHEDULE)
# and the Limiter::Rescheduled control signal, any re-push of a live jid
# double-counted `pending` (so `:success` never fired) or the outer Batch
# middleware acked a job that hadn't actually run. NEVER mock Redis here.
class BatchRetryRoundtripTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 20.0
  POLL_INTERVAL = 0.1
  # How long a "not yet fired" assertion must HOLD once the observation
  # window is provably open before we trust it (vs. just winning a read race).
  HOLD_WINDOW = 0.4

  def setup
    super
    @ns = "batchrt-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @config = build_config
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @bids = []
  end

  def teardown
    cleanup_batches!
    cleanup_queue!
    purge_stray_due_entries!('retry')
    purge_stray_due_entries!('schedule')
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  # The headline regression (plan 04, "Done when"): batch of 2, one job fails
  # once then succeeds on retry. `:success` must fire exactly once, `total`
  # stays 2 (never re-incremented by the retry re-push), `pending` ends at 0.
  def test_batch_with_one_flaky_job_retries_to_success_once_with_correct_counters # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Minitest/MultipleAssertions
    marker_a     = "#{@ns}-marker-a"
    attempts_key = "#{@ns}-attempts"
    marker_b     = "#{@ns}-marker-b"
    batch = track(Wurk::Batch.new)
    batch.jobs do
      Wurk::Client.push('class' => BatchRoundtripSimpleWorker.name,
                        'args' => [Wurk::Test.redis_url, marker_a],
                        'queue' => @queue_name, 'retry' => false)
      Wurk::Client.push('class' => BatchRoundtripFlakyWorker.name,
                        'args' => [Wurk::Test.redis_url, attempts_key, marker_b],
                        'queue' => @queue_name, 'retry' => true)
    end

    assert_equal '2', batch_field(batch, 'total'), 'total must count both jobs at registration'

    with_swarm(topology(concurrency: 2)) do
      assert wait_until { @observer.call('EXISTS', marker_a) == 1 },
             "simple job's marker never appeared — batch job never ran"
      assert wait_until { @observer.call('GET', attempts_key).to_i >= 1 },
             'flaky job never made its first (failing) attempt'

      # Observation window: the simple job succeeded (pending 2→1) and the
      # flaky job has failed once and is awaiting retry promotion — pending
      # must hold at 1 and :success/:complete must not have fired.
      hold_deadline = monotonic_now + HOLD_WINDOW
      while monotonic_now < hold_deadline
        assert_equal '1', batch_field(batch, 'pending'),
                     'pending must reflect only the simple job succeeding, not a premature ack'
        assert_nil batch_field(batch, 'success'), ':success fired before the flaky job actually succeeded'
        sleep POLL_INTERVAL
      end

      force_due_now!('retry', attempts_key)

      assert wait_until { @observer.call('EXISTS', marker_b) == 1 },
             'flaky job never succeeded on retry'
      assert wait_until { batch_field(batch, 'success') == '1' },
             "batch :success never fired within #{POLL_TIMEOUT}s"
    end

    assert_equal '2', batch_field(batch, 'total'), 'retry re-push must not re-increment total'
    assert_equal '0', batch_field(batch, 'pending'), 'pending must reach 0 once both jobs have succeeded'
    assert_equal '1', batch_field(batch, 'complete')
    assert_equal 2, @observer.call('GET', attempts_key).to_i,
                 'flaky job must run exactly twice: once failing, once succeeding'
  end

  # A `perform_in` job registered inside `batch.jobs` must move `total`/
  # `pending` at creation (BATCH_SCHEDULE) — otherwise the empty-marker check
  # sees no counter movement and fires `:complete`/`:success` immediately,
  # while the real job still sits unpromoted in `schedule`.
  def test_perform_in_inside_batch_does_not_fire_premature_complete # rubocop:disable Metrics/AbcSize,Minitest/MultipleAssertions
    marker = "#{@ns}-scheduled-marker"
    batch = track(Wurk::Batch.new)
    target_at = ::Process.clock_gettime(::Process::CLOCK_REALTIME) + 0.5
    batch.jobs do
      Wurk::Client.push('class' => BatchRoundtripScheduledWorker.name,
                        'args' => [Wurk::Test.redis_url, marker],
                        'queue' => @queue_name, 'retry' => false, 'at' => target_at)
    end

    assert_equal '1', batch_field(batch, 'total'),
                 'BATCH_SCHEDULE must register the scheduled job at creation'
    assert_equal '1', batch_field(batch, 'pending')
    assert_nil batch_field(batch, 'complete'),
               ':complete must not fire while the scheduled job still sits in `schedule`'

    with_swarm(topology(concurrency: 1)) do
      assert wait_until { @observer.call('EXISTS', marker) == 1 },
             'scheduled job was never promoted + run'
      assert wait_until { batch_field(batch, 'complete') == '1' },
             "batch :complete never fired within #{POLL_TIMEOUT}s"
    end

    assert_equal '1', batch_field(batch, 'total'), 'promotion re-push must not re-increment total'
    assert_equal '0', batch_field(batch, 'pending')
    assert_equal '1', batch_field(batch, 'success')
  end

  # Limiter × Batch (#18): a job that hits OverLimit inside a batch gets
  # rescheduled by Wurk::Limiter::ServerMiddleware, which raises
  # Wurk::Limiter::Rescheduled — neither success nor failure. The outer Batch
  # middleware must skip BOTH acks (no premature success, no spurious retry
  # bookkeeping) until the job actually runs to completion.
  def test_limiter_reschedule_inside_batch_does_not_fire_premature_ack # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Minitest/MultipleAssertions
    limiter_name = "#{@ns}-limiter"
    running_key  = "#{@ns}-running"
    release_key  = "#{@ns}-release"
    attempts_key = "#{@ns}-contender-attempts"
    marker       = "#{@ns}-contender-marker"
    batch = track(Wurk::Batch.new)
    batch.jobs do
      Wurk::Client.push('class' => BatchRoundtripLimiterGateWorker.name,
                        'args' => [Wurk::Test.redis_url, limiter_name, running_key, release_key],
                        'queue' => @queue_name, 'retry' => false)
      Wurk::Client.push('class' => BatchRoundtripLimiterContenderWorker.name,
                        'args' => [Wurk::Test.redis_url, limiter_name, running_key, attempts_key, marker],
                        'queue' => @queue_name, 'retry' => false)
    end

    assert_equal '2', batch_field(batch, 'total')

    with_swarm(topology(concurrency: 2)) do
      assert wait_until { @observer.call('EXISTS', running_key) == 1 },
             'gate job never acquired the limiter slot'
      assert wait_until { @observer.call('GET', attempts_key).to_i >= 1 },
             'contender job never attempted to acquire the (held) limiter slot'

      # The contender's first attempt must OverLimit → reschedule → neither
      # ack fires. Hold this window before releasing the gate.
      hold_deadline = monotonic_now + HOLD_WINDOW
      while monotonic_now < hold_deadline
        refute_equal '1', @observer.call('GET', marker), 'contender must not succeed while the gate holds the slot'
        assert_equal '2', batch_field(batch, 'pending'),
                     'pending must not drop — a rescheduled job is neither success nor failure'
        assert_nil batch_field(batch, 'success'), ':success fired before the contender actually ran'
        sleep POLL_INTERVAL
      end

      @observer.call('SET', release_key, '1', 'EX', 60)

      assert wait_until { @observer.call('EXISTS', marker) == 1 },
             'contender job never succeeded after the gate released'
      assert wait_until { batch_field(batch, 'success') == '1' },
             "batch :success never fired within #{POLL_TIMEOUT}s"
    ensure
      @observer.call('SET', release_key, '1', 'EX', 60) # never strand the gated worker
    end

    assert_equal '2', batch_field(batch, 'total'), 'limiter reschedule re-push must not re-increment total'
    assert_equal '0', batch_field(batch, 'pending')
    assert_operator @observer.call('GET', attempts_key).to_i, :>=, 2,
                    'contender must have attempted at least twice: once OverLimit, once successful'
  end

  private

  def build_config
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:timeout] = 5
    # Fast scheduler cadence so retry/schedule promotion happens quickly.
    config[:poll_interval_average] = 0.25
    config[:scheduler_initial_wait] = 0.1
    # Require-time registrations only touch the global Wurk.configuration; a
    # fresh Configuration starts with a bare chain, and without these the
    # ack/rescue paths under test never run at all.
    config.server_middleware.add(Wurk::Batch::ServerMiddleware)
    config.server_middleware.add(Wurk::Limiter::ServerMiddleware)
    config
  end

  def cleanup_batches!
    @observer&.call('UNLINK', *@bids.flat_map { |bid| Wurk::Batch.keys_for(bid) })
    @bids.each { |bid| @observer&.call('ZREM', 'batches', bid) }
  end

  def cleanup_queue!
    @observer&.call('DEL', "queue:#{@queue_name}", private_queue_key(@queue_name))
    @observer&.call('SREM', 'queues', @queue_name)
  end

  def track(batch)
    @bids << batch.bid
    batch
  end

  def topology(concurrency:)
    Wurk::Topology.flat(count: 1, queues: [@queue_name], concurrency: concurrency)
  end

  def with_swarm(topo)
    swarm = Wurk::Swarm.new(topology: topo, config: @config, shutdown_timeout: 5)
    swarm.boot(install_signals: false)
    supervisor = Thread.new { swarm.supervise }
    yield
  ensure
    swarm&.shutdown(timeout: 5)
    supervisor&.join(10)
  end

  # Finds the due-set member belonging to `needle` (a Redis key baked into
  # the job's args) and rescoring it to 0 so the next (fast) poll cycle
  # promotes it immediately — bypasses job_retry's real backoff+jitter
  # without touching the counting/registration logic under test.
  def force_due_now!(set_key, needle)
    deadline = monotonic_now + POLL_TIMEOUT
    loop do
      raise "#{needle} never appeared in `#{set_key}` — retry never scheduled?" if monotonic_now > deadline

      member = @observer.call('ZRANGE', set_key, 0, -1).find { |m| m.include?(needle) }
      if member
        @observer.call('ZADD', set_key, 0, member)
        return
      end
      sleep POLL_INTERVAL
    end
  end

  # Belt-and-suspenders: an aborted test (assertion failure mid-flight)
  # could leave one of our jobs sitting in the shared global `retry`/
  # `schedule` ZSET. Sweep anything tagged with our namespace so it can't
  # linger and confuse a later test class sharing this worker's Redis DB.
  def purge_stray_due_entries!(set_key)
    members = @observer.call('ZRANGE', set_key, 0, -1).select { |m| m.include?(@ns) }
    @observer.call('ZREM', set_key, *members) unless members.empty?
  end

  def batch_field(batch, field)
    @observer.call('HGET', "b-#{batch.bid}", field)
  end

  def wait_until # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + POLL_TIMEOUT
    until monotonic_now > deadline
      return true if yield

      sleep POLL_INTERVAL
    end
    false
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end
end

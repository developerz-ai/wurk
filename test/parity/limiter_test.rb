# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'securerandom'

# Parity oracle for Sidekiq Enterprise rate limiting, written from
# docs/target/sidekiq-ent.md §1, not from Wurk's limiter code. Over-limit jobs
# run through a real `Sidekiq::Processor` over the default configuration's
# server chain, the path a drop-in app's jobs take, against real Redis.
#
# Enforced:
# - §1.1 the five constructors + `unlimited`, and their kwargs.
# - §1.3 `within_limit` per type: concurrent slots + `policy: :ignore` +
#   blocking until a slot frees; bucket / window counts incl. `used:`;
#   leaky fill; points `estimate:` + `handle.points_used`.
# - §1.4 `OverLimit#limiter`; the server middleware's `overrated` counter,
#   backoff precedence (limiter proc > global > default formula), same-queue
#   reschedule, and the reschedule cap. The cap's terminal state is the dead
#   set, per docs/idea/parity-divergences.md "Limiter reschedule cap routes to
#   the dead set, not re-raise".
# - §1.5 name / type / options / size / status / reset / delete.
# - §1.6 `configure` defaults; `errors` extends what counts as OverLimit;
#   `redis` routes limiter traffic to a dedicated pool.
# - §1.7 the `lmtr*` key shapes and that keys carry `EXPIRE = ttl`.
class LimiterParityTest < Wurk::Test::UnitCase
  parallelize_me!

  DEFAULT_TTL = 90 * 24 * 3600
  DAY = 24 * 3600

  class ExternalRateLimitError < StandardError; end

  module Log
    MUTEX = Mutex.new
    @ran = []
    @backoff = []
    def self.ran(name) = MUTEX.synchronize { @ran << name }
    def self.ran?(name) = MUTEX.synchronize { @ran.include?(name) }
    def self.backoff(entry) = MUTEX.synchronize { @backoff << entry }
    def self.backoffs = MUTEX.synchronize { @backoff.dup }

    def self.clear
      MUTEX.synchronize do
        @ran.clear
        @backoff.clear
      end
    end
  end

  # Every limiter is built inside perform, under the name the test passes in:
  # §1.2 names are the shared identity, so this is also the named-reuse path.
  class LimitedJob
    include Sidekiq::Job

    def perform(name, mode)
      limiter(name, mode).within_limit { Log.ran(name) }
    end

    private

    def limiter(name, mode)
      case mode
      when 'default' then Sidekiq::Limiter.bucket(name, 1, :hour, wait_timeout: 0)
      when 'backoff'
        Sidekiq::Limiter.bucket(name, 1, :hour, wait_timeout: 0, backoff: lambda { |lim, job, exc|
          Log.backoff([lim.name, job['overrated'], exc.class])
          42
        })
      when 'resched2' then Sidekiq::Limiter.bucket(name, 1, :hour, wait_timeout: 0, reschedule: 2)
      end
    end
  end

  class ExternalErrorJob
    include Sidekiq::Job

    def perform(_name)
      raise ExternalRateLimitError, 'remote said 429'
    end
  end

  def setup
    super
    @name = "lp-#{SecureRandom.hex(4)}"
    @queue = "lpq-#{SecureRandom.hex(4)}"
    @capsule = Sidekiq::Capsule.new("limiter-parity-#{@name}", Sidekiq.default_configuration)
    @capsule.queues = [@queue]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
    Log.clear
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
  ensure
    super
  end

  # --- §1.1 / §1.5 constructors + introspection ---------------------------

  def test_constructors_expose_name_type_and_options
    {
      concurrent: Sidekiq::Limiter.concurrent(@name, 2, wait_timeout: 1, lock_timeout: 10),
      bucket: Sidekiq::Limiter.bucket(@name, 5, :second),
      window: Sidekiq::Limiter.window(@name, 5, :minute),
      leaky: Sidekiq::Limiter.leaky(@name, 10, :minute),
      points: Sidekiq::Limiter.points(@name, 100, 5)
    }.each do |type, lim|
      assert_equal @name, lim.name
      assert_equal type, lim.type
      assert_kind_of Hash, lim.options
    end
  end

  def test_unlimited_ignores_its_arguments_and_always_yields
    lim = Sidekiq::Limiter.unlimited(@name, 1, :second, wait_timeout: 0, anything: true)
    runs = 0
    50.times { lim.within_limit { runs += 1 } }

    assert_equal 50, runs
    assert_equal :unlimited, lim.type
  end

  # --- §1.3 concurrent ----------------------------------------------------

  def test_concurrent_raises_over_limit_when_no_slot_and_wait_timeout_zero
    lim = Sidekiq::Limiter.concurrent(@name, 1, wait_timeout: 0)
    err = hold(lim) { assert_raises(Sidekiq::Limiter::OverLimit) { lim.within_limit { flunk 'entered' } } }

    assert_same lim, err.limiter
    assert_operator Sidekiq::Limiter::OverLimit, :<, StandardError
  end

  def test_concurrent_policy_ignore_skips_the_block_silently
    lim = Sidekiq::Limiter.concurrent(@name, 1, wait_timeout: 0, policy: :ignore)
    entered = false
    hold(lim) { lim.within_limit { entered = true } }

    refute entered
  end

  def test_concurrent_slot_is_freed_on_block_exit
    lim = Sidekiq::Limiter.concurrent(@name, 1, wait_timeout: 0)
    3.times { lim.within_limit { nil } }
    entered = false
    lim.within_limit { entered = true }

    assert entered
  end

  def test_concurrent_slot_is_freed_when_the_block_raises
    lim = Sidekiq::Limiter.concurrent(@name, 1, wait_timeout: 0)
    assert_raises(RuntimeError) { lim.within_limit { raise 'boom' } }
    entered = false
    lim.within_limit { entered = true }

    assert entered
  end

  def test_concurrent_waiter_enters_once_the_holder_releases
    lim = Sidekiq::Limiter.concurrent(@name, 1, wait_timeout: 5)
    held = Queue.new
    release = Queue.new
    holder = Thread.new { lim.within_limit { (held << true) && release.pop } }
    held.pop
    waiter = Thread.new { Sidekiq::Limiter.concurrent(@name, 1, wait_timeout: 5).within_limit { :entered } }
    sleep 0.2 # give the waiter time to reach the limiter; it must still be blocked

    assert_predicate waiter, :alive?
    release << true

    assert_equal :entered, waiter.value
    holder.join
  end

  def test_concurrent_slot_zset_scored_at_now_plus_lock_timeout
    lim = Sidekiq::Limiter.concurrent(@name, 2, lock_timeout: 120)
    lim.within_limit do
      key = "lmtr-cs:#{@name}"

      assert_equal 'zset', redis('TYPE', key)
      scores = zrange_with_scores(key).map(&:last)

      assert_equal 1, scores.size
      assert_in_delta Time.now.to_f + 120, scores.first, 5
      assert_equal 1, lim.size
    end

    assert_equal 0, lim.size
  end

  def test_concurrent_status_carries_the_documented_counters
    lim = Sidekiq::Limiter.concurrent(@name, 1, wait_timeout: 0)
    lim.within_limit { nil }
    keys = lim.status.keys.map(&:to_s)

    %w[held held_time immediate waited wait_time overages reclaimed].each do |k|
      assert_includes keys, k
    end
  end

  # --- §1.3 bucket --------------------------------------------------------

  def test_bucket_allows_count_per_interval_then_over_limit
    lim = Sidekiq::Limiter.bucket(@name, 3, :hour, wait_timeout: 0)
    3.times { lim.within_limit { nil } }

    assert_raises(Sidekiq::Limiter::OverLimit) { lim.within_limit { flunk 'entered' } }
  end

  def test_bucket_used_charges_n_units
    lim = Sidekiq::Limiter.bucket(@name, 3, :hour, wait_timeout: 0)
    lim.within_limit(used: 3) { nil }

    assert_raises(Sidekiq::Limiter::OverLimit) { lim.within_limit { flunk 'entered' } }
  end

  def test_bucket_counter_key_is_per_epoch_string
    Sidekiq::Limiter.bucket(@name, 3, :hour, wait_timeout: 0).within_limit { nil }
    keys = scan("lmtr-b:#{@name}:*")

    assert_equal 1, keys.size
    assert_match(/\Almtr-b:#{Regexp.escape(@name)}:\d+\z/, keys.first)
    assert_equal 'string', redis('TYPE', keys.first)
    assert_equal '1', redis('GET', keys.first)
  end

  def test_same_name_shares_state_across_instances
    2.times { Sidekiq::Limiter.bucket(@name, 2, :hour, wait_timeout: 0).within_limit { nil } }

    assert_raises(Sidekiq::Limiter::OverLimit) do
      Sidekiq::Limiter.bucket(@name, 2, :hour, wait_timeout: 0).within_limit { flunk 'entered' }
    end
  end

  def test_reset_clears_usage
    lim = Sidekiq::Limiter.bucket(@name, 1, :hour, wait_timeout: 0)
    lim.within_limit { nil }
    lim.reset
    entered = false
    lim.within_limit { entered = true }

    assert entered
  end

  def test_delete_removes_every_key_for_the_name
    lim = Sidekiq::Limiter.bucket(@name, 1, :hour, wait_timeout: 0)
    lim.within_limit { nil }

    refute_empty scan("*#{@name}*")
    lim.delete

    assert_empty scan("*#{@name}*")
  end

  # --- §1.3 window --------------------------------------------------------

  def test_window_allows_count_then_over_limit_with_a_zset
    lim = Sidekiq::Limiter.window(@name, 2, :minute, wait_timeout: 0)
    2.times { lim.within_limit { nil } }

    assert_raises(Sidekiq::Limiter::OverLimit) { lim.within_limit { flunk 'entered' } }
    assert_equal 'zset', redis('TYPE', "lmtr-w:#{@name}")
  end

  def test_window_accepts_a_raw_integer_interval_and_used
    lim = Sidekiq::Limiter.window(@name, 4, 30, wait_timeout: 0)
    lim.within_limit(used: 4) { nil }

    assert_raises(Sidekiq::Limiter::OverLimit) { lim.within_limit { flunk 'entered' } }
  end

  # --- §1.3 leaky ---------------------------------------------------------

  def test_leaky_fills_to_bucket_size_then_over_limit_with_a_hash
    lim = Sidekiq::Limiter.leaky(@name, 2, 60, wait_timeout: 0)
    2.times { lim.within_limit { nil } }

    assert_raises(Sidekiq::Limiter::OverLimit) { lim.within_limit { flunk 'entered' } }
    assert_equal 'hash', redis('TYPE', "lmtr-l:#{@name}")
  end

  # --- §1.3 points --------------------------------------------------------

  def test_points_raises_immediately_when_estimate_exceeds_balance
    lim = Sidekiq::Limiter.points(@name, 100, 1)
    lim.within_limit(estimate: 60) { nil }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Sidekiq::Limiter::OverLimit) { lim.within_limit(estimate: 60) { flunk 'entered' } }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
    assert_equal 'hash', redis('TYPE', "lmtr-p:#{@name}")
  end

  def test_points_used_refunds_the_unspent_estimate
    lim = Sidekiq::Limiter.points(@name, 100, 1)
    lim.within_limit(estimate: 60) { |handle| handle.points_used(10) }
    entered = false
    lim.within_limit(estimate: 60) { entered = true }

    assert entered
  end

  # --- §1.7 keys + TTL ----------------------------------------------------

  def test_metadata_hash_and_listing_set
    Sidekiq::Limiter.bucket(@name, 3, :hour, wait_timeout: 0).within_limit { nil }

    assert_equal 'hash', redis('TYPE', "lmtr:#{@name}")
    assert_equal 'set', redis('TYPE', 'lmtr-list')
    assert_equal 1, redis('SISMEMBER', 'lmtr-list', @name)
  end

  def test_keys_default_to_a_ninety_day_ttl
    Sidekiq::Limiter.concurrent(@name, 2).within_limit { nil }
    Sidekiq::Limiter.window("#{@name}-w", 2, :minute).within_limit { nil }

    ["lmtr:#{@name}", "lmtr-w:#{@name}-w"].each do |key|
      assert_in_delta DEFAULT_TTL, redis('TTL', key), 60, key
    end
  end

  def test_custom_ttl_is_applied
    Sidekiq::Limiter.bucket(@name, 3, :hour, wait_timeout: 0, ttl: 2 * DAY).within_limit { nil }

    assert_in_delta 2 * DAY, redis('TTL', "lmtr:#{@name}"), 60
  end

  def test_no_key_lives_shorter_than_the_24h_minimum
    Sidekiq::Limiter.window(@name, 2, :minute, wait_timeout: 0, ttl: 60).within_limit { nil }
  rescue ArgumentError
    pass # rejecting a sub-minimum ttl also honours the 24h floor
  else
    scan("*#{@name}*").each { |key| assert_operator redis('TTL', key), :>=, DAY - 60, key }
  end

  # --- §1.4 server middleware --------------------------------------------

  def test_over_limit_reschedules_to_the_same_queue_with_default_backoff
    saturate
    jid = LimitedJob.set(queue: @queue).perform_async(@name, 'default')
    now = Time.now.to_f
    run_one

    refute Log.ran?(@name)
    job, score = scheduled(jid)

    assert_equal 1, job['overrated']
    assert_equal @queue, job['queue']
    assert_operator score, :>=, now + 300
    assert_operator score, :<=, now + 601 + 5
    assert_nil Sidekiq::RetrySet.new.find_job(jid)
  end

  def test_overrated_counter_increments_on_each_reschedule
    saturate
    jid = push_raw('default', 'overrated' => 3)
    run_one

    assert_equal 4, scheduled(jid).first['overrated']
  end

  def test_limiter_backoff_proc_wins_and_sees_the_incremented_counter
    saturate
    jid = LimitedJob.set(queue: @queue).perform_async(@name, 'backoff')
    now = Time.now.to_f
    with_global_backoff(->(*) { 9999 }) { run_one }

    assert_equal [[@name, 1, Sidekiq::Limiter::OverLimit]], Log.backoffs
    assert_in_delta now + 42, scheduled(jid).last, 5
  end

  def test_global_backoff_applies_when_the_limiter_has_none
    saturate
    jid = LimitedJob.set(queue: @queue).perform_async(@name, 'default')
    now = Time.now.to_f
    with_global_backoff(->(_lim, job, _exc) { 100 * job['overrated'] }) { run_one }

    assert_in_delta now + 100, scheduled(jid).last, 5
  end

  def test_reschedule_cap_default_twenty_ends_in_the_dead_set
    saturate
    below = push_raw('default', 'overrated' => 18)
    run_one

    assert_equal 19, scheduled(below).first['overrated']

    at_cap = push_raw('default', 'overrated' => 19)
    run_one

    assert_nil scheduled(at_cap)
    refute_nil Sidekiq::DeadSet.new.find_job(at_cap)
  end

  def test_per_limiter_reschedule_cap
    saturate
    first = push_raw('resched2')
    run_one

    assert_equal 1, scheduled(first).first['overrated']

    capped = push_raw('resched2', 'overrated' => 1)
    run_one

    assert_nil scheduled(capped)
    refute_nil Sidekiq::DeadSet.new.find_job(capped)
  end

  # --- §1.6 configure -----------------------------------------------------

  def test_configure_defaults
    Sidekiq::Limiter.configure do |config|
      assert_includes config.errors, Sidekiq::Limiter::OverLimit
      assert_respond_to config, :backoff=
      assert_respond_to config, :redis=
    end
  end

  def test_configured_errors_are_treated_as_over_limit
    jid = with_extra_error(ExternalRateLimitError) do
      id = ExternalErrorJob.set(queue: @queue).perform_async(@name)
      run_one
      id
    end
    job, = scheduled(jid)

    assert_equal 1, job['overrated']
    assert_nil Sidekiq::RetrySet.new.find_job(jid)
  end

  def test_dedicated_redis_pool_carries_limiter_traffic
    previous = nil
    Sidekiq::Limiter.configure do |config|
      previous = config.redis
      config.redis = { url: 'redis://127.0.0.1:1/0', size: 1 }
    end
    err = assert_raises(StandardError) { Sidekiq::Limiter.bucket(@name, 1, :hour).within_limit { nil } }

    refute_kind_of Sidekiq::Limiter::OverLimit, err
  ensure
    Sidekiq::Limiter.configure { |config| config.redis = previous }
  end

  private

  def redis(*cmd) = Sidekiq.redis { |c| c.call(*cmd) }

  def scan(pattern)
    Sidekiq.redis { |c| c.scan('MATCH', pattern, count: 1000).to_a }
  end

  # Holds one slot of +lim+ on another thread while the block runs.
  def hold(lim)
    held = Queue.new
    release = Queue.new
    holder = Thread.new { lim.within_limit { (held << true) && release.pop } }
    held.pop
    yield
  ensure
    release << true
    holder&.join
  end

  def saturate = Sidekiq::Limiter.bucket(@name, 1, :hour, wait_timeout: 0).within_limit { nil }

  def push_raw(mode, extra = {})
    Sidekiq::Client.push({ 'class' => LimitedJob, 'queue' => @queue, 'args' => [@name, mode] }.merge(extra))
  end

  def run_one
    @processor.process_one
  rescue StandardError
    nil # the job's fate is asserted from Redis, not from the processor's raise
  ensure
    @capsule.fetcher.flush_pending_acks
  end

  def scheduled(jid)
    zrange_with_scores('schedule').each do |payload, score|
      job = JSON.parse(payload)
      return [job, score] if job['jid'] == jid
    end
    nil
  end

  def zrange_with_scores(key)
    redis('ZRANGE', key, 0, -1, 'WITHSCORES').flatten.each_slice(2).map { |m, s| [m, s.to_f] }
  end

  def with_global_backoff(proc)
    previous = nil
    Sidekiq::Limiter.configure do |config|
      previous = config.backoff
      config.backoff = proc
    end
    yield
  ensure
    Sidekiq::Limiter.configure { |config| config.backoff = previous }
  end

  def with_extra_error(klass)
    Sidekiq::Limiter.configure { |config| config.errors << klass }
    yield
  ensure
    Sidekiq::Limiter.configure { |config| config.errors.delete(klass) }
  end
end

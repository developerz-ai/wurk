# frozen_string_literal: true

require_relative '../test_helper'

class PeriodicTickOptionsWorker
  include Wurk::Worker

  sidekiq_options queue: 'ptick-low', retry: 3, unique_for: 600, encrypt: true, expires_in: 3600

  def perform(*); end
end

class PeriodicTickPlainWorker
  include Wurk::Worker

  def perform(*); end
end

# A queue name the client refuses, so every push for it raises.
class PeriodicTickBrokenWorker
  include Wurk::Worker

  sidekiq_options queue: ''

  def perform(*); end
end

# The leader tick end to end against real Redis: real Manager registration,
# real LoopSet read, real claim script, real client push. Covers the 03-pro-ent
# cron cluster — E6 (worker options), E20 (unpause), E21 (no backfill),
# E28 (per-loop rescue), E24 (bare-Hash args).
#
# Not parallelize_me!: a tick fires every loop in the DB's shared `periodic`
# set, so it must not run beside the threaded cron unit tests that assert a
# loop of theirs did *not* fire.
class PeriodicTickTest < Wurk::Test::UnitCase
  def setup
    super
    @suffix = "ptick#{Process.pid}#{object_id}"
    @lids = []
    @queues = ['ptick-low']
    @log = StringIO.new
    @config = Wurk.configuration
    @poller = Wurk::Cron::Poller.new(@config)
    @poller.define_singleton_method(:leader?) { true }
    log = ::Logger.new(@log)
    @poller.define_singleton_method(:logger) { log }
  end

  def teardown
    @lids.each { |lid| Wurk::Cron.unregister(lid) }
    Wurk.redis do |c|
      @queues.each do |q|
        c.call('DEL', "queue:#{q}")
        c.call('SREM', 'queues', q)
      end
    end
  ensure
    super
  end

  # ---- E6: a tick is perform_async, so the worker's sidekiq_options apply ----

  def test_a_tick_lands_in_the_worker_queue_with_its_sidekiq_options
    register(PeriodicTickOptionsWorker.name)

    @poller.tick
    job = pop('ptick-low')

    refute_nil job, 'the tick must land in the queue the worker declares'
    assert_equal 3, job['retry']
    assert_equal 600, job['unique_for']
    assert job['encrypt']
    assert_in_delta (job['created_at'] / 1000.0) + 3600, job['expiry'], 1.0, 'expires_in is stamped into expiry'
  end

  def test_loop_queue_and_retry_override_the_worker_options
    queue = queue_named('override')
    register(PeriodicTickOptionsWorker.name, queue: queue, retry: false)

    @poller.tick
    job = pop(queue)

    refute_nil job
    assert_same false, job['retry']
    assert_equal 600, job['unique_for'], 'options the loop does not override still come from the worker'
    assert_nil pop('ptick-low')
  end

  def test_loop_queue_reports_the_worker_queue
    lp = register(PeriodicTickOptionsWorker.name)

    assert_equal 'ptick-low', Wurk::Cron::LoopSet.new.fetch(lp.lid).queue
  end

  # ---- E20: `paused` is the HASH field only ----

  def test_a_loop_registered_paused_runs_once_the_field_is_cleared
    queue = queue_named('paused')
    lp = register(PeriodicTickPlainWorker.name, queue: queue, paused: true)

    @poller.tick

    assert_nil pop(queue), 'registered paused: true starts paused'

    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'paused', '0') }

    refute_predicate Wurk::Cron::LoopSet.new.fetch(lp.lid), :paused?
    @poller.tick

    refute_nil pop(queue), 'an unpaused loop fires'
  end

  # ---- E21: no backfill ----

  # A minutely loop has an occurrence due whenever a leader ticks. Spending the
  # tick on the stale mark cost a minute at every leader change, and under churn
  # that was every minute: a leader that lives under two ticks fired nothing.
  def test_a_stale_slot_does_not_spend_the_tick_on_the_occurrence_due_now
    queue = queue_named('stale')
    lp = register(PeriodicTickPlainWorker.name, queue: queue)
    stale = ((::Time.now.to_i - 3600) / 60) * 60
    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'lf', (stale - 60).to_s, 'nf', stale.to_s) }

    @poller.tick

    refute_nil pop(queue), 'the occurrence due now fires'
    assert_nil pop(queue), 'once: the hour missed in between is not backfilled'
    assert_equal 1, lp.history.size
    nf = Wurk.redis { |c| c.call('HGET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'nf') }.to_i

    assert_operator nf, :>, ::Time.now.to_i, 'the mark advances to the next future slot'
    assert_match(/missed tick.*not backfilled/, @log.string)

    @poller.tick

    assert_nil pop(queue), 'the same occurrence does not fire on the next tick'
  end

  def test_a_stale_slot_with_nothing_due_now_is_skipped
    queue = queue_named('hourly')
    lp = register(PeriodicTickPlainWorker.name, schedule: minute_ago(600), queue: queue)
    stale = ::Time.now.to_i - 600
    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'nf', ((stale / 60) * 60).to_s) }

    @poller.tick

    assert_nil pop(queue)
    assert_empty lp.history
    assert_match(/missed tick.*not backfilled/, @log.string)
  end

  def test_a_loop_whose_last_fire_predates_an_outage_fires_only_what_is_due
    queue = queue_named('outage')
    lp = register(PeriodicTickPlainWorker.name, queue: queue)
    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'lf', (::Time.now.to_i - 7200).to_s) }

    @poller.tick

    refute_nil pop(queue)
    assert_nil pop(queue), 'two hours of missed minutes are not backfilled'
  end

  # Two leaders co-exist for up to the gate's cache. Whichever occurrence they
  # work out, the mark they both read lets one of them through.
  def test_two_leaders_racing_a_stale_mark_fire_once
    queue = queue_named('race')
    lp = register(PeriodicTickPlainWorker.name, queue: queue)
    second = Wurk::Cron::Poller.new(@config)
    second.define_singleton_method(:leader?) { true }
    second.define_singleton_method(:logger) { ::Logger.new(IO::NULL) }

    10.times do |round|
      stale = ((::Time.now.to_i - 600 - (round * 60)) / 60) * 60
      Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'nf', stale.to_s) }

      [@poller, second].map { |poller| Thread.new { poller.enqueue_if_due(lp) } }.each(&:join)

      refute_nil pop(queue), "round #{round}: one of them fires"
      assert_nil pop(queue), "round #{round}: only one"
    end
  end

  # ---- the grace ----

  def test_the_default_grace_skips_a_slot_three_minutes_late
    queue = queue_named('late')
    lp = register(PeriodicTickPlainWorker.name, schedule: minute_ago(180), queue: queue)
    make_due(lp, 180)

    @poller.tick

    assert_nil pop(queue)
  end

  def test_a_grace_of_five_minutes_fires_a_slot_three_minutes_late
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.periodic { |m| m.grace = 300 }
    poller = Wurk::Cron::Poller.new(config)
    poller.define_singleton_method(:leader?) { true }
    queue = queue_named('graced')
    lp = register(PeriodicTickPlainWorker.name, schedule: minute_ago(180), queue: queue)
    make_due(lp, 180)

    poller.enqueue_if_due(lp)

    refute_nil pop(queue)
  end

  # A numeric string used to be stored as is, and every due loop then raised on
  # every tick with nothing failing at boot.
  def test_a_grace_from_the_environment_or_a_duration_is_coerced_to_seconds
    require 'active_support'
    require 'active_support/duration'

    { '300' => 300.0, 90 => 90.0, 1.5 => 1.5, ActiveSupport::Duration.build(300) => 300.0 }.each do |given, seconds|
      config = Wurk::Configuration.new
      config.periodic { |m| m.grace = given }

      assert_equal seconds, config[:cron_grace]
    end
  end

  def test_a_numeric_string_grace_still_fires_a_late_slot
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.periodic { |m| m.grace = '300' }
    poller = Wurk::Cron::Poller.new(config)
    queue = queue_named('string-grace')
    lp = register(PeriodicTickPlainWorker.name, schedule: minute_ago(180), queue: queue)
    make_due(lp, 180)

    poller.enqueue_if_due(lp)

    refute_nil pop(queue)
  end

  def test_a_grace_that_is_not_a_positive_finite_number_raises_at_config_time
    [0, -1, '-5', nil, '', 'soon', '5 minutes', Float::INFINITY, Float::NAN, Object.new].each do |bad|
      assert_raises(ArgumentError, "#{bad.inspect} must be refused") do
        Wurk::Configuration.new.periodic { |m| m.grace = bad }
      end
    end
  end

  # ---- a new leader ----

  def test_winning_the_lock_ticks_without_waiting_out_the_interval
    config = Wurk.configuration
    queue = queue_named('gain')
    lp = register(PeriodicTickPlainWorker.name, queue: queue)
    make_due(lp, 1)
    poller = Wurk::Cron::Poller.new(config)
    leader = Wurk::Leader.new(config: config)
    poller.start

    leader.acquire

    assert wait_until { lp.history.size == 1 }, 'the win ticks; the interval is a minute away'
    refute_nil pop(queue)
  ensure
    poller&.terminate
    leader&.release
  end

  def test_a_stopped_poller_leaves_no_hook_behind
    hooks = Wurk.configuration[:lifecycle_events][:leader]
    before = hooks.size
    poller = Wurk::Cron::Poller.new(Wurk.configuration)

    poller.start

    assert_equal before + 1, hooks.size
    poller.terminate

    assert_equal before, hooks.size
  end

  # ---- E28: one raising loop does not starve the others ----

  def test_a_raising_loop_does_not_starve_the_loops_after_it
    register(PeriodicTickBrokenWorker.name, queue: '')
    healthy = queue_named('healthy')
    register(PeriodicTickPlainWorker.name, queue: healthy)

    @poller.tick

    refute_nil pop(healthy), 'the healthy loop fires despite the broken one'
  end

  # SMEMBERS order is unspecified on Redis < 7.2, so the test above may draw
  # the healthy loop first; this one is order-independent: every loop raises,
  # and every loop must still be attempted.
  def test_every_loop_is_attempted_when_each_one_raises
    mgr = Wurk::Cron::Manager.new
    3.times { |i| @lids << mgr.register('* * * * *', PeriodicTickPlainWorker.name, args: [i]).lid }
    attempted = []
    @poller.define_singleton_method(:enqueue_if_due) do |lp, *|
      attempted << lp.lid
      raise 'boom'
    end

    @poller.tick

    assert_empty @lids - attempted
  end

  # ---- E24: args: {hash} is one argument ----

  def test_a_bare_hash_args_option_is_passed_as_one_argument
    queue = queue_named('hash')
    register(PeriodicTickPlainWorker.name, queue: queue, args: { 'tenant' => 7 })

    @poller.tick

    assert_equal [{ 'tenant' => 7 }], pop(queue)['args']
  end

  private

  # A schedule matching only the wall-clock minute `seconds` ago, so nothing else
  # falls due before the test ends.
  def minute_ago(seconds)
    "#{::Time.at(::Time.now.to_i - seconds).utc.min} * * * *"
  end

  def make_due(loop_obj, seconds_ago)
    slot = ((::Time.now.to_i - seconds_ago) / 60) * 60
    slot = ::Time.now.to_i - seconds_ago if seconds_ago < 60
    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{loop_obj.lid}", 'nf', slot.to_s) }
  end

  def wait_until(timeout: 5)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    true
  end

  def register(klass, schedule: '* * * * *', **)
    lp = Wurk::Cron::Manager.new.register(schedule, klass, **)
    @lids << lp.lid
    lp
  end

  def queue_named(tag)
    "ptick-#{tag}-#{@suffix}".tap { |q| @queues << q }
  end

  def pop(queue)
    raw = Wurk.redis { |c| c.call('RPOP', "queue:#{queue}") }
    raw && JSON.parse(raw)
  end
end

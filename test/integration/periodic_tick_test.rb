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

  def test_a_slot_missed_by_an_hour_is_skipped_not_backfilled
    queue = queue_named('stale')
    lp = register(PeriodicTickPlainWorker.name, queue: queue)
    stale = ((::Time.now.to_i - 3600) / 60) * 60
    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'lf', (stale - 60).to_s, 'nf', stale.to_s) }

    @poller.tick

    assert_nil pop(queue), 'an hour-old slot must not be fired on recovery'
    assert_empty lp.history
    nf = Wurk.redis { |c| c.call('HGET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'nf') }.to_i

    assert_operator nf, :>, ::Time.now.to_i, 'the mark advances to the next future slot'
    assert_match(/missed tick.*not backfilled/, @log.string)

    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'nf', ((::Time.now.to_i / 60) * 60).to_s) }
    @poller.tick

    refute_nil pop(queue), 'the next on-time slot fires normally'
  end

  def test_a_loop_whose_last_fire_predates_an_outage_does_not_backfill
    queue = queue_named('outage')
    lp = register(PeriodicTickPlainWorker.name, queue: queue)
    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}", 'lf', (::Time.now.to_i - 7200).to_s) }

    @poller.tick

    assert_nil pop(queue)
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
    @poller.define_singleton_method(:enqueue_if_due) do |lp|
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

  def register(klass, **)
    lp = Wurk::Cron::Manager.new.register('* * * * *', klass, **)
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

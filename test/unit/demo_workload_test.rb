# frozen_string_literal: true

require_relative '../test_helper'

# Load the demo workload generator + its jobs straight from the dummy app
# (no Rails boot needed — they only depend on Wurk).
DEMO_APP = File.expand_path('../dummy/app', __dir__)
Dir[File.join(DEMO_APP, 'jobs/demo/*.rb')].each { |f| require f }
require File.join(DEMO_APP, 'workloads/demo/workload.rb')

# Exercises the enqueue/seed side of the demo workload generator (#33) against an
# isolated Redis DB: one `tick!` must light up every dashboard surface that is
# observable without a running worker — queues, scheduled, batches, limiters,
# cron — and the generator must be idempotent and self-heal after a flush. The
# retry/dead/throughput surfaces need a real worker and are covered by
# test/qa/demo_workload_driver.rb.
class DemoWorkloadTest < Wurk::Test::UnitCase
  DB = ENV.fetch('WURK_DEMO_TEST_DB', '15')

  def setup
    super
    url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0').sub(%r{/\d+\z}, "/#{DB}")
    @prev_config = Wurk.configuration
    cfg = Wurk::Configuration.new
    cfg.logger = Logger.new(IO::NULL)
    cfg.redis = { url: url }
    Wurk.instance_variable_set(:@configuration, cfg)
    Wurk.redis { |c| c.call('FLUSHDB') }
    @workload = Demo::Workload.new
  end

  def teardown
    Wurk.redis { |c| c.call('FLUSHDB') }
    Wurk.instance_variable_set(:@configuration, @prev_config)
    super
  end

  def test_one_tick_fills_the_primary_and_secondary_queues
    @workload.tick!

    assert_operator Wurk::Queue.new('default').size, :>, 0
    assert_operator(%w[high low].sum { |q| Wurk::Queue.new(q).size }, :>, 0)
  end

  def test_one_tick_schedules_future_jobs
    @workload.tick!

    assert_operator Wurk::ScheduledSet.new.size, :>, 0
  end

  def test_one_tick_creates_a_batch
    @workload.tick!

    assert_operator Wurk::BatchSet.new.size, :>, 0
  end

  def test_seeding_registers_both_limiters
    @workload.ensure_seeded!

    names = Wurk.redis { |c| c.call('SMEMBERS', 'lmtr-list') }

    assert_includes names, 'demo-emails'
    assert_includes names, 'demo-api'
  end

  def test_seeding_registers_cron_loops
    @workload.ensure_seeded!

    assert_operator Wurk::Cron::LoopSet.new.to_a.size, :>=, 2
  end

  def test_seeding_is_idempotent
    5.times { @workload.ensure_seeded! }

    # Deterministic lids + name-keyed limiters → no duplicates on re-seed.
    assert_equal 2, Wurk::Cron::LoopSet.new.to_a.size
    assert_equal(2, Wurk.redis { |c| c.call('SCARD', 'lmtr-list') })
  end

  def test_self_heals_after_a_redis_flush
    @workload.tick!
    Wurk.redis { |c| c.call('FLUSHDB') }

    @workload.tick!

    assert_operator Wurk::Queue.new('default').size, :>, 0
    assert_includes Wurk.redis { |c| c.call('SMEMBERS', 'lmtr-list') }, 'demo-emails'
  end
end

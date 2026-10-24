# frozen_string_literal: true

require_relative '../test_helper'

# Load the demo workload generator + its jobs straight from the dummy app
# (no Rails boot needed — they only depend on Wurk).
DEMO_APP = File.expand_path('../dummy/app', __dir__)
Dir[File.join(DEMO_APP, 'jobs/demo/*.rb')].each { |f| require f }
require File.join(DEMO_APP, 'workloads/demo/workload.rb')

# Exercises the demo workload generator (#33) against an isolated Redis DB:
# one `tick!` must light up every dashboard surface — queues, scheduled,
# batches, limiters, cron — and the generator must be idempotent and self-heal
# after a flush. The retry, dead, and throughput surfaces are exercised below
# with a real Processor driving the demo jobs, in this same file.
class DemoWorkloadTest < Wurk::Test::UnitCase
  # Isolation here is by dedicated Redis DB, NOT by the per-test key namespace
  # the rest of the suite uses. The generator and the Stats/Queue/Set classes it
  # drives write fixed *global* keys (`queue:default`, `schedule`, `dead`,
  # `lmtr-list`, the periodic set, …) that can't be prefixed, and the
  # RedisNamespace helper is still a stub. So this class points the global config
  # at the reserved DEDICATED_DB (15) and FLUSHDB's it — parallel workers are
  # capped to DBs 1..14 (see test_helper), so no worker is ever assigned this DB.
  # For that reason it does NOT call `parallelize_me!`: FLUSHDB-based isolation is
  # only safe with the tests run sequentially, which the per-class fork runner
  # already guarantees.
  DB = ENV.fetch('WURK_DEMO_TEST_DB', Wurk::Test::DEDICATED_DB.to_s)

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
    # The `rand` override on Demo::FlakyJob is a method on the class itself:
    # left behind, it would decide the demo job's fate for every other test
    # class that happens to run in this worker afterwards.
    Demo::FlakyJob.class_eval { remove_method(:rand) } if Demo::FlakyJob.method_defined?(:rand, false)
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

  def test_a_real_worker_moves_demo_failures_into_retry_and_dead_sets
    flaky_jid = Demo::FlakyJob.perform_async
    poison_jid = Demo::PoisonJob.perform_async
    processor = build_processor

    # Demo::FlakyJob raises only when `rand < 0.5`, so a single attempt would
    # put it in the retry set only half the time. Pin the coin so the run is
    # the same every time — without it this test is a coin flip that fails
    # the suite roughly one run in six.
    force_flaky_job_to_fail
    2.times { processor.process_one }

    retry_entry = Wurk::RetrySet.new.find_job(flaky_jid)
    dead_entry = Wurk::DeadSet.new.find_job(poison_jid)

    assert retry_entry, 'the flaky demo job must land in the retry set'
    assert_equal 'Demo::FlakyJob', retry_entry.klass
    assert dead_entry, 'the poison demo job must land in the dead set'
    assert_equal 'Demo::PoisonJob', dead_entry.klass
  end

  # The complement of the test above: the same demo job, forced to SUCCEED,
  # must reach neither the retry set nor the dead set. Without this the retry
  # assertion could pass for the wrong reason (a job that lands in the retry
  # set no matter what it does) and would not be evidence of anything.
  def test_a_real_worker_leaves_a_succeeding_flaky_job_out_of_the_failure_sets
    flaky_jid = Demo::FlakyJob.perform_async
    processor = build_processor

    force_flaky_job_to_succeed
    processor.process_one

    assert_nil Wurk::RetrySet.new.find_job(flaky_jid),
               'a demo job that succeeded must not land in the retry set'
    assert_nil Wurk::DeadSet.new.find_job(flaky_jid),
               'a demo job that succeeded must not land in the dead set'
  end

  def test_a_real_worker_raises_the_processed_throughput_counter
    Demo::FastJob.perform_async
    processor = build_processor

    # Processor::PROCESSED is a process-global singleton, so a sibling test
    # class in this worker could have left a count behind and the assertion
    # below would pass without this job ever running. Reset under the
    # suite-wide counter mutex (see Wurk::Test::PROCESSOR_COUNTER_MUTEX).
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      Wurk::Processor::PROCESSED.reset
      Wurk::Processor::FAILURE.reset

      processor.process_one
      Wurk::Launcher.new(Wurk.configuration).flush_stats

      assert_operator Wurk::Stats.new.processed, :>, 0
    end
  end

  private

  # Demo::FlakyJob decides whether to raise with `rand < 0.5`. Overriding `rand`
  # ON THE CLASS (not as a singleton method — a class's singleton class is not
  # in its instances' ancestor chain, so a singleton override would never be
  # reached) pins that decision without touching the global PRNG. `teardown`
  # removes the override so the class behaves like the demo again for every
  # other test in this worker.
  def force_flaky_job_to_fail
    Demo::FlakyJob.class_eval { def rand = 0.1 }
  end

  def force_flaky_job_to_succeed
    Demo::FlakyJob.class_eval { def rand = 0.9 }
  end

  def build_processor
    config = Wurk::Configuration.new
    config.logger = Logger.new(IO::NULL)
    config.redis = { url: Wurk.configuration.redis_config[:url] }
    config.queues = ['default']
    capsule = config.default_capsule
    capsule.prepare!
    Wurk::Processor.new(capsule)
  end
end

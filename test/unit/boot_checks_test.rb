# frozen_string_literal: true

require_relative '../test_helper'

class BootChecksTest < Wurk::Test::UnitCase
  parallelize_me!

  class LockedJob
    include Wurk::Job

    sidekiq_options lock: :until_executed
  end

  def setup
    super
    @out = StringIO.new
    @config = Wurk::Configuration.new
    @config.redis = { url: Wurk::Test.redis_url }
    @config.logger = ::Logger.new(@out)
    @redis = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @redis&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_logs_the_backend_and_version
    Wurk::BootChecks.run(@config, 'redis_version' => '7.4.0')

    assert_match(/Wurk #{Regexp.escape(Wurk::VERSION)} on redis 7\.4\.0/, @out.string)
  end

  def test_recognises_dragonfly_and_valkey_from_info
    assert_equal %w[dragonfly 1.34.0],
                 Wurk::BootChecks.backend('redis_version' => '7.2', 'dragonfly_version' => 'df-v1.34.0')
    assert_equal %w[valkey 8.0.1], Wurk::BootChecks.backend('redis_version' => '7.2.4', 'valkey_version' => '8.0.1')
  end

  def test_warns_below_a_tested_floor_and_not_at_it
    Wurk::BootChecks.log_backend(@config.logger, 'dragonfly_version' => 'df-v1.34.0')

    refute_match(/older than/, @out.string)
    Wurk::BootChecks.log_backend(@config.logger, 'dragonfly_version' => 'df-v1.10.0')

    assert_match(/dragonfly 1\.10\.0 is older than/, @out.string)
  end

  def test_warns_about_live_non_wurk_processes_and_stays_quiet_about_wurk_ones
    process('wurk:1:n', 'cores' => 8, 'queues' => [])
    Wurk::BootChecks.warn_on_foreign_processes(@config)

    refute_match(/not Wurk/, @out.string)
    process('stock:1:n', 'queues' => [])
    Wurk::BootChecks.warn_on_foreign_processes(@config)

    assert_match(/not Wurk share this Redis: stock:1:n/, @out.string)
  end

  def test_warns_about_jobs_whose_lock_option_does_nothing
    Wurk::BootChecks.warn_on_ignored_locks(@config.logger)

    assert_match(/BootChecksTest::LockedJob/, @out.string)
    assert_includes Wurk::BootChecks.locked_job_classes, 'BootChecksTest::LockedJob'
  end

  def test_listing_caps_a_long_list
    assert_match(/a0, .* and 5 more\z/, Wurk::BootChecks.listing(Array.new(25) { |i| "a#{i}" }))
  end

  def test_a_failing_check_never_stops_the_boot
    broken = Wurk::Configuration.new
    broken.logger = @config.logger
    broken.redis = { url: 'redis://127.0.0.1:1/0', reconnect_attempts: 0 }

    Wurk::BootChecks.run(broken, 'redis_version' => '7.4.0')

    assert_match(/boot checks skipped/, @out.string)
  ensure
    broken&.reset_redis_pools!
  end

  private

  def process(identity, info)
    @redis.call('SADD', Wurk::Keys::PROCESSES, identity)
    @redis.call('HSET', identity, 'info', ::JSON.generate(info))
  end
end

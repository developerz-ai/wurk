# frozen_string_literal: true

require_relative '../test_helper'

# #283, and the reason it was so hard to see: the swarm parent never builds a
# Redis pool. It closes the parent-side connections (step 3 of the boot ordering)
# and forks; each child opens a fresh pool (step 5). So a `config.redis` key
# redis-client rejects kills every child on boot —
#
#   ERROR swarm child #0 (12) crashed: ArgumentError: unknown keyword: :network_timeout
#   WARN  swarm: child 12 died (status=1); respawning slot 0 in 1.0s
#
# — while the parent stays up and healthy: Running pod, passing liveness probe,
# zero jobs processed, forever. A unit test on the parent's own pool would have
# missed it, so this one runs the pool build where it actually broke.
class RedisOptionsForkTest < Wurk::Test::UnitCase
  parallelize_me!

  CHILD_TIMEOUT = 20

  # The initializer straight out of the production report.
  SIDEKIQ_SHAPED = { driver: :ruby, network_timeout: 5, pool_timeout: 5 }.freeze

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = SIDEKIQ_SHAPED.merge(url: Wurk::Test.redis_url)
  end

  def teardown
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_forked_child_builds_a_working_pool_from_sidekiq_shaped_options
    assert_equal 0, run_in_child { @config.redis_pool.with { |c| c.call('PING') } == 'PONG' },
                 'a forked child must build its Redis pool from a Sidekiq-shaped config.redis hash'
  end

  def test_forked_child_honours_the_fanned_out_network_timeout
    assert_equal 0, run_in_child { @config.redis_pool.client_config[:read_timeout] == 5 },
                 'network_timeout must reach the child as the split socket timeouts'
  end

  private

  # Mirrors the swarm's own pre-fork step: drop every parent-side pool, fork, and
  # let the child build its own. Exit status is the assertion channel — that's
  # exactly how the bug reported itself in production.
  def run_in_child(&block)
    @config.reset_redis_pools!
    pid = ::Process.fork do
      ok = begin
        block.call
      rescue StandardError => e
        warn("child failed: #{e.class}: #{e.message}") if ENV['DEBUG_INVOCATION'] == '1'
        false
      end
      ::Process.exit!(ok ? 0 : 1)
    end
    _, status = ::Process.wait2(pid)
    status.exitstatus
  end
end

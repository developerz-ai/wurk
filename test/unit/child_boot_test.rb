# frozen_string_literal: true

require_relative '../test_helper'

# ChildBoot#reconnect_after_fork runs inside forked swarm children; the real
# fork path is proven end-to-end by swarm_boot_test. Here we drive its Redis
# side in-process (no fork) against real Redis so the post-fork PING + eager
# pipelined script-load logic is exercised directly. `send` reaches the private
# reconnect because there is no public entry that runs it without the launcher.
class ChildBootTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    @boot = Wurk::Swarm::ChildBoot.new(@config, nil, 0)
  end

  def teardown
    @config&.reset_redis_pools!
  ensure
    super
  end

  # PINGs, primes every Lua script, and (with ActiveRecord absent in unit env)
  # returns cleanly. A live-cache SCRIPT FLUSH would race peer workers that
  # share the global script cache, so we assert the end state: all SHAs present.
  def test_reconnect_after_fork_primes_every_lua_script
    @boot.send(:reconnect_after_fork)

    shas    = Wurk::Lua::SHAS.values
    present = @config.redis { |c| c.call('SCRIPT', 'EXISTS', *shas) }

    assert(present.all? { |v| v == 1 }, "post-fork boot must leave every script cached, got #{present.inspect}")
  end

  def test_validate_redis_pings_then_pipelines_every_script_load
    result = @boot.send(:validate_redis!)

    # #with returns the block value; script_load_all is the last expression, so
    # its one-SHA-per-script pipeline result proves both the PING (which would
    # have raised first) and the eager load ran on the same checkout.
    assert_equal Wurk::Lua::SCRIPTS.size, result.size
  end
end

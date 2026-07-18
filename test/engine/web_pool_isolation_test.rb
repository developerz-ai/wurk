# frozen_string_literal: true

require_relative '../engine_test_helper'

# Proves the engine's dashboard/API stack routes its Redis reads through the
# dedicated web pool (#101). The Wurk::ApplicationController around_action wraps
# every action in Wurk::Web::PoolScope, so `Wurk.redis` inside the action
# resolves via the web-pool handle rather than the worker (default capsule)
# pool — dashboard load can't exhaust the connections a co-located worker needs.
class WebPoolIsolationTest < Wurk::Test::EngineCase
  parallelize_me!

  def teardown
    restore_handle
    Wurk.configuration.reset_redis_pools!
  ensure
    super
  end

  def test_api_request_resolves_redis_through_the_web_pool
    spy_handle_resolutions

    get '/wurk/api/stats'

    assert_equal 200, last_response.status, "non-200: #{last_response.body[0, 300]}"
    assert_operator @resolutions, :>, 0,
                    'the API action should resolve Wurk.redis through the web-pool handle'
  end

  # Outside a request there is no web scope, so `Wurk.redis` stays on the worker
  # pool — the diversion is strictly request-scoped and doesn't leak onto the
  # Rack::Test thread afterwards.
  def test_request_scope_does_not_leak_onto_the_thread
    assert_nil Thread.current[:wurk_capsule]

    get '/wurk/api/stats'

    assert_nil Thread.current[:wurk_capsule], 'web pool binding must be cleared after the request'
  end

  private

  # Counts pool resolutions WITHOUT redefining the shared PoolScope.handle
  # singleton (which every concurrent request would see): swaps in a double that
  # tallies only resolutions on this test's own thread — Rack::Test runs the
  # action inline — and delegates live to the real web pool, so a sibling
  # request resolves the correct, never-stale pool and can't inflate the count.
  # teardown#restore_handle puts the untouched original back.
  def spy_handle_resolutions
    @resolutions = 0
    @original_handle = ::Wurk::Web::PoolScope.handle
    spy = ResolutionCountingHandle.new(::Thread.current) { @resolutions += 1 }
    ::Wurk::Web::PoolScope.instance_variable_set(:@handle, spy)
  end

  def restore_handle
    return unless defined?(@original_handle) && @original_handle

    ::Wurk::Web::PoolScope.instance_variable_set(:@handle, @original_handle)
  end

  # Web-pool handle double: increments the counter only when the resolving
  # thread is the test's own, then returns the live web pool exactly as the real
  # PoolScope::Handle would — no captured (staleable) pool, no global mutation
  # of the shared handle.
  class ResolutionCountingHandle
    def initialize(test_thread, &counter)
      @test_thread = test_thread
      @counter = counter
    end

    def redis_pool
      @counter.call if ::Thread.current == @test_thread
      ::Wurk.configuration.web_redis_pool
    end
  end
end

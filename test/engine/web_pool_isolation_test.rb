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
    web = ::Wurk.configuration.web_redis_pool
    spy_handle_resolutions(web)

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

  # Records each time the handle resolves its pool (i.e. each in-action
  # `Wurk.redis` call) while still returning the real pool so the request works.
  def spy_handle_resolutions(web)
    @resolutions = 0
    @handle = ::Wurk::Web::PoolScope.handle
    counter = -> { @resolutions += 1 }
    @handle.define_singleton_method(:redis_pool) do
      counter.call
      web
    end
  end

  def restore_handle
    return unless @handle&.singleton_methods&.include?(:redis_pool)

    @handle.singleton_class.send(:remove_method, :redis_pool)
  end
end

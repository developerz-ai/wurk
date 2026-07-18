# frozen_string_literal: true

require_relative '../test_helper'

# Dedicated web pool (#101): the dashboard / JSON API / SSE run on their own
# Redis pool, disjoint from the worker capsules', so dashboard load can't
# exhaust the connections a co-located worker needs (and vice versa).
# Wurk::Web::PoolScope routes `Wurk.redis` onto that pool for the request.
class WebPoolScopeTest < Wurk::Test::UnitCase
  parallelize_me!

  def teardown
    Thread.current[:wurk_capsule] = nil
    # This class builds the global config's web/worker pools; drop them so a
    # sibling class in the same fork rebuilds lazily against its own DB.
    Wurk.configuration.reset_redis_pools!
  ensure
    super
  end

  # --- routing -----------------------------------------------------------

  def test_scope_routes_wurk_redis_to_the_web_pool
    # Baseline outside the scope: the default capsule (worker) pool.
    refute_same Wurk.configuration.web_redis_pool, Wurk.redis_pool

    Wurk::Web::PoolScope.scope do
      assert_same Wurk.configuration.web_redis_pool, Wurk.redis_pool
    end
  end

  def test_scope_restores_thread_local_afterwards
    assert_nil Thread.current[:wurk_capsule]

    Wurk::Web::PoolScope.scope { assert_equal Wurk::Web::PoolScope.handle, Thread.current[:wurk_capsule] }

    assert_nil Thread.current[:wurk_capsule]
  end

  def test_scope_restores_thread_local_after_exception
    assert_nil Thread.current[:wurk_capsule]

    assert_raises(RuntimeError) { Wurk::Web::PoolScope.scope { raise 'boom' } }

    assert_nil Thread.current[:wurk_capsule]
  end

  # A worker thread that already carries a capsule binding is restored, not
  # clobbered, on the way out of a web scope.
  def test_scope_restores_prior_capsule_binding
    cap = Wurk.configuration.default_capsule
    Thread.current[:wurk_capsule] = cap

    Wurk::Web::PoolScope.scope do
      assert_same Wurk.configuration.web_redis_pool, Wurk.redis_pool
    end

    assert_same cap, Thread.current[:wurk_capsule]
  end

  def test_nested_scopes_restore_to_outer
    Wurk::Web::PoolScope.scope do
      outer = Wurk.redis_pool

      Wurk::Web::PoolScope.scope { assert_same outer, Wurk.redis_pool }

      assert_same outer, Wurk.redis_pool
    end
  end

  # --- handle ------------------------------------------------------------

  def test_handle_is_memoized
    assert_same Wurk::Web::PoolScope.handle, Wurk::Web::PoolScope.handle
  end

  # The handle resolves the pool on each call, so a post-fork reset rebuild is
  # picked up transparently rather than pinning a stale pool.
  def test_handle_resolves_current_web_pool_after_reset
    first = nil
    Wurk::Web::PoolScope.scope { first = Wurk.redis_pool }

    Wurk.configuration.reset_redis_pools!

    Wurk::Web::PoolScope.scope { refute_same first, Wurk.redis_pool }
  end

  # --- isolation ---------------------------------------------------------

  # The headline guarantee: saturating the web pool leaves the worker pool
  # fully available. Uses a local config so the small web pool doesn't perturb
  # the shared global one.
  def test_saturated_web_pool_does_not_starve_worker_pool
    config = isolated_config(web_pool_size: 1)
    web = config.web_redis_pool
    hold = hold_only_connection(web)

    assert_equal 0, web.available, 'the only web connection should be checked out'
    assert_pool_usable config.default_capsule.redis_pool
  ensure
    hold&.release
    config&.reset_redis_pools!
  end

  # A background thread holding a pool's only connection until #release, so a
  # test can prove a *different* pool stays available while it's checked out.
  Hold = Struct.new(:thread, :release_queue) do
    def release
      release_queue << :go
      thread.join(2)
    end
  end

  private

  def isolated_config(web_pool_size:)
    config = Wurk::Configuration.new
    config.redis = { url: Wurk::Test.redis_url }
    config.web_pool_size = web_pool_size
    config
  end

  # Checks out (and holds) a connection from a size-1 pool on a background
  # thread, blocking until it is held, so the pool is saturated for the caller.
  def hold_only_connection(pool)
    gate = Queue.new
    release = Queue.new
    thread = Thread.new do
      pool.with do |conn|
        conn.call('PING')
        gate << :held
        release.pop
      end
    end
    gate.pop
    Hold.new(thread, release)
  end

  def assert_pool_usable(pool)
    assert_operator pool.available, :>, 0, 'the pool must retain free slots'
    assert_equal 'PONG', pool.with { |conn| conn.call('PING') }, 'checkout must still succeed'
  end
end

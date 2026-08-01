# frozen_string_literal: true

require_relative '../test_helper'

# F5 follow-up. `RedisPool#with` now takes the caller's apply-safety claim
# (`idempotent:`), but almost nothing in lib/ touches a pool directly — every
# subsystem goes through a wrapper (Wurk.redis, Capsule#redis, Component#redis,
# the middleware mixin, the pool-or-default helpers). A wrapper that dropped the
# keyword would pin its callers to the safe default with no way to opt back in,
# so the forwarding is asserted here once, centrally, instead of per subsystem.
class RedisIdempotentForwardingTest < Wurk::Test::UnitCase
  parallelize_me!

  # Every wrapper in lib/ that ends in a `RedisPool#with` checkout. Listed
  # explicitly so a new wrapper added without the keyword shows up as a diff
  # here rather than as a silently ignored `idempotent: true` in production.
  WRAPPERS = [
    [Wurk.singleton_class,                    :redis],
    [Sidekiq.singleton_class,                 :redis],
    [Wurk::Configuration,                     :redis],
    [Wurk::Capsule,                           :redis],
    [Wurk::Capsule,                           :fetch_redis],
    [Wurk::Component,                         :redis],
    [Wurk::Middleware::ServerMiddleware,      :redis],
    [Wurk::Limiter.singleton_class,           :redis],
    [Wurk::Cron::LoopSet,                     :redis],
    [Wurk::Web::Extension::Helpers,           :redis],
    [Wurk::Leader,                            :redis_call],
    [Wurk::Stats::History,                    :with_redis],
    [Wurk::Deploy,                            :with_redis],
    [Wurk::Profiler.singleton_class,          :with_pool],
    [Wurk::Metrics::History.singleton_class,  :with_pool]
  ].freeze

  # Records the claim each checkout carried. Subclasses the real pool because
  # PoolCheckout dispatches on the RedisPool type, so a bare double would take
  # the foreign-pool branch and prove nothing; `#with` is overridden, and
  # ConnectionPool builds connections lazily, so no socket is ever opened.
  class RecordingPool < Wurk::RedisPool
    attr_reader :claims

    def initialize
      super(size: 1, name: 'recording', url: Wurk::Test.redis_url)
      @claims = []
    end

    def with(idempotent: false)
      @claims << idempotent
      yield :conn
    end
  end

  # What a host actually hands to `Sidekiq::Client#redis_pool=` or a `pool:`
  # kwarg when it wants to count/trace round trips: a bare decorator whose
  # `#with` takes no keywords at all.
  class ForeignPool
    attr_reader :checkouts

    def initialize
      @checkouts = 0
    end

    def with
      @checkouts += 1
      yield :conn
    end
  end

  # The capsule duck type `Wurk.redis_pool` resolves through — the same seam
  # Wurk::Web::PoolScope uses to divert the dashboard onto the web pool.
  Handle = Struct.new(:redis_pool)

  # Config duck type for the wrappers that delegate to `config.redis` rather
  # than to a pool of their own.
  class RecordingConfig
    attr_reader :claims

    def initialize
      @claims = []
    end

    def redis(idempotent: false)
      @claims << idempotent
      yield :conn
    end
  end

  class ComponentHost
    include Wurk::Component

    attr_reader :config

    def initialize(config)
      @config = config
    end
  end

  class MiddlewareHost
    include Wurk::Middleware::ServerMiddleware
  end

  class ExtensionHost
    include Wurk::Web::Extension::Helpers
  end

  def setup
    super
    @pool = RecordingPool.new
    @config = RecordingConfig.new
    Wurk::Limiter.reset_config!
  end

  def teardown
    Thread.current[:wurk_capsule] = nil
    Wurk::Limiter.reset_config!
  ensure
    super
  end

  # --- foreign pools ------------------------------------------------------

  # The drop-in seam: `Sidekiq::Client#redis_pool=`, `Sidekiq::Web.redis_pool=`
  # and the `pool:` kwargs all accept any ConnectionPool-shaped object, and
  # `def with; yield conn; end` is a legal one. Forwarding a keyword it never
  # declared is an ArgumentError, so PoolCheckout must drop the claim there —
  # a foreign pool keeps the conservative behavior it had before F5.
  def test_foreign_pool_never_receives_the_claim
    foreign = ForeignPool.new

    assert_equal :conn, Wurk::PoolCheckout.with(foreign, true) { |c| c }
    assert_equal :conn, Wurk::PoolCheckout.with(foreign, false) { |c| c }

    assert_equal 2, foreign.checkouts
  end

  # Wrappers reach the pool through PoolCheckout, so a host-supplied pool
  # survives a claim made anywhere upstream — not just a direct checkout.
  def test_wrappers_tolerate_a_foreign_pool_under_a_claim
    foreign = ForeignPool.new
    cap = Wurk::Capsule.new('idempotent-foreign', Wurk::Configuration.new)
    cap.define_singleton_method(:redis_pool) { foreign }
    cap.define_singleton_method(:fetch_redis_pool) { foreign }

    cap.redis(idempotent: true) { |c| c }
    cap.fetch_redis(idempotent: true) { |c| c }
    Wurk::Deploy.new(pool: foreign).send(:with_redis, idempotent: true) { |c| c }
    Wurk::Leader.new(pool: foreign).send(:redis_call, idempotent: true) { |c| c }

    assert_equal 4, foreign.checkouts
  end

  # A real RedisPool does understand it, so the claim must survive the seam —
  # otherwise `idempotent: true` would be silently inert everywhere.
  def test_wurk_redis_pool_does_receive_the_claim
    Wurk::PoolCheckout.with(@pool, true) { |c| c }
    Wurk::PoolCheckout.with(@pool, false) { |c| c }

    assert_equal [true, false], @pool.claims
  end

  # --- structural sweep --------------------------------------------------

  def test_every_pool_wrapper_accepts_the_claim
    WRAPPERS.each do |owner, meth|
      params = owner.instance_method(meth).parameters

      assert_includes params, %i[key idempotent], "#{owner}##{meth} drops idempotent:"
    end
  end

  def test_every_pool_wrapper_defaults_to_apply_unsafe
    WRAPPERS.each do |owner, meth|
      params = owner.instance_method(meth).parameters

      refute_includes params, %i[keyreq idempotent], "#{owner}##{meth} made the claim mandatory"
    end
  end

  # --- Wurk.redis / Sidekiq.redis ----------------------------------------

  # The drop-in contract: third-party gems call `Sidekiq.redis { |c| ... }` and
  # `Wurk.redis { |c| ... }` with no arguments, and get the safe default.
  def test_zero_arg_call_shape_is_unchanged
    returned = on_recording_pool { [Wurk.redis { |c| c }, Sidekiq.redis { |c| c }] }

    assert_equal %i[conn conn], returned
    assert_equal [false, false], @pool.claims
  end

  def test_wurk_redis_forwards_the_claim
    on_recording_pool { Wurk.redis(idempotent: true) { |c| c } }

    assert_equal [true], @pool.claims
  end

  def test_sidekiq_redis_forwards_the_claim
    on_recording_pool { Sidekiq.redis(idempotent: true) { |c| c } }

    assert_equal [true], @pool.claims
  end

  # --- capsule / configuration / component -------------------------------

  def test_capsule_redis_forwards_the_claim
    cap = capsule_on_recording_pool

    assert_equal :conn, cap.redis(idempotent: true) { |c| c }
    cap.redis { |c| c }

    assert_equal [true, false], @pool.claims
  end

  # The reliable fetcher's BLMOVE pool is a separate checkout path, so it needs
  # its own forwarding — it is the first caller that will claim apply-safety.
  def test_capsule_fetch_redis_forwards_the_claim
    cap = capsule_on_recording_pool

    assert_equal :conn, cap.fetch_redis(idempotent: true) { |c| c }
    cap.fetch_redis { |c| c }

    assert_equal [true, false], @pool.claims
  end

  def test_configuration_redis_forwards_the_claim
    config = Wurk::Configuration.new
    pool = @pool
    config.define_singleton_method(:redis_pool) { pool }

    assert_equal :conn, config.redis(idempotent: true) { |c| c }
    config.redis { |c| c }

    assert_equal [true, false], @pool.claims
  end

  def test_component_redis_forwards_the_claim_to_its_config
    host = ComponentHost.new(@config)

    assert_equal :conn, host.redis(idempotent: true) { |c| c }
    host.redis { |c| c }

    assert_equal [true, false], @config.claims
  end

  def test_server_middleware_redis_forwards_the_claim_to_its_config
    mw = MiddlewareHost.new
    mw.config = @config

    assert_equal :conn, mw.redis(idempotent: true) { |c| c }
    mw.redis { |c| c }

    assert_equal [true, false], @config.claims
  end

  # --- wrappers that fall back to the default pool -----------------------

  def test_limiter_redis_forwards_the_claim
    on_recording_pool do
      assert_equal :conn, Wurk::Limiter.redis(idempotent: true) { |c| c }
      Wurk::Limiter.redis { |c| c }
    end

    assert_equal [true, false], @pool.claims
  end

  def test_cron_loop_set_redis_forwards_the_claim
    loops = Wurk::Cron::LoopSet.new(@config)

    assert_equal :conn, loops.send(:redis, idempotent: true) { |c| c }
    loops.send(:redis) { |c| c }

    assert_equal [true, false], @config.claims
  end

  def test_cron_loop_set_redis_forwards_the_claim_without_a_config
    loops = Wurk::Cron::LoopSet.new
    on_recording_pool { loops.send(:redis, idempotent: true) { |c| c } }

    assert_equal [true], @pool.claims
  end

  def test_web_extension_helper_redis_forwards_the_claim
    helper = ExtensionHost.new
    on_recording_pool do
      assert_equal :conn, helper.redis(idempotent: true) { |c| c }
      helper.redis { |c| c }
    end

    assert_equal [true, false], @pool.claims
  end

  # Each of the wrappers below picks between an injected pool and the process
  # default, so it has *two* checkout expressions rather than one. A keyword
  # forwarded on the injected leg and dropped on the fallback leg downgrades the
  # claim silently in whichever configuration the author didn't exercise — hence
  # both legs, not just the one the subsystem happens to use today.

  def test_stats_history_with_redis_forwards_on_both_branches
    injected = Wurk::Stats::History.new(1, pool: @pool)
    fallback = Wurk::Stats::History.new(1)

    assert_both_branches_forward(
      injected: ->(claim) { injected.send(:with_redis, idempotent: claim) { |c| c } },
      fallback: ->(claim) { fallback.send(:with_redis, idempotent: claim) { |c| c } }
    )
  end

  def test_deploy_with_redis_forwards_on_both_branches
    injected = Wurk::Deploy.new(pool: @pool)
    fallback = Wurk::Deploy.new

    assert_both_branches_forward(
      injected: ->(claim) { injected.send(:with_redis, idempotent: claim) { |c| c } },
      fallback: ->(claim) { fallback.send(:with_redis, idempotent: claim) { |c| c } }
    )
  end

  def test_metrics_history_with_pool_forwards_on_both_branches
    assert_both_branches_forward(
      injected: ->(claim) { Wurk::Metrics::History.send(:with_pool, @pool, idempotent: claim) { |c| c } },
      fallback: ->(claim) { Wurk::Metrics::History.send(:with_pool, nil, idempotent: claim) { |c| c } }
    )
  end

  def test_profiler_with_pool_forwards_on_both_branches
    assert_both_branches_forward(
      injected: ->(claim) { Wurk::Profiler.send(:with_pool, @pool, idempotent: claim) { |c| c } },
      fallback: ->(claim) { Wurk::Profiler.send(:with_pool, nil, idempotent: claim) { |c| c } }
    )
  end

  # Leader is the three-way case: explicit pool → bound config → process default.
  def test_leader_redis_call_forwards_on_every_branch
    assert_equal :conn, Wurk::Leader.new(pool: @pool).send(:redis_call, idempotent: true) { |c| c }
    Wurk::Leader.new(config: @config).send(:redis_call, idempotent: true) { |c| c }
    Wurk::Leader.new(config: @config).send(:redis_call) { |c| c }
    on_recording_pool { Wurk::Leader.new.send(:redis_call, idempotent: true) { |c| c } }

    assert_equal [true, true], @pool.claims
    assert_equal [true, false], @config.claims
  end

  private

  # Drives a pool-or-default wrapper down both legs — the injected pool outside
  # the scope, the default pool inside it — asserting each leg carries the claim
  # it was handed. Both legs land on the same recorder, so the expected sequence
  # is the two claims per leg in call order.
  def assert_both_branches_forward(injected:, fallback:)
    assert_equal :conn, injected.call(true)
    injected.call(false)

    on_recording_pool do
      assert_equal :conn, fallback.call(true)
      fallback.call(false)
    end

    assert_equal [true, false, true, false], @pool.claims
  end

  # Points `Wurk.redis_pool` at the recorder for the duration of the block.
  def on_recording_pool
    prev = Thread.current[:wurk_capsule]
    Thread.current[:wurk_capsule] = Handle.new(@pool)
    yield
  ensure
    Thread.current[:wurk_capsule] = prev
  end

  def capsule_on_recording_pool
    cap = Wurk::Capsule.new('idempotent-forwarding', Wurk::Configuration.new)
    pool = @pool
    cap.define_singleton_method(:redis_pool) { pool }
    cap.define_singleton_method(:fetch_redis_pool) { pool }
    cap
  end
end

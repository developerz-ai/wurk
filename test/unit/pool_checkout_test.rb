# frozen_string_literal: true

require_relative '../test_helper'

# PoolCheckout is the seam every `#redis`-style wrapper checks out through.
# `.with` must tolerate a foreign, non-Wurk::RedisPool object (any
# ConnectionPool-shaped `def with; yield conn; end`) by dropping the
# `idempotent:` claim rather than raising ArgumentError on an unknown kwarg.
# `.trusted` skips that duck-type probe entirely — only safe for call sites
# whose pool is always this process's own RedisPool.
class PoolCheckoutTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool = Wurk::RedisPool.new(size: 2, url: Wurk::Test.redis_url)
  end

  def teardown
    @pool&.disconnect!
    super
  end

  # A pool that does NOT accept `idempotent:` — the shape a host might supply
  # via Sidekiq::Client#redis_pool= or a bare round-trip-counting decorator.
  class ForeignPool
    def with
      yield :foreign_conn
    end
  end

  # --- .with: Wurk::RedisPool + idempotent: true ---

  def test_with_forwards_idempotent_true_to_a_real_redis_pool
    result = Wurk::PoolCheckout.with(@pool, true) { |conn| conn.call('PING') }

    assert_equal 'PONG', result
  end

  def test_with_forwards_idempotent_false_to_a_real_redis_pool
    result = Wurk::PoolCheckout.with(@pool, false) { |conn| conn.call('PING') }

    assert_equal 'PONG', result
  end

  # --- .with: foreign-pool fallback (must not ArgumentError on the kwarg) ---

  def test_with_drops_idempotent_true_for_a_foreign_pool
    result = Wurk::PoolCheckout.with(ForeignPool.new, true) { |conn| conn }

    assert_equal :foreign_conn, result
  end

  def test_with_idempotent_false_never_touches_the_kwarg_for_a_foreign_pool
    result = Wurk::PoolCheckout.with(ForeignPool.new, false) { |conn| conn }

    assert_equal :foreign_conn, result
  end

  def test_with_foreign_pool_does_not_raise_argument_error
    Wurk::PoolCheckout.with(ForeignPool.new, true) { |conn| conn }
  rescue ArgumentError => e
    flunk("PoolCheckout.with must never hand a foreign pool an unknown kwarg: #{e.message}")
  end

  # A pool that DOES understand `idempotent:` but isn't a Wurk::RedisPool
  # subclass still only receives the kwarg when idempotent: true is asked for
  # — the is_a? probe gates the call shape, not just the value.
  class DuckTypedPool
    attr_reader :last_kwargs

    def with(**kwargs)
      @last_kwargs = kwargs
      yield :duck_conn
    end
  end

  def test_with_never_calls_idempotent_kwarg_on_non_redis_pool_even_if_supported
    duck = DuckTypedPool.new
    Wurk::PoolCheckout.with(duck, true) { |conn| conn }

    assert_equal({}, duck.last_kwargs, 'PoolCheckout only trusts RedisPool with the kwarg, not any duck-typed pool')
  end

  # --- .trusted: skips the is_a? probe, same forwarding otherwise ---

  def test_trusted_forwards_idempotent_true_to_a_real_redis_pool
    result = Wurk::PoolCheckout.trusted(@pool, true) { |conn| conn.call('PING') }

    assert_equal 'PONG', result
  end

  def test_trusted_forwards_idempotent_false_to_a_real_redis_pool
    result = Wurk::PoolCheckout.trusted(@pool, false) { |conn| conn.call('PING') }

    assert_equal 'PONG', result
  end

  def test_trusted_raises_for_a_foreign_pool_given_idempotent_true
    assert_raises(ArgumentError) do
      Wurk::PoolCheckout.trusted(ForeignPool.new, true) { |conn| conn }
    end
  end

  def test_trusted_does_not_raise_for_a_foreign_pool_given_idempotent_false
    result = Wurk::PoolCheckout.trusted(ForeignPool.new, false) { |conn| conn }

    assert_equal :foreign_conn, result
  end

  # --- subclass parity: a RedisPool subclass is still trusted by .with ---

  class SubclassPool < Wurk::RedisPool; end

  def test_with_forwards_idempotent_true_to_a_redis_pool_subclass
    sub = SubclassPool.new(size: 1, url: Wurk::Test.redis_url)
    result = Wurk::PoolCheckout.with(sub, true) { |conn| conn.call('PING') }

    assert_equal 'PONG', result
  ensure
    sub&.disconnect!
  end
end

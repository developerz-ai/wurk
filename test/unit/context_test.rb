# frozen_string_literal: true

require_relative '../test_helper'

class ContextTest < Wurk::Test::UnitCase
  parallelize_me!

  def teardown
    Thread.current[Wurk::Context::KEY] = nil
  end

  # --- with -----------------------------------------------------------

  def test_with_merges_hash_into_thread_local
    Wurk::Context.with(jid: 'abc') do
      assert_equal({ jid: 'abc' }, Wurk::Context.current)
    end
  end

  def test_with_returns_block_value
    result = Wurk::Context.with(jid: 'abc') { 42 }

    assert_equal 42, result
  end

  def test_with_restores_prior_context_after_block
    Wurk::Context.with(a: 1) do
      Wurk::Context.with(b: 2) do
        assert_equal({ a: 1, b: 2 }, Wurk::Context.current)
      end
      assert_equal({ a: 1 }, Wurk::Context.current)
    end

    assert_empty Wurk::Context.current
  end

  def test_with_restores_context_on_raise
    assert_raises(RuntimeError) do
      Wurk::Context.with(jid: 'abc') { raise 'boom' }
    end

    assert_empty Wurk::Context.current
  end

  def test_with_inner_overrides_outer_keys
    Wurk::Context.with(jid: 'outer') do
      Wurk::Context.with(jid: 'inner') do
        assert_equal 'inner', Wurk::Context.current[:jid]
      end
      assert_equal 'outer', Wurk::Context.current[:jid]
    end
  end

  # --- add ------------------------------------------------------------

  def test_add_creates_context_if_missing
    Wurk::Context.add(:foo, :bar)

    assert_equal :bar, Wurk::Context.current[:foo]
  end

  def test_add_inside_with_block
    Wurk::Context.with(jid: 'j') do
      Wurk::Context.add(:elapsed, 42)

      assert_equal({ jid: 'j', elapsed: 42 }, Wurk::Context.current)
    end
  end

  def test_add_inside_with_does_not_leak_outside
    Wurk::Context.with(jid: 'j') do
      Wurk::Context.add(:elapsed, 42)
    end

    assert_empty Wurk::Context.current
  end

  # --- thread isolation ----------------------------------------------

  def test_context_is_thread_local
    Wurk::Context.add(:main, true)
    other = Thread.new { Wurk::Context.current.dup }.value

    assert_empty other
    assert Wurk::Context.current[:main]
  end
end

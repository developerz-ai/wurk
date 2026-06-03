# frozen_string_literal: true

require_relative '../test_helper'
require 'date'

class DeployTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @suffix = "dep#{Process.pid}_#{object_id}"
    @label = "deploy-#{@suffix}"
    @at = ::Time.utc(2026, 5, 21, 14, 37, 12)
  end

  def teardown
    Wurk.redis do |c|
      c.call('DEL', "deploylock-#{@label}")
      c.call('DEL', '20260521-marks')
    end
  ensure
    super
  end

  def test_mark_writes_hash_field_at_iso8601_rounded_to_minute
    iso = Wurk::Deploy.mark!(label: @label, at: @at)

    assert_equal '2026-05-21T14:37:00Z', iso
    val = Wurk.redis { |c| c.call('HGET', '20260521-marks', iso) }

    assert_equal @label, val
  end

  def test_mark_sets_marks_ttl_to_90_days
    Wurk::Deploy.mark!(label: @label, at: @at)

    ttl = Wurk.redis { |c| c.call('TTL', '20260521-marks') }

    assert_operator ttl, :>, Wurk::Deploy::MARK_TTL - 60
    assert_operator ttl, :<=, Wurk::Deploy::MARK_TTL
  end

  def test_mark_acquires_per_label_lock_with_60s_ttl
    Wurk::Deploy.mark!(label: @label, at: @at)

    ttl = Wurk.redis { |c| c.call('TTL', "deploylock-#{@label}") }

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, Wurk::Deploy::LOCK_TTL
  end

  def test_mark_returns_nil_when_lock_already_held
    first = Wurk::Deploy.mark!(label: @label, at: @at)
    second = Wurk::Deploy.mark!(label: @label, at: @at)

    refute_nil first
    assert_nil second
  end

  def test_mark_with_blank_label_returns_nil_when_label_maker_fails
    orig = Wurk::Deploy::LABEL_MAKER
    Wurk::Deploy.send(:remove_const, :LABEL_MAKER)
    Wurk::Deploy.const_set(:LABEL_MAKER, -> { raise 'no git' })

    assert_nil Wurk::Deploy.mark!(label: nil, at: @at)
  ensure
    Wurk::Deploy.send(:remove_const, :LABEL_MAKER)
    Wurk::Deploy.const_set(:LABEL_MAKER, orig)
  end

  def test_mark_rounds_seconds_off
    iso = Wurk::Deploy.mark!(label: @label, at: ::Time.utc(2026, 5, 21, 14, 37, 59))

    assert_equal '2026-05-21T14:37:00Z', iso
  end

  def test_fetch_returns_iso_to_label_hash
    Wurk::Deploy.mark!(label: @label, at: @at)

    marks = Wurk::Deploy.new.fetch(@at)

    assert_equal({ '2026-05-21T14:37:00Z' => @label }, marks)
  end

  def test_fetch_empty_when_no_marks
    assert_equal({}, Wurk::Deploy.new.fetch(@at))
  end

  # `fetch` with a Date (not Time): Date doesn't respond to #utc, so the
  # `date = date.utc if ...` guard's else side leaves it untouched and we
  # strftime the bare Date. Pins the non-Time path of the date coercion.
  def test_fetch_accepts_a_date_object
    Wurk::Deploy.mark!(label: @label, at: @at)
    date = ::Date.new(2026, 5, 21)

    refute_respond_to date, :utc, 'guard precondition: Date has no #utc'
    marks = Wurk::Deploy.new.fetch(date)

    assert_equal({ '2026-05-21T14:37:00Z' => @label }, marks)
  end

  # with_redis routes through an injected pool (`@pool.with(&)`, the then
  # side) instead of the global `Wurk.redis`. Passing the configured pool
  # exercises that branch while still hitting real Redis.
  def test_mark_uses_injected_pool
    pool = Wurk.configuration.redis_pool
    iso = Wurk::Deploy.new(pool: pool).mark!(label: @label, at: @at)

    assert_equal '2026-05-21T14:37:00Z', iso
    val = pool.with { |c| c.call('HGET', '20260521-marks', iso) }

    assert_equal @label, val
  end

  def test_class_mark_delegates_to_instance
    assert_kind_of String, Wurk::Deploy.mark!(label: @label, at: @at)
  end

  def test_sidekiq_deploy_alias_exists
    assert_equal Wurk::Deploy, Sidekiq::Deploy
  end
end

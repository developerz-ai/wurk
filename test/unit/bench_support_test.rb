# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../bench/support'

# `bench_redis_url` is the only thing standing between a benchmark's FLUSHDB
# and a developer's real DB 0, so its two failure modes are pinned here: a
# bogus `WURK_BENCH_DB` must raise rather than fall back, and a query-bearing
# `REDIS_URL` must keep its query when the DB is swapped.
class BenchSupportTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_uses_the_per_bench_default_database
    with_env('REDIS_URL' => 'redis://localhost:6379/0', 'WURK_BENCH_DB' => nil) do
      assert_equal 'redis://localhost:6379/10', bench_redis_url('10')
    end
  end

  def test_override_replaces_the_default_database
    with_env('REDIS_URL' => 'redis://localhost:6379/0', 'WURK_BENCH_DB' => '11') do
      assert_equal 'redis://localhost:6379/11', bench_redis_url('10')
    end
  end

  def test_preserves_query_and_credentials_when_swapping_the_database
    with_env('REDIS_URL' => 'rediss://:pw@host:6380/0?ssl=true', 'WURK_BENCH_DB' => '12') do
      assert_equal 'rediss://:pw@host:6380/12?ssl=true', bench_redis_url('10')
    end
  end

  def test_appends_the_database_to_a_url_without_one
    with_env('REDIS_URL' => 'redis://host?timeout=1', 'WURK_BENCH_DB' => '13') do
      assert_equal 'redis://host/13?timeout=1', bench_redis_url('10')
    end
  end

  def test_rejects_database_zero
    assert_invalid_override '0'
  end

  def test_rejects_negative_database
    assert_invalid_override '-1'
  end

  def test_rejects_non_numeric_database
    assert_invalid_override 'abc'
  end

  private

  def assert_invalid_override(value)
    with_env('REDIS_URL' => 'redis://localhost:6379/0', 'WURK_BENCH_DB' => value) do
      error = assert_raises(ArgumentError) { bench_redis_url('10') }

      assert_match(/positive integer/, error.message)
    end
  end

  # ENV is process-global and the whole suite reads REDIS_URL for its per-worker
  # DB isolation, so every key touched here is restored even on failure.
  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

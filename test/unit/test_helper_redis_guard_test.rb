# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'rbconfig'

# The suite's teardown is a FLUSHDB. No REDIS_URL or WURK_TEST_DB_OFFSET may aim it at DB 0.
class TestHelperRedisGuardTest < Wurk::Test::UnitCase
  def with_redis_url(url)
    saved = ENV.fetch('REDIS_URL', nil)
    ENV['REDIS_URL'] = url
    yield
  ensure
    ENV['REDIS_URL'] = saved
  end

  {
    'redis://h:1/0' => 'redis://h:1/5',
    'redis://h:1' => 'redis://h:1/5',
    'redis://h:1/0?x=1' => 'redis://h:1/5?x=1',
    'redis://h:1/0?db=0' => 'redis://h:1/5',
    'rediss://u:p@h:1/9?db=0&x=1' => 'rediss://u:p@h:1/5?x=1'
  }.each do |given, expected|
    define_method("test_#{given.gsub(/\W/, '_')}_lands_on_the_workers_db") do
      with_redis_url(given) { assert_equal expected, Wurk::Test.redis_url_for_db(5) }
    end
  end

  def test_a_url_with_no_db_path_is_refused
    with_redis_url('unix:///tmp/r.sock?db=0') do
      assert_raises(RuntimeError) { Wurk::Test.redis_url_for_db(5) }
    end
  end

  def test_db_zero_is_refused_outright
    assert_raises(RuntimeError) { Wurk::Test.redis_url_for_db(0) }
  end

  def test_a_negative_offset_cannot_reach_db_zero
    helper = File.expand_path('../test_helper', __dir__)
    out, status = Open3.capture2e({ 'WURK_TEST_DB_OFFSET' => '-1', 'RUBYOPT' => '-rbundler/setup', 'COVERAGE' => nil },
                                  RbConfig.ruby, '-e', "require #{helper.inspect}; exit!(0)")

    refute_predicate status, :success?, out
    assert_includes out, 'DB 0'
  end

  def test_flush_refuses_a_connection_on_db_zero
    conn = Object.new
    def conn.call(*args) = args.first == 'CLIENT' ? 'id=1 db=0 sub=0' : raise('flushed DB 0')

    error = assert_raises(RuntimeError) { Wurk::Test.flush!(conn) }
    assert_includes error.message, 'refusing FLUSHDB'
  end

  def test_flush_wipes_the_workers_own_db
    Wurk.redis do |conn|
      conn.call('SET', 'flush-me', '1')
      Wurk::Test.flush!(conn)

      assert_nil conn.call('GET', 'flush-me')
    end
  end
end

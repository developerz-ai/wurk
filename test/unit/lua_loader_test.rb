# frozen_string_literal: true

require_relative '../test_helper'

class LuaLoaderTest < Wurk::Test::UnitCase
  parallelize_me!


  def setup
    super
    @pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'loader-test')
    @ns   = "loadertest:#{Process.pid}:#{object_id}"
  end

  def teardown
    @pool.with do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', "#{@ns}:*", 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
    end
    @pool.disconnect!
  ensure
    super
  end

  # --- script_load_all ------------------------------------------------

  def test_script_load_all_registers_every_script_with_redis
    @pool.with do |c|
      Wurk::Lua::Loader.script_load_all(c)
      shas    = Wurk::Lua::SHAS.values
      present = c.call('SCRIPT', 'EXISTS', *shas)

      assert(present.all? { |v| v == 1 }, "all SHAs must be cached after script_load_all, got #{present.inspect}")
    end
  end

  # --- eval_cached happy path ----------------------------------------

  def test_eval_cached_executes_and_returns_lua_value
    set_key = "#{@ns}:s"
    @pool.with do |c|
      Wurk::Lua::Loader.script_load_all(c)
      c.call('ZADD', set_key, 1, 'job-one')
      result = Wurk::Lua::Loader.eval_cached(c, :zpopbyscore, keys: [set_key], argv: [10])

      assert_equal 'job-one', result
    end
  end

  def test_eval_cached_raises_argument_error_for_unknown_script
    @pool.with do |c|
      err = assert_raises(ArgumentError) do
        Wurk::Lua::Loader.eval_cached(c, :nope, keys: [], argv: [])
      end

      assert_match(/unknown Lua script/, err.message)
    end
  end

  # --- NOSCRIPT recovery ---------------------------------------------
  #
  # Stages a connection that raises NOSCRIPT exactly once. The loader
  # must catch it, issue SCRIPT LOAD, and re-issue EVALSHA. A real
  # SCRIPT FLUSH would race other parallel tests, so we use a fake.

  def test_eval_cached_recovers_from_noscript_with_one_retry
    conn = FakeNoscriptConn.new(noscript_times: 1, eventual_result: 'OK')
    result = Wurk::Lua::Loader.eval_cached(conn, :zpopbyscore, keys: ['k'], argv: ['0'])

    assert_equal 'OK', result
    assert_equal %w[EVALSHA SCRIPT EVALSHA], conn.command_log
  end

  def test_eval_cached_re_raises_noscript_after_one_retry
    conn = FakeNoscriptConn.new(noscript_times: 2, eventual_result: 'OK')
    assert_raises(RedisClient::CommandError) do
      Wurk::Lua::Loader.eval_cached(conn, :zpopbyscore, keys: ['k'], argv: ['0'])
    end
    assert_equal %w[EVALSHA SCRIPT EVALSHA], conn.command_log
  end

  def test_eval_cached_passes_through_non_noscript_errors_without_retry
    conn = FakeErrorConn.new(message: 'ERR wrong number of arguments')
    err = assert_raises(RedisClient::CommandError) do
      Wurk::Lua::Loader.eval_cached(conn, :zpopbyscore, keys: ['k'], argv: ['0'])
    end

    assert_match(/wrong number of arguments/, err.message)
    assert_equal 1, conn.call_count
  end

  # Stand-in connection that simulates Redis returning NOSCRIPT on the
  # first N EVALSHA calls, then succeeds. Records command names so the
  # test can assert the SCRIPT LOAD + retry sequence happened.
  class FakeNoscriptConn
    attr_reader :command_log

    def initialize(noscript_times:, eventual_result:)
      @noscript_times = noscript_times
      @eventual_result = eventual_result
      @evalsha_calls = 0
      @command_log = []
    end

    def call(*args)
      @command_log << args[0]
      case args[0]
      when 'EVALSHA'
        @evalsha_calls += 1
        if @evalsha_calls <= @noscript_times
          raise RedisClient::CommandError, "NOSCRIPT No matching script. Use EVAL. #{args[1]}"
        end

        @eventual_result
      when 'SCRIPT'
        Wurk::Lua::SHAS.values.first
      end
    end
  end

  # Stand-in connection that raises a non-NOSCRIPT command error so we
  # can prove the loader does not retry on unrelated failures.
  class FakeErrorConn
    attr_reader :call_count

    def initialize(message:)
      @message = message
      @call_count = 0
    end

    def call(*_args)
      @call_count += 1
      raise RedisClient::CommandError, @message
    end
  end
end

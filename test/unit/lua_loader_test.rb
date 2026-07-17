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

  # The eager post-fork load must cost one round-trip, not one per script —
  # a regression to N separate SCRIPT LOADs would re-open the boot-latency
  # hole the #101 fix closed.
  def test_script_load_all_batches_into_a_single_pipeline
    conn = FakePipelineConn.new
    Wurk::Lua::Loader.script_load_all(conn)

    assert_equal 1, conn.pipeline_count, 'script_load_all must batch into exactly one pipeline'
    assert_equal Wurk::Lua::SCRIPTS.size, conn.loaded.size, 'every registered script must be loaded'
    assert(conn.loaded.all? { |cmd| cmd.first(2) == %w[SCRIPT LOAD] },
           "expected only SCRIPT LOADs, got #{conn.loaded.inspect}")
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

  # --- eval_with_source ----------------------------------------------
  #
  # Source-embedded EVAL is the recovery path used by `push_batched_pipelined`
  # when an EVALSHA-in-pipeline races a freshly-loaded script and re-raises
  # NOSCRIPT (observed in CI on test (3.4, 7.2)). Because EVAL ships the
  # script body, it cannot fail with NOSCRIPT no matter what the cache state
  # is — that's exactly the invariant the retry depends on.
  #
  # We can't `SCRIPT FLUSH` against the real Redis because the script cache
  # is global across the parallel_fork workers' isolated DBs, so a flush would
  # destabilize peer tests. End-to-end EVAL semantics against real Redis are
  # already covered by the existing eval_cached happy-path test (post-load
  # EVALSHA hits the same code path as EVAL on the server).

  def test_eval_with_source_uses_eval_not_evalsha
    set_key = "#{@ns}:s2"
    @pool.with do |c|
      c.call('ZADD', set_key, 1, 'job-two')
      result = Wurk::Lua::Loader.eval_with_source(c, :zpopbyscore, keys: [set_key], argv: [10])

      assert_equal 'job-two', result
    end
  end

  def test_eval_with_source_raises_argument_error_for_unknown_script
    @pool.with do |c|
      err = assert_raises(ArgumentError) do
        Wurk::Lua::Loader.eval_with_source(c, :nope, keys: [], argv: [])
      end

      assert_match(/unknown Lua script/, err.message)
    end
  end

  def test_eval_with_source_sends_eval_command_with_full_script_body
    conn = FakeEvalConn.new(eventual_result: 'OK')
    Wurk::Lua::Loader.eval_with_source(conn, :zpopbyscore, keys: ['k'], argv: ['0'])

    # Single composite assertion: command shape AND script body in one place
    # so reviewers see the EVAL-vs-EVALSHA invariant at a glance.
    assert_equal(
      { commands: ['EVAL'], source: Wurk::Lua::SCRIPTS[:zpopbyscore] },
      { commands: conn.command_log, source: conn.last_script_source }
    )
  end

  # Stand-in connection that records the pipelined SCRIPT LOADs so the test
  # can assert script_load_all uses one pipeline (not a call-per-script loop).
  class FakePipelineConn
    attr_reader :pipeline_count, :loaded

    def initialize
      @pipeline_count = 0
      @loaded = []
    end

    def pipelined
      @pipeline_count += 1
      yield Pipe.new(@loaded)
      []
    end

    class Pipe
      def initialize(sink) = @sink = sink
      def call(*args) = @sink << args
    end
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

  # Stand-in connection that captures the EVAL command shape so we can
  # assert eval_with_source ships the full script body (never EVALSHA).
  class FakeEvalConn
    attr_reader :command_log, :last_script_source

    def initialize(eventual_result:)
      @eventual_result = eventual_result
      @command_log = []
      @last_script_source = nil
    end

    def call(*args)
      @command_log << args[0]
      @last_script_source = args[1] if args[0] == 'EVAL'
      @eventual_result
    end
  end
end

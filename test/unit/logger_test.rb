# frozen_string_literal: true

require_relative '../test_helper'

# Helpers shared between LoggerTest and LoggerEnvTest. ENV mutations are
# serialized via ENV_MUTEX so the env-touching class can still opt into the
# parallel runner without cross-test interference.
module LoggerTestHelpers
  private

  ENV_MUTEX = Mutex.new

  def format_with(formatter, severity, message)
    formatter.call(severity, Time.utc(2026, 1, 2, 3, 4, 5), nil, message)
  end

  def with_env(pairs)
    ENV_MUTEX.synchronize do
      old = pairs.transform_values { |_| nil }
      pairs.each_key { |k| old[k] = ENV.fetch(k, nil) }
      pairs.each { |k, v| ENV[k] = v }
      yield
    ensure
      old.each { |k, v| ENV[k] = v }
    end
  end
end

class LoggerTest < Wurk::Test::UnitCase
  include LoggerTestHelpers

  parallelize_me!

  def teardown
    Thread.current[Wurk::Context::KEY] = nil
  end

  def test_is_a_kind_of_stdlib_logger
    assert_kind_of ::Logger, Wurk::Logger.new(IO::NULL)
  end

  # --- Pretty formatter -------------------------------------------------

  def test_pretty_includes_iso8601_timestamp
    line = format_with(Wurk::Logger::Formatters::Pretty.new, 'INFO', 'start')

    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/, line)
  end

  def test_pretty_includes_severity_pid_tid_and_message
    line = format_with(Wurk::Logger::Formatters::Pretty.new, 'INFO', 'start')

    assert_match(/INFO.*pid=#{::Process.pid}.*tid=[a-z0-9]+.*: start$/, line.chomp)
  end

  def test_pretty_formats_context_keys
    Wurk::Context.with(jid: 'abc', class: 'MyJob') do
      line = format_with(Wurk::Logger::Formatters::Pretty.new, 'INFO', 'done')

      assert_match(/jid=abc/, line)
      assert_match(/class=MyJob/, line)
    end
  end

  def test_pretty_joins_array_context_values_with_commas
    Wurk::Context.with(tags: %w[high billing]) do
      line = format_with(Wurk::Logger::Formatters::Pretty.new, 'INFO', 'x')

      assert_match(/tags=high,billing/, line)
    end
  end

  def test_pretty_omits_context_segment_when_empty
    line = format_with(Wurk::Logger::Formatters::Pretty.new, 'INFO', 'x')

    refute_match(/jid=/, line)
  end

  # --- WithoutTimestamp formatter --------------------------------------

  def test_without_timestamp_omits_timestamp
    line = format_with(Wurk::Logger::Formatters::WithoutTimestamp.new, 'INFO', 'x')

    refute_match(/\d{4}-\d{2}-\d{2}T/, line)
    assert_match(/pid=#{::Process.pid}/, line)
  end

  # --- JSON formatter ---------------------------------------------------

  def test_json_emits_newline_terminated_line
    line = format_with(Wurk::Logger::Formatters::JSON.new, 'INFO', 'start')

    assert_equal "\n", line[-1]
  end

  def test_json_payload_contains_msg_lvl_pid_and_ts
    parsed = ::JSON.parse(format_with(Wurk::Logger::Formatters::JSON.new, 'INFO', 'start'))
    expected = { 'msg' => 'start', 'lvl' => 'INFO', 'pid' => ::Process.pid }

    assert_equal expected, parsed.slice('msg', 'lvl', 'pid')
  end

  def test_json_payload_timestamp_is_iso8601
    parsed = ::JSON.parse(format_with(Wurk::Logger::Formatters::JSON.new, 'INFO', 'start'))

    assert_match(/\d{4}-\d{2}-\d{2}T/, parsed['ts'])
  end

  def test_json_includes_ctx_when_present
    Wurk::Context.with(jid: 'abc') do
      parsed = ::JSON.parse(format_with(Wurk::Logger::Formatters::JSON.new, 'INFO', 'x'))

      assert_equal({ 'jid' => 'abc' }, parsed['ctx'])
    end
  end

  def test_json_omits_ctx_when_empty
    parsed = ::JSON.parse(format_with(Wurk::Logger::Formatters::JSON.new, 'INFO', 'x'))

    refute parsed.key?('ctx')
  end
end

# Mutates process-global ENV via with_env, which is mutex-guarded so the class
# can still run under the parallel runner.
class LoggerEnvTest < Wurk::Test::UnitCase
  include LoggerTestHelpers

  parallelize_me!

  def teardown
    Thread.current[Wurk::Context::KEY] = nil
  end

  # --- formatter selection ---------------------------------------------

  def test_default_formatter_is_pretty_without_dyno_env
    with_env('DYNO' => nil) do
      logger = Wurk::Logger.new(IO::NULL)

      assert_kind_of Wurk::Logger::Formatters::Pretty, logger.formatter
    end
  end

  def test_default_formatter_is_without_timestamp_with_dyno_env
    with_env('DYNO' => 'web.1') do
      logger = Wurk::Logger.new(IO::NULL)

      assert_kind_of Wurk::Logger::Formatters::WithoutTimestamp, logger.formatter
    end
  end

  # --- end-to-end ------------------------------------------------------

  def test_logger_uses_pretty_formatter_in_practice
    io = StringIO.new
    logger = with_env('DYNO' => nil) { Wurk::Logger.new(io) }
    logger.info('booting')

    assert_match(/INFO/, io.string)
    assert_match(/booting/, io.string)
  end
end

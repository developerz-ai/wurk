# frozen_string_literal: true

require_relative '../test_helper'

# The formatters build their lines in place instead of through map/join, and
# cache the `pid=` tag. Log scrapers parse these bytes, so the rewrite must be
# invisible: every line is compared against the expressions it replaced, kept
# here verbatim as the oracle, across the value shapes a context can carry.
class LoggerGoldenTest < Wurk::Test::UnitCase
  TIME = Time.utc(2026, 1, 2, 3, 4, 5.678r)

  # A value whose #to_s does not return a String: interpolation falls back to
  # the default inspect-ish form, and the formatter has to as well.
  class OddToS
    def to_s = :not_a_string
  end

  class Stringish < String; end

  CONTEXTS = [
    {},
    { jid: 'abc123', class: 'HardJob' },
    { jid: 'abc123', class: 'HardJob', elapsed: 0.007 },
    { jid: 'j', class: 'K', bid: 'b-1', tags: %w[high billing], elapsed: 12.5 },
    { tags: [], elapsed: 0.0 },
    { tags: ['a', :b, 3, nil, ['nested', 1.5]] },
    { 'string_key' => 'v', 7 => 8, nil => nil, true => false },
    { sym: :value, int: 42, big: 2**70, neg: -1, float: 1.0e-05, inf: Float::INFINITY },
    { odd: OddToS.new, sub: Stringish.new('sub'), klass: Integer },
    { unicode: 'café ✓', emoji: '🚀', 'clé' => 'été' }
  ].freeze

  MESSAGES = ['start', 'done', '', 'naïve ✓', nil, :sym, 42, RuntimeError.new('boom'), OddToS.new].freeze
  SEVERITIES = %w[DEBUG INFO WARN ERROR FATAL ANY].freeze

  def teardown
    Thread.current[Wurk::Context::KEY] = nil
  end

  def test_pretty_lines_are_byte_identical_to_the_map_join_formatter
    each_case do |ctx, severity, message|
      expected = "#{colors[severity]} #{TIME.dup.utc.iso8601(3)} pid=#{::Process.pid} " \
                 "tid=#{Wurk::Component.tid}#{reference_context(ctx)}: #{message}\n"

      assert_line expected, Wurk::Logger::Formatters::Pretty.new, ctx, severity, message
    end
  end

  def test_without_timestamp_lines_are_byte_identical_to_the_map_join_formatter
    each_case do |ctx, severity, message|
      expected = "#{colors[severity]} pid=#{::Process.pid} tid=#{Wurk::Component.tid}" \
                 "#{reference_context(ctx)}: #{message}\n"

      assert_line expected, Wurk::Logger::Formatters::WithoutTimestamp.new, ctx, severity, message
    end
  end

  def test_format_context_is_byte_identical_for_an_explicit_context
    formatter = Wurk::Logger::Formatters::Pretty.new
    actual = CONTEXTS.map { |ctx| formatter.format_context(ctx) }

    assert_equal CONTEXTS.map { |ctx| reference_context(ctx) }, actual
  end

  def test_a_forked_child_prints_its_own_pid
    formatter = Wurk::Logger::Formatters::Pretty.new
    formatter.call('INFO', TIME.dup, nil, 'warm')
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(formatter.call('INFO', TIME.dup, nil, 'child'))
      writer.close
      exit!(0)
    end
    writer.close
    line = reader.read
    Process.wait(pid)

    assert_includes line, " pid=#{pid} "
  end

  # The allocation the cut removed, pinned: a `done` line with the default
  # context used to build ~11 objects on top of the line itself. Measured with
  # GC disabled so a sweep cannot hide a regression.
  def test_a_done_line_allocates_at_most_four_objects
    formatter = Wurk::Logger::Formatters::Pretty.new
    Thread.current[Wurk::Context::KEY] = { jid: 'abc123', class: 'HardJob', elapsed: 0.007 }
    time = Time.now
    allocations { formatter.call('INFO', time, nil, 'done') } # warm the line and the helper

    # The line, the timestamp, the context buffer, the elapsed Float#to_s.
    assert_operator allocations { formatter.call('INFO', time, nil, 'done') }, :<=, 4
  end

  private

  def colors = Wurk::Logger::Formatters::Base::SEVERITY_COLORS

  # The pre-rewrite Base#format_context, verbatim.
  def reference_context(ctxt)
    return '' if ctxt.empty?

    " #{ctxt.map { |k, v| v.is_a?(Array) ? "#{k}=#{v.join(',')}" : "#{k}=#{v}" }.join(' ')}"
  end

  def each_case(&)
    CONTEXTS.each do |ctx|
      SEVERITIES.each do |severity|
        MESSAGES.each { |message| yield ctx, severity, message }
      end
    end
  end

  def assert_line(expected, formatter, ctx, severity, message)
    Thread.current[Wurk::Context::KEY] = ctx
    actual = formatter.call(severity, TIME.dup, nil, message)

    assert_equal expected.b, actual.b, "#{severity} #{message.inspect} #{ctx.inspect}"
    assert_equal expected.encoding, actual.encoding
  end

  def allocations
    GC.disable
    before = GC.stat(:total_allocated_objects)
    yield
    GC.stat(:total_allocated_objects) - before
  ensure
    GC.enable
  end
end

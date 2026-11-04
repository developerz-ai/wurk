# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'pty'
require 'stringio'

# Parity oracle for `Sidekiq::Logger` and `Sidekiq::Context`, written from the
# documented promise in docs/target/sidekiq-free.md §29, not from Wurk's
# logger code.
#
# §29 names three things: `Sidekiq::Logger` is a `Logger` subclass defaulting
# to INFO, its formatter is Pretty for a TTY, WithoutTimestamp under DYNO, or
# the opt-in JSON formatter; and `Sidekiq::Context.with` / `.add` carry a
# thread-local logging context. Each assertion below observes the logger or
# the context directly — the level it reports, the formatter it installed, the
# bytes it wrote, the context it holds.
class LoggerParityTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    Sidekiq::Context.current.clear
  end

  def teardown
    Sidekiq::Context.current.clear
    super
  end

  # --- §29 `Sidekiq::Logger` — `Logger` subclass. Default level INFO. -------

  def test_inheritance
    assert_operator Sidekiq::Logger, :<, ::Logger
  end

  # The level belongs to the logger a configuration hands out: upstream sets
  # it there too (`Sidekiq::Logger.new($stdout, level: :info)`), so the logger
  # an app gets is the one that logs at INFO.
  def test_default_level
    logger = Sidekiq::Config.new.logger

    assert_instance_of Sidekiq::Logger, logger
    assert_equal ::Logger::INFO, logger.level
  end

  # --- §29 `Sidekiq::Logger::Formatters::Pretty` (TTY default) -------------

  # A real pseudo-terminal, so the case is about the TTY destination the
  # document names, not about a stand-in for one.
  def test_pretty_tty
    assert_instance_of Sidekiq::Logger::Formatters::Pretty, Sidekiq::Config.new.logger.formatter

    PTY.open do |_reader, writer|
      logger = Sidekiq::Logger.new(writer)

      assert_instance_of Sidekiq::Logger::Formatters::Pretty, logger.formatter
    end
  end

  # --- §29 `Sidekiq::Logger::Formatters::WithoutTimestamp` (DYNO set) -------

  def test_dyno_formatter
    original = ENV.fetch('DYNO', nil)
    ENV['DYNO'] = 'web.1'
    io = StringIO.new
    logger = Sidekiq::Logger.new(io)
    logger.info('hello')
    line = io.string

    assert_instance_of Sidekiq::Logger::Formatters::WithoutTimestamp, logger.formatter
    refute_match(/\d{4}-\d{2}-\d{2}T/, line)
    assert_includes line, 'hello'
  ensure
    ENV['DYNO'] = original
  end

  # --- §29 `Sidekiq::Logger::Formatters::JSON` (opt-in) --------------------

  def test_json_opt_in
    io = StringIO.new
    logger = Sidekiq::Logger.new(io)
    logger.formatter = Sidekiq::Logger::Formatters::JSON.new
    logger.info('hello')

    record = JSON.parse(io.string)

    assert_equal 'INFO', record['lvl']
    assert_equal 'hello', record['msg']
    assert_equal Process.pid, record['pid']
    refute_empty record['ts']
  end

  # --- §29 `Sidekiq::Context.with(hash) { ... }` ----------------------------

  def test_context_with
    Sidekiq::Context.with(jid: 'abc123') do
      assert_equal 'abc123', Sidekiq::Context.current[:jid]
    end

    assert_empty Sidekiq::Context.current
  end

  # --- §29 `Sidekiq::Context.add(k, v)` -------------------------------------

  def test_context_add
    Sidekiq::Context.add(:jid, 'xyz789')

    assert_equal 'xyz789', Sidekiq::Context.current[:jid]
  end

  # --- §29 the logging context is thread-local -------------------------------

  # The documented promise: `Sidekiq::Context` stores its thread-local
  # logging context under `Thread.current[:wurk_context]`, and a context
  # added on one thread is not visible on another.
  def test_context_thread_local
    seen = Queue.new
    Sidekiq::Context.with(jid: 'main-thread') do
      Sidekiq::Context.add(:queue, 'critical')

      assert_equal({ jid: 'main-thread', queue: 'critical' }, Thread.current[:wurk_context],
                   'the context is stored under Wurk\'s own thread-local key')

      other = Thread.new do
        before = Sidekiq::Context.current.dup
        Sidekiq::Context.with(jid: 'other-thread') do
          Sidekiq::Context.add(:queue, 'low')
        end
        seen << [before, Sidekiq::Context.current.dup]
      end
      other.join

      assert_equal([{}, {}], seen.pop,
                   "another thread's context must not see this thread's entries")
      assert_equal 'main-thread', Sidekiq::Context.current[:jid],
                   "another thread's write must not reach this thread's context"
      assert_equal 'critical', Sidekiq::Context.current[:queue]
    end

    assert_empty Sidekiq::Context.current, '`with` restores the prior context on exit'
  end
end

# frozen_string_literal: true

require_relative '../test_helper'

class JobLoggerTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    @io = StringIO.new
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(@io)
    @config.logger.level = ::Logger::DEBUG
    @config.logger.formatter = ->(severity, _t, _p, msg) { "#{severity} #{msg}\n" }
    @logger = Wurk::JobLogger.new(@config)
  end

  def teardown
    Thread.current[Wurk::Context::KEY] = nil
  end

  # --- call: start / done / fail --------------------------------------

  def test_call_logs_start_then_done_on_success
    @logger.call({}, 'default') { :work }

    assert_match(/^INFO start$/, @io.string)
    assert_match(/^INFO done$/,  @io.string)
  end

  def test_call_returns_block_value
    refute_nil @logger.call({}, 'default') { :the_value }
  end

  def test_call_reraises_underlying_exception
    err = assert_raises(RuntimeError) do
      @logger.call({}, 'default') { raise 'boom' }
    end

    assert_equal 'boom', err.message
  end

  def test_call_logs_start_then_fail_on_exception
    assert_raises(RuntimeError) { @logger.call({}, 'default') { raise 'boom' } }

    assert_match(/^INFO start\nINFO fail$/, @io.string.strip)
  end

  def test_call_does_not_log_done_when_block_raises
    assert_raises(RuntimeError) { @logger.call({}, 'default') { raise 'x' } }

    refute_match(/^INFO done$/, @io.string)
  end

  def test_call_logs_fail_for_non_standard_errors
    assert_raises(SystemExit) do
      @logger.call({}, 'default') { raise SystemExit }
    end
    assert_match(/^INFO fail$/, @io.string)
  end

  # --- elapsed pushed into context -----------------------------------

  def test_call_adds_elapsed_to_context_on_success
    captured = nil
    Wurk::Context.with({}) do
      @logger.call({}, 'default') { captured = Wurk::Context.current.dup }

      assert_kind_of Float, Wurk::Context.current[:elapsed]
    end
    refute captured.key?(:elapsed)
  end

  def test_call_adds_elapsed_to_context_on_failure
    Wurk::Context.with({}) do
      assert_raises(RuntimeError) { @logger.call({}, 'default') { raise 'x' } }
      assert_kind_of Float, Wurk::Context.current[:elapsed]
    end
  end

  # --- skip_default_job_logging --------------------------------------

  def test_call_skips_logging_when_configured
    @config[:skip_default_job_logging] = true
    logger = Wurk::JobLogger.new(@config)
    logger.call({}, 'default') { :work }

    assert_empty @io.string
  end

  def test_call_still_records_elapsed_when_skipped
    @config[:skip_default_job_logging] = true
    logger = Wurk::JobLogger.new(@config)
    Wurk::Context.with({}) do
      logger.call({}, 'default') { :ok }

      assert_kind_of Float, Wurk::Context.current[:elapsed]
    end
  end

  # --- prepare: context wiring ---------------------------------------

  def test_prepare_sets_jid_and_class_context
    seen = nil
    @logger.prepare('jid' => 'abc', 'class' => 'MyJob') { seen = Wurk::Context.current.dup }

    assert_equal 'abc',   seen[:jid]
    assert_equal 'MyJob', seen[:class]
  end

  def test_prepare_unwraps_activejob_wrapped_class
    seen = nil
    @logger.prepare('jid' => '1', 'class' => 'AdapterWrapper', 'wrapped' => 'RealJob') do
      seen = Wurk::Context.current.dup
    end

    assert_equal 'RealJob', seen[:class]
  end

  def test_prepare_pulls_in_logged_job_attributes
    @config[:logged_job_attributes] = %w[bid tags custom]
    logger = Wurk::JobLogger.new(@config)
    seen = nil
    logger.prepare(
      'jid' => 'a', 'class' => 'J', 'bid' => 'B-1', 'tags' => %w[x y], 'custom' => 'k'
    ) { seen = Wurk::Context.current.dup }

    assert_equal 'B-1',   seen[:bid]
    assert_equal %w[x y], seen[:tags]
    assert_equal 'k',     seen[:custom]
  end

  def test_prepare_skips_logged_job_attributes_absent_from_hash
    seen = nil
    @logger.prepare('jid' => 'a', 'class' => 'J') { seen = Wurk::Context.current.dup }

    refute seen.key?(:bid)
    refute seen.key?(:tags)
  end

  def test_prepare_restores_context_after_block
    @logger.prepare('jid' => 'a', 'class' => 'J') { :noop }

    assert_empty Wurk::Context.current
  end

  def test_prepare_restores_context_when_block_raises
    assert_raises(RuntimeError) do
      @logger.prepare('jid' => 'a', 'class' => 'J') { raise 'kaboom' }
    end
    assert_empty Wurk::Context.current
  end

  # --- per-job log_level ----------------------------------------------

  def test_prepare_applies_per_job_log_level
    @config.logger.level = ::Logger::WARN
    inside = nil
    @logger.prepare('jid' => 'a', 'class' => 'J', 'log_level' => 'debug') do
      inside = @config.logger.level
    end

    assert_equal ::Logger::DEBUG, inside
    assert_equal ::Logger::WARN,  @config.logger.level
  end

  def test_prepare_without_log_level_leaves_logger_level_unchanged
    @config.logger.level = ::Logger::WARN
    inside = nil
    @logger.prepare('jid' => 'a', 'class' => 'J') { inside = @config.logger.level }

    assert_equal ::Logger::WARN, inside
  end

  # --- sidekiq alias --------------------------------------------------

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::JobLogger, Sidekiq::JobLogger
  end
end

# frozen_string_literal: true

require_relative '../test_helper'
require 'base64'
require 'zlib'
require 'securerandom'

# Drives Wurk::JobRetry against real Redis. Each test owns a private retry/
# dead ZSET via the `Keys::*` constant — but the retrier writes to the
# canonical keys (`retry`, `dead`) since that's the wire-compat contract. We
# track payloads we ZADD'd and ZREM them in teardown, plus we filter Redis
# `ZRANGE` reads to our jid so parallel runs don't cross-contaminate.
class JobRetryTest < Wurk::Test::UnitCase
  parallelize_me!

  class FailingJob
    include Wurk::Worker

    def perform; end
  end

  class CustomDelayJob
    include Wurk::Worker

    sidekiq_retry_in { |count, _ex, _msg| 42 + count }

    def perform; end
  end

  class DiscardJob
    include Wurk::Worker

    sidekiq_retry_in { :discard }

    def perform; end
  end

  class KillJob
    include Wurk::Worker

    sidekiq_retry_in { :kill }

    def perform; end
  end

  class RaisingRetryInJob
    include Wurk::Worker

    sidekiq_retry_in { raise 'inner boom' }

    def perform; end
  end

  class ExhaustedJob
    include Wurk::Worker

    @callbacks = []
    class << self
      attr_reader :callbacks
    end

    sidekiq_retries_exhausted { |msg, ex| callbacks << [msg, ex] }

    def perform; end
  end

  class DiscardOnExhaustionJob
    include Wurk::Worker

    sidekiq_retries_exhausted { :discard }

    def perform; end
  end

  class FloatDelayJob
    include Wurk::Worker

    sidekiq_retry_in { 12.9 }

    def perform; end
  end

  class ZeroDelayJob
    include Wurk::Worker

    sidekiq_retry_in { 0 }

    def perform; end
  end

  # Stands in for an ActiveJob-style wrapper target referenced via msg["wrapped"].
  # It exposes the per-class retry blocks the wrapped lookup prefers.
  class WrappedTarget
    include Wurk::Worker

    @retry_in_received = []
    @exhausted_received = []
    class << self
      attr_reader :retry_in_received, :exhausted_received
    end

    sidekiq_retry_in do |count, _ex, _msg|
      retry_in_received << count
      7
    end
    sidekiq_retries_exhausted do |msg, _ex|
      exhausted_received << msg['jid']
      nil
    end

    def perform; end
  end

  class WrappedRaisingTarget
    include Wurk::Worker

    sidekiq_retry_in { raise 'wrapped boom' }

    def perform; end
  end

  # Plain class (no Worker mixin) → does not respond to the block accessors,
  # so wrapped_block returns nil and falls back to the instance block.
  class PlainWrapped; end

  # Exception whose #backtrace is nil even after being raised — exercises the
  # nil-backtrace guard in stamp_backtrace.
  class NoBacktraceError < ::StandardError
    def backtrace
      nil
    end
  end

  # Minimal capsule double whose #config does not respond to `[]`, exercising
  # the inner_config_get fallback (returns nil → DEFAULT_MAX_RETRY_ATTEMPTS).
  class NoBracketConfig
    def initialize(logger)
      @logger = logger
    end
    attr_reader :logger
  end

  class CapsuleDouble
    def initialize(config)
      @config = config
    end
    attr_reader :config
  end

  def setup
    super
    @ns = "jr-#{Process.pid}-#{object_id}"
    @queue = "q-#{@ns}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @retrier = Wurk::JobRetry.new(@config)
    @pool = Wurk.configuration.redis_pool
    @added = []
  end

  def teardown
    @pool.with do |c|
      @added.compact.each do |payload|
        c.call('ZREM', Wurk::Keys::RETRY, payload)
        c.call('ZREM', Wurk::Keys::DEAD, payload)
      end
    end
  ensure
    super
  end

  # --- shape -----------------------------------------------------------

  def test_default_max_retries_constant
    assert_equal 25, Wurk::JobRetry::DEFAULT_MAX_RETRY_ATTEMPTS
  end

  def test_handled_is_runtime_error
    assert_operator Wurk::JobRetry::Handled, :<, ::RuntimeError
  end

  def test_skip_subclasses_handled
    assert_operator Wurk::JobRetry::Skip, :<, Wurk::JobRetry::Handled
  end

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::JobRetry, Sidekiq::JobRetry
  end

  def test_includes_component
    assert_includes Wurk::JobRetry.ancestors, Wurk::Component
  end

  # --- yields-through on success --------------------------------------

  def test_global_yields_and_returns_block_value
    assert_equal 7, @retrier.global(jobstr(retry: true), @queue) { 7 }
  end

  def test_local_yields_and_returns_block_value
    inst = FailingJob.new

    assert_equal 9, @retrier.local(inst, jobstr(retry: true), @queue) { 9 }
  end

  # --- Handled / Shutdown propagation ---------------------------------

  def test_global_re_raises_handled
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(jobstr(retry: true), @queue) { raise Wurk::JobRetry::Handled }
    end
  end

  def test_global_re_raises_skip_intact
    assert_raises(Wurk::JobRetry::Skip) do
      @retrier.global(jobstr(retry: true), @queue) { raise Wurk::JobRetry::Skip }
    end
  end

  def test_global_re_raises_shutdown
    assert_raises(Wurk::Shutdown) do
      @retrier.global(jobstr(retry: true), @queue) { raise Wurk::Shutdown }
    end
  end

  def test_global_converts_shutdown_cause_to_shutdown
    assert_raises(Wurk::Shutdown) do
      @retrier.global(jobstr(retry: true), @queue) do
        raise Wurk::Shutdown
      rescue Wurk::Shutdown
        raise StandardError, 'wrapped'
      end
    end
  end

  # --- global with retry=true: ZADD into retry -----------------------

  def test_global_zadds_into_retry_with_default_delay # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
    job = base_msg(retry: true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])

    assert payload, 'expected payload in retry set'
    @added << payload
    parsed = Wurk.load_json(payload)

    assert_equal 'boom', parsed['error_message']
    assert_equal 'RuntimeError', parsed['error_class']
    assert_equal 0, parsed['retry_count']
    assert parsed['failed_at']
    refute parsed['retried_at']
  end

  def test_global_bumps_retry_count_on_repeat_failure
    job = base_msg(retry: true, 'retry_count' => 0, 'failed_at' => Wurk::JobRetry::DEFAULT_MAX_RETRY_ATTEMPTS)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'again' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    parsed = Wurk.load_json(payload)

    assert_equal 1, parsed['retry_count']
    assert parsed['retried_at']
  end

  def test_global_routes_to_retry_queue_when_set
    job = base_msg(retry: true, 'retry_queue' => 'low')
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    assert_equal 'low', Wurk.load_json(payload)['queue']
  end

  def test_global_overwrites_queue_to_msg_queue_when_no_retry_queue
    job = base_msg(retry: true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), 'inbound') { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    assert_equal 'inbound', Wurk.load_json(payload)['queue']
  end

  def test_global_truncates_error_message_to_10k
    job = base_msg(retry: true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'x' * 20_000 }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    assert_equal 10_000, Wurk.load_json(payload)['error_message'].bytesize
  end

  def test_global_stores_compressed_backtrace_when_enabled # rubocop:disable Minitest/MultipleAssertions
    job = base_msg(retry: true, 'backtrace' => true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    encoded = Wurk.load_json(payload)['error_backtrace']

    refute_nil encoded
    decoded = ::Zlib::Inflate.inflate(::Base64.strict_decode64(encoded))
    lines = ::JSON.parse(decoded)

    assert_kind_of ::Array, lines
    refute_empty lines
  end

  def test_global_omits_backtrace_when_disabled
    job = base_msg(retry: true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    refute Wurk.load_json(payload).key?('error_backtrace')
  end

  def test_global_truncates_backtrace_to_n_lines
    job = base_msg(retry: true, 'backtrace' => 2)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    encoded = Wurk.load_json(payload)['error_backtrace']
    decoded = ::Zlib::Inflate.inflate(::Base64.strict_decode64(encoded))

    assert_equal 2, ::JSON.parse(decoded).size
  end

  # --- exhaustion → morgue ---------------------------------------------

  def test_global_sends_to_morgue_when_count_exceeds_attempts
    job = base_msg(retry: 1, 'retry_count' => 0)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'final' }
    end
    refute find_payload(Wurk::Keys::RETRY, job['jid']), 'should not be in retry set'
    payload = find_payload(Wurk::Keys::DEAD, job['jid'])
    @added << payload

    assert payload, 'should be in dead set'
  end

  def test_global_fires_death_handlers_on_morgue # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
    received = []
    @config.death_handlers << ->(msg, ex) { received << [msg['jid'], ex.message] }
    job = base_msg(retry: 1, 'retry_count' => 0)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'final' }
    end
    @added << find_payload(Wurk::Keys::DEAD, job['jid'])

    assert_equal 1, received.size
    assert_equal job['jid'], received.first.first
    assert_equal 'final', received.first.last
  end

  def test_global_fires_death_handlers_when_retry_false # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
    received = []
    @config.death_handlers << ->(msg, ex) { received << [msg['jid'], ex] }
    job = base_msg(retry: false)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'no-retry' }
    end
    refute find_payload(Wurk::Keys::RETRY, job['jid'])
    refute find_payload(Wurk::Keys::DEAD, job['jid'])
    assert_equal 1, received.size
  end

  def test_global_skips_morgue_when_dead_false
    received = []
    @config.death_handlers << ->(msg, _ex) { received << msg['jid'] }
    job = base_msg(retry: 1, 'retry_count' => 0, 'dead' => false)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    refute find_payload(Wurk::Keys::DEAD, job['jid']), 'should NOT be in morgue when dead:false'
    assert_equal 1, received.size
  end

  # --- local: per-class blocks ----------------------------------------

  def test_local_uses_class_default_retry_when_msg_retry_nil
    inst = FailingJob.new
    job = base_msg('retry' => nil)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    assert payload
  end

  def test_local_re_raises_when_retry_is_false
    inst = FailingJob.new
    job = base_msg(retry: false)
    err = assert_raises(StandardError) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    assert_equal 'boom', err.message
  end

  def test_local_re_raises_handled
    inst = FailingJob.new
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, jobstr(retry: true), @queue) { raise Wurk::JobRetry::Handled }
    end
  end

  def test_local_re_raises_shutdown
    inst = FailingJob.new
    assert_raises(Wurk::Shutdown) do
      @retrier.local(inst, jobstr(retry: true), @queue) { raise Wurk::Shutdown }
    end
  end

  def test_local_honors_sidekiq_retry_in_block # rubocop:disable Metrics/AbcSize
    inst = CustomDelayJob.new
    job = base_msg(retry: true)
    before = ::Time.now.to_f
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    score = @pool.with { |c| c.call('ZSCORE', Wurk::Keys::RETRY, payload).to_f }
    # delay was 42 + 0 = 42 (count=0); plus 0..9 jitter
    assert_operator score, :>=, before + 42
    assert_operator score, :<=, before + 42 + 11
  end

  def test_local_discard_strategy_skips_retry_and_morgue # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
    inst = DiscardJob.new
    received = []
    @config.death_handlers << ->(msg, _ex) { received << msg['jid'] }
    job = base_msg(retry: true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    refute find_payload(Wurk::Keys::RETRY, job['jid'])
    refute find_payload(Wurk::Keys::DEAD, job['jid'])
    assert_equal 1, received.size
  end

  def test_local_kill_strategy_sends_to_morgue
    inst = KillJob.new
    job = base_msg(retry: true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    refute find_payload(Wurk::Keys::RETRY, job['jid'])
    payload = find_payload(Wurk::Keys::DEAD, job['jid'])
    @added << payload

    assert payload
  end

  def test_local_falls_back_to_default_when_retry_in_block_raises
    inst = RaisingRetryInJob.new
    job = base_msg(retry: true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    assert payload, 'fell back to default schedule_retry'
  end

  def test_local_runs_retries_exhausted_block # rubocop:disable Metrics/AbcSize
    ExhaustedJob.callbacks.clear
    inst = ExhaustedJob.new
    job = base_msg(retry: 0, 'retry_count' => 0)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'final' }
    end
    @added << find_payload(Wurk::Keys::DEAD, job['jid'])

    assert_equal 1, ExhaustedJob.callbacks.size
    assert_equal 'final', ExhaustedJob.callbacks.first.last.message
  end

  def test_local_exhausted_block_can_force_discard
    inst = DiscardOnExhaustionJob.new
    job = base_msg(retry: 0, 'retry_count' => 0)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'gone' }
    end
    refute find_payload(Wurk::Keys::DEAD, job['jid'])
  end

  # --- retry_for ---------------------------------------------------------

  def test_retry_for_uses_duration_not_count # rubocop:disable Metrics/AbcSize
    failed_at = (::Time.now - 3600).to_f * 1000
    job = base_msg(retry: 999, 'retry_count' => 0, 'failed_at' => failed_at.to_i, 'retry_for' => 60)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'expired' }
    end
    refute find_payload(Wurk::Keys::RETRY, job['jid'])
    payload = find_payload(Wurk::Keys::DEAD, job['jid'])
    @added << payload

    assert payload, 'retry_for exceeded → morgue'
  end

  def test_retry_for_not_exceeded_continues_to_retry
    job = base_msg(retry: true, 'retry_for' => 3600)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'not yet' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    assert payload
  end

  # --- branch coverage: local shutdown-cause (line 76) -----------------

  def test_local_converts_shutdown_cause_to_shutdown
    inst = FailingJob.new
    assert_raises(Wurk::Shutdown) do
      @retrier.local(inst, jobstr(retry: true), @queue) do
        raise Wurk::Shutdown
      rescue Wurk::Shutdown
        raise StandardError, 'wrapped'
      end
    end
  end

  # --- branch coverage: nil backtrace despite backtrace flag (line 167) -

  def test_global_skips_backtrace_when_exception_backtrace_nil
    job = base_msg(retry: true, 'backtrace' => true)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise NoBacktraceError, 'no bt' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    refute Wurk.load_json(payload).key?('error_backtrace'), 'nil backtrace → field omitted'
  end

  # --- branch coverage: retry_for with no failed_at (line 175 then) -----

  def test_retry_for_with_missing_failed_at_continues_to_retry
    # retry_count present (so bump_retry_count won't set failed_at) but
    # failed_at absent → retry_for_exceeded? bails out via `unless failed_at`.
    job = base_msg(retry: 999, 'retry_count' => 0, 'retry_for' => 60)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'no failed_at' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload

    assert payload, 'no failed_at → not exhausted → scheduled for retry'
  end

  # --- branch coverage: time_for Float path (line 195 then) ------------

  def test_retry_for_treats_float_failed_at_as_seconds
    # failed_at as a Float (epoch seconds) far in the past + small retry_for
    # → time_for takes the Float branch and the window is exceeded → morgue.
    job = base_msg(retry: 999, 'retry_count' => 5, 'failed_at' => (::Time.now - 7200).to_f, 'retry_for' => 60)
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'expired' }
    end
    refute find_payload(Wurk::Keys::RETRY, job['jid'])
    payload = find_payload(Wurk::Keys::DEAD, job['jid'])
    @added << payload

    assert payload, 'float failed_at past retry_for → morgue'
  end

  # --- branch coverage: delay_for Float coercion (line 205 then) -------

  def test_local_coerces_float_retry_in_to_integer_delay
    inst = FloatDelayJob.new
    job = base_msg(retry: true)
    before = ::Time.now.to_f
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    score = @pool.with { |c| c.call('ZSCORE', Wurk::Keys::RETRY, payload).to_f }

    # 12.9 → to_i → 12; plus 0..9 jitter (count=0).
    assert_operator score, :>=, before + 12
    assert_operator score, :<=, before + 12 + 10
  end

  # --- branch coverage: non-positive Integer delay → default (line 210 else)

  def test_local_falls_back_to_default_when_retry_in_returns_zero
    inst = ZeroDelayJob.new
    job = base_msg(retry: true)
    before = ::Time.now.to_f
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    score = @pool.with { |c| c.call('ZSCORE', Wurk::Keys::RETRY, payload).to_f }

    # rv=0 is not positive → default_delay = 0**4 + 15 = 15 (+0..9 jitter).
    assert_operator score, :>=, before + 15
    assert_operator score, :<=, before + 15 + 10
  end

  # --- branch coverage: wrapped retry_in block (line 222 then, 258 then) -

  def test_global_prefers_wrapped_retry_in_block
    WrappedTarget.retry_in_received.clear
    job = base_msg(retry: true, 'wrapped' => 'JobRetryTest::WrappedTarget')
    before = ::Time.now.to_f
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    score = @pool.with { |c| c.call('ZSCORE', Wurk::Keys::RETRY, payload).to_f }

    refute_empty WrappedTarget.retry_in_received, 'wrapped block was invoked'
    # delay 7 + 0..9 jitter
    assert_operator score, :>=, before + 7
    assert_operator score, :<=, before + 7 + 10
  end

  # --- branch coverage: wrapped class lacks accessor (line 258 else) ----

  def test_wrapped_lookup_falls_back_when_target_not_a_worker
    inst = CustomDelayJob.new
    job = base_msg(retry: true, 'wrapped' => 'JobRetryTest::PlainWrapped')
    before = ::Time.now.to_f
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(inst, Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    score = @pool.with { |c| c.call('ZSCORE', Wurk::Keys::RETRY, payload).to_f }

    # PlainWrapped does not respond to the accessor → nil → fall back to the
    # instance's CustomDelayJob block (42 + count=0 = 42).
    assert_operator score, :>=, before + 42
    assert_operator score, :<=, before + 42 + 11
  end

  # --- branch coverage: wrapped retry_in block raises with nil jobinst --
  #     (line 221 else-sides, 225 else-sides — handle_exception gets a nil class)

  def test_global_wrapped_retry_in_block_raising_falls_back_to_default
    job = base_msg(retry: true, 'wrapped' => 'JobRetryTest::WrappedRaisingTarget')
    before = ::Time.now.to_f
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'boom' }
    end
    payload = find_payload(Wurk::Keys::RETRY, job['jid'])
    @added << payload
    score = @pool.with { |c| c.call('ZSCORE', Wurk::Keys::RETRY, payload).to_f }

    # wrapped block raised → rescued → nil → default_delay 15 (+0..9 jitter).
    assert payload, 'fell back to default schedule_retry after wrapped block raised'
    assert_operator score, :>=, before + 15
    assert_operator score, :<=, before + 15 + 10
  end

  # --- branch coverage: wrapped retries_exhausted block (line 247 then) -

  def test_global_prefers_wrapped_exhausted_block
    WrappedTarget.exhausted_received.clear
    job = base_msg(retry: 0, 'retry_count' => 0, 'wrapped' => 'JobRetryTest::WrappedTarget')
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.global(Wurk.dump_json(job), @queue) { raise 'final' }
    end
    @added << find_payload(Wurk::Keys::DEAD, job['jid'])

    assert_includes WrappedTarget.exhausted_received, job['jid'], 'wrapped exhausted block ran'
  end

  # --- branch coverage: inner_config_get fallback (line 317 else) ------

  def test_initialize_uses_default_max_retries_when_config_lacks_bracket
    cfg = NoBracketConfig.new(::Logger.new(IO::NULL))
    retrier = Wurk::JobRetry.new(CapsuleDouble.new(cfg))

    assert_equal(
      Wurk::JobRetry::DEFAULT_MAX_RETRY_ATTEMPTS,
      retrier.instance_variable_get(:@max_retries)
    )
    assert_nil retrier.instance_variable_get(:@backtrace_cleaner)
  end

  # --- helpers ---------------------------------------------------------

  private

  def base_msg(extra = {})
    {
      'class' => 'JobRetryTest::FailingJob',
      'args' => [],
      'queue' => @queue,
      'jid' => "#{@ns}-#{SecureRandom.hex(8)}",
      'created_at' => ::Time.now.to_f
    }.merge(extra.transform_keys(&:to_s))
  end

  def jobstr(extra = {})
    Wurk.dump_json(base_msg(extra))
  end

  # Linear scan over the canonical sorted set, filtered by our jid. Avoids
  # cross-test interference when many tests target the global `retry`/`dead`
  # keys in parallel.
  def find_payload(key, jid)
    @pool.with do |c|
      c.call('ZRANGE', key, 0, -1).find { |raw| raw.include?(%("jid":"#{jid}")) }
    end
  end
end

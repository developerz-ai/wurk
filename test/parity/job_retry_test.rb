# frozen_string_literal: true

require_relative '../test_helper'
require 'base64'
require 'zlib'
require 'securerandom'

# Parity test for JobRetry. Mirrors the surface third-party gems and the
# upstream test suite depend on: error payload field names + encodings,
# retry-count semantics, exhaustion handoff to the morgue, retry_queue
# routing, and `sidekiq_retry_in` strategy returns.
#
# When this file diverges from upstream Sidekiq's tests, Wurk is wrong
# unless the divergence is explicitly documented in
# docs/target/sidekiq-free.md §17.
class JobRetryParityTest < Wurk::Test::UnitCase
  parallelize_me!

  class ParityJob
    include Sidekiq::Worker

    def perform(*); end
  end

  class RetryQueueJob
    include Sidekiq::Worker

    sidekiq_options retry_queue: 'lowprio'

    def perform; end
  end

  def setup
    super
    @ns = "jrp-#{Process.pid}-#{object_id}"
    @queue = "q-#{@ns}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @retrier = Sidekiq::JobRetry.new(@config)
    @pool = Wurk.configuration.redis_pool
    @added = []
  end

  def teardown
    @pool.with do |c|
      @added.compact.each do |payload|
        c.call('ZREM', 'retry', payload)
        c.call('ZREM', 'dead', payload)
      end
    end
  ensure
    super
  end

  # --- handled / skip ----------------------------------------------------

  def test_handled_is_runtime_error
    assert_operator Sidekiq::JobRetry::Handled, :<, ::RuntimeError
  end

  def test_skip_is_handled
    assert_operator Sidekiq::JobRetry::Skip, :<, Sidekiq::JobRetry::Handled
  end

  def test_default_max_retry_attempts
    assert_equal 25, Sidekiq::JobRetry::DEFAULT_MAX_RETRY_ATTEMPTS
  end

  # --- error payload (upstream §17.3) -----------------------------------

  def test_error_message_truncated_to_10k
    job = base_msg(retry: true)
    drive_retry(job) { raise 'x' * 50_000 }
    parsed = find_parsed('retry', job['jid'])

    assert_equal 10_000, parsed['error_message'].bytesize
  end

  def test_error_class_recorded
    job = base_msg(retry: true)
    drive_retry(job) { raise ArgumentError, 'bad' }
    parsed = find_parsed('retry', job['jid'])

    assert_equal 'ArgumentError', parsed['error_class']
  end

  def test_first_failure_sets_failed_at_and_retry_count_zero
    job = base_msg(retry: true)
    drive_retry(job) { raise 'boom' }
    parsed = find_parsed('retry', job['jid'])

    assert_equal 0, parsed['retry_count']
    assert parsed['failed_at']
    refute parsed['retried_at']
  end

  def test_subsequent_failure_increments_and_stamps_retried_at
    job = base_msg(retry: true, 'retry_count' => 3, 'failed_at' => 1)
    drive_retry(job) { raise 'boom' }
    parsed = find_parsed('retry', job['jid'])

    assert_equal 4, parsed['retry_count']
    assert parsed['retried_at']
  end

  def test_error_backtrace_is_base64_zlib_json
    job = base_msg(retry: true, 'backtrace' => true)
    drive_retry(job) { raise 'boom' }
    parsed = find_parsed('retry', job['jid'])
    encoded = parsed['error_backtrace']

    refute_nil encoded
    decoded = ::Zlib::Inflate.inflate(::Base64.strict_decode64(encoded))
    lines = ::JSON.parse(decoded)

    assert_kind_of ::Array, lines
  end

  # --- retry_queue routing (upstream §17, doc bullet 7 in §32) ---------

  def test_retry_queue_overrides_original_queue
    job = base_msg(retry: true, 'retry_queue' => 'low')
    drive_retry(job) { raise 'boom' }

    assert_equal 'low', find_parsed('retry', job['jid'])['queue']
  end

  def test_no_retry_queue_uses_current_queue
    job = base_msg(retry: true)
    drive_retry(job) { raise 'boom' }

    assert_equal @queue, find_parsed('retry', job['jid'])['queue']
  end

  # --- count vs attempts (upstream §17.2) -------------------------------

  def test_retry_count_at_attempts_promotes_to_morgue
    job = base_msg(retry: 3, 'retry_count' => 2)
    drive_retry(job) { raise 'final' }

    refute find_parsed('retry', job['jid'])
    parsed = find_parsed('dead', job['jid'])

    assert parsed
  end

  def test_retry_false_skips_retry_and_morgue
    received = []
    @config.death_handlers << ->(m, _e) { received << m['jid'] }
    job = base_msg(retry: false)
    drive_retry(job) { raise 'no retry' }

    refute find_parsed('retry', job['jid'])
    refute find_parsed('dead', job['jid'])
    assert_equal 1, received.size
  end

  # --- sidekiq_retry_in strategies (upstream §17.1) ---------------------

  def test_sidekiq_retry_in_integer_overrides_delay
    klass = Class.new do
      include Sidekiq::Worker

      sidekiq_retry_in { |_count, _ex, _msg| 99 }
      def perform; end
    end
    job = base_msg(retry: true, 'class' => klass.name || 'Anon')
    before = ::Time.now.to_f
    drive_retry(job, inst: klass.new) { raise 'boom' }
    payload = find_payload('retry', job['jid'])
    score = @pool.with { |c| c.call('ZSCORE', 'retry', payload).to_f }

    assert_operator score, :>=, before + 99
    assert_operator score, :<=, before + 99 + 11
  end

  def test_sidekiq_retry_in_discard_drops_silently
    klass = Class.new do
      include Sidekiq::Worker

      sidekiq_retry_in { :discard }
      def perform; end
    end
    received = []
    @config.death_handlers << ->(m, _e) { received << m['jid'] }
    job = base_msg(retry: true)
    drive_retry(job, inst: klass.new) { raise 'gone' }

    refute find_parsed('retry', job['jid'])
    refute find_parsed('dead', job['jid'])
    assert_equal 1, received.size
  end

  def test_sidekiq_retry_in_kill_sends_to_morgue
    klass = Class.new do
      include Sidekiq::Worker

      sidekiq_retry_in { :kill }
      def perform; end
    end
    job = base_msg(retry: true)
    drive_retry(job, inst: klass.new) { raise 'kill' }

    refute find_parsed('retry', job['jid'])
    assert find_parsed('dead', job['jid'])
  end

  # --- sidekiq_options retry: N retry semantics -------------------------

  def test_integer_retry_caps_attempts
    job = base_msg(retry: 0)
    drive_retry(job) { raise 'one-shot' }

    refute find_parsed('retry', job['jid'])
    assert find_parsed('dead', job['jid'])
  end

  # --- helpers ---------------------------------------------------------

  private

  def base_msg(extra = {})
    {
      'class' => 'JobRetryParityTest::ParityJob',
      'args' => [],
      'queue' => @queue,
      'jid' => "#{@ns}-#{SecureRandom.hex(8)}",
      'created_at' => ::Time.now.to_f
    }.merge(extra.transform_keys(&:to_s))
  end

  def drive_retry(msg, inst: nil, &block)
    jobstr = Wurk.dump_json(msg)
    assert_raises(Sidekiq::JobRetry::Handled) do
      if inst
        @retrier.local(inst, jobstr, @queue, &block)
      else
        @retrier.global(jobstr, @queue, &block)
      end
    end
    @added << find_payload('retry', msg['jid'])
    @added << find_payload('dead', msg['jid'])
  end

  def find_payload(key, jid)
    @pool.with do |c|
      c.call('ZRANGE', key, 0, -1).find { |raw| raw.include?(%("jid":"#{jid}")) }
    end
  end

  def find_parsed(key, jid)
    raw = find_payload(key, jid)
    raw && Wurk.load_json(raw)
  end
end

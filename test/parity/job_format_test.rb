# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'securerandom'

# Parity oracle for docs/job-format.md: a job written to Redis by hand, the way
# a producer in another language writes it, is run by a real
# `Sidekiq::Processor` with its arguments intact, and fails into the shapes the
# same document promises.
#
# Spec: docs/target/sidekiq-free.md §1.1 (`queues` SET, `queue:<name>` LIST,
# LPUSH), §1.2 (`schedule` ZSET, score = epoch float seconds), §2.1 (required
# fields), §2.2 (`enqueued_at`, `at`, `retry_count`, `failed_at`, `error_*`),
# §2.3 (integer epoch milliseconds), §2.4 (jid), §7.1 (scheduled members are
# stored without `enqueued_at` and `at`).
#
# No Wurk or Sidekiq client code builds the payloads below: each one is a JSON
# string assembled here and pushed with raw Redis commands.
class JobFormatParityTest < Wurk::Test::UnitCase
  parallelize_me!

  module Log
    MUTEX = Mutex.new
    @seen = []
    def self.record(entry) = MUTEX.synchronize { @seen << entry }
    def self.entries = MUTEX.synchronize { @seen.dup }
    def self.clear = MUTEX.synchronize { @seen.clear }
  end

  class EchoJob
    include Sidekiq::Job

    def perform(*args)
      Log.record(args)
    end
  end

  class FailingJob
    include Sidekiq::Job

    def perform(*)
      raise ArgumentError, 'boom'
    end
  end

  # JSON-native values a non-Ruby producer is likely to send, including an
  # integer past 2**53, which a lossy decoder anywhere on the path would round.
  ARGS = [
    9_007_199_254_740_993, -1, 1.5, 'naïve ✓', nil, true, false,
    { 'nested' => [1, { 'deep' => 'x' }] }, []
  ].freeze

  def setup
    super
    @token = SecureRandom.hex(6)
    @queue = "jf-#{@token}"
    @capsule = Sidekiq::Capsule.new("job-format-parity-#{@token}", Sidekiq.default_configuration)
    @capsule.queues = [@queue]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
    Log.clear
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
  ensure
    super
  end

  # §2.1 + §1.1: SADD the queue name, LPUSH the JSON. The worker sees exactly
  # the arguments the producer serialized.
  def test_a_hand_built_immediate_job_runs_with_its_arguments_intact
    jid = push_immediate(job(EchoJob, ARGS))

    run_one

    assert_equal [ARGS], Log.entries
    assert_equal 0, queue_size
    assert_nil Sidekiq::RetrySet.new.find_job(jid)
  end

  # §1.2 + §7.1: a scheduled job is a ZADD to `schedule`, score = epoch float
  # seconds, member stored without `enqueued_at`. Promotion stamps
  # `enqueued_at` as integer milliseconds and the job then runs unchanged.
  def test_a_hand_built_scheduled_job_is_promoted_and_runs
    payload = job(EchoJob, ARGS)
    redis('ZADD', 'schedule', (Time.now.to_f - 1).to_s, JSON.generate(payload))

    Sidekiq::Scheduled::Enq.new(Sidekiq.default_configuration).enqueue_jobs(['schedule'])
    promoted = JSON.parse(redis('LINDEX', "queue:#{@queue}", 0))

    assert_kind_of Integer, promoted['enqueued_at']
    assert_in_delta Time.now.to_f * 1000, promoted['enqueued_at'], 60_000
    assert_includes redis('SMEMBERS', 'queues'), @queue
    assert_equal payload.except('enqueued_at'), promoted.except('enqueued_at')

    run_one

    assert_equal [ARGS], Log.entries
  end

  # §2.2: a first failure lands in `retry` carrying `retry_count` 0,
  # `error_class`, `error_message` and integer-millisecond `failed_at`, and
  # every field the producer wrote comes back unchanged.
  def test_a_hand_built_job_that_fails_lands_in_retry_in_the_documented_shape
    payload = job(FailingJob, [1])
    jid = push_immediate(payload)

    run_one
    entry = Sidekiq::RetrySet.new.find_job(jid)

    refute_nil entry
    assert_equal 0, entry['retry_count']
    assert_equal 'ArgumentError', entry['error_class']
    assert_equal 'boom', entry['error_message']
    assert_kind_of Integer, entry['failed_at']
    assert_equal payload, entry.item.slice(*payload.keys)
    assert_operator entry.score, :>, Time.now.to_f
  end

  # §2.3: `enqueued_at` and `created_at` written as the old Float epoch
  # seconds are still read, so an older producer's jobs keep running.
  def test_float_second_timestamps_from_an_older_producer_still_run
    now = Time.now.to_f
    push_immediate(job(EchoJob, ['old']).merge('created_at' => now, 'enqueued_at' => now))

    run_one

    assert_equal [['old']], Log.entries
  end

  private

  # Every §2.1 required field, written by hand. `enqueued_at` is §2.2's, set
  # because this is an immediate push.
  def job(klass, args)
    now_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    {
      'class' => klass.name, 'args' => args, 'queue' => @queue, 'jid' => SecureRandom.hex(12),
      'created_at' => now_ms, 'enqueued_at' => now_ms, 'retry' => true
    }
  end

  def push_immediate(payload)
    redis('SADD', 'queues', @queue)
    redis('LPUSH', "queue:#{@queue}", JSON.generate(payload))
    payload['jid']
  end

  def redis(*command) = Sidekiq.redis { |conn| conn.call(*command) }

  def queue_size = redis('LLEN', "queue:#{@queue}")

  def run_one
    @processor.process_one
  rescue StandardError
    nil # the job's fate is asserted from Redis, not from the processor's raise
  ensure
    @capsule.fetcher.flush_pending_acks
  end
end

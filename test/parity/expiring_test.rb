# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'securerandom'

# Parity oracle for Sidekiq Pro job expiration, written from
# docs/target/sidekiq-pro.md §7, §8 and §12, not from Wurk's expiry code.
# Jobs run through a real `Sidekiq::Processor` over the default
# configuration's server chain, against real Redis.
#
# Enforced:
# - §7 `expires_in` (worker option or `set` override) is stored on the job as
#   `expiry`, an epoch-seconds Float = enqueue time + duration.
# - §7 a scheduled job expires `delay + expires_in` after perform_in (the
#   section's worked example).
# - §7 a job past `expiry` is skipped before perform and never retried; one
#   still in time runs normally.
# - §12 an expired job counts as success within a batch.
#
# `created_at` is epoch milliseconds (Sidekiq 8.1, see client_push_test.rb),
# so "created_at + duration" is compared in seconds.
class ExpiringParityTest < Wurk::Test::UnitCase
  parallelize_me!

  module Log
    MUTEX = Mutex.new
    @seen = []
    def self.record(entry) = MUTEX.synchronize { @seen << entry }
    def self.entries = MUTEX.synchronize { @seen.dup }
    def self.clear = MUTEX.synchronize { @seen.clear }
  end

  class ExpiringJob
    include Sidekiq::Job

    sidekiq_options expires_in: 3600

    def perform(token)
      Log.record(token)
    end
  end

  class PlainJob
    include Sidekiq::Job

    def perform(token)
      Log.record(token)
    end
  end

  def setup
    super
    @token = SecureRandom.hex(6)
    @queue = "xp-#{@token}"
    @capsule = Sidekiq::Capsule.new("expiring-parity-#{@token}", Sidekiq.default_configuration)
    @capsule.queues = [@queue]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
    @bids = []
    Log.clear
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
    Sidekiq.redis { |c| @bids.each { |bid| c.call('ZREM', 'batches', bid) } }
  ensure
    super
  end

  # --- §7 stored expiry ---------------------------------------------------

  def test_worker_option_stores_expiry_as_created_at_plus_duration
    ExpiringJob.set(queue: @queue).perform_async(@token)
    job = queued.first

    assert_kind_of Float, job['expiry']
    assert_in_delta (job['created_at'] / 1000.0) + 3600, job['expiry'], 0.01
  end

  def test_set_override_replaces_the_worker_duration
    ExpiringJob.set(queue: @queue, expires_in: 86_400).perform_async(@token)

    job = queued.first

    assert_in_delta (job['created_at'] / 1000.0) + 86_400, job['expiry'], 0.01
  end

  def test_set_override_on_a_worker_without_the_option
    PlainJob.set(queue: @queue, expires_in: 60).perform_async(@token)

    job = queued.first

    assert_in_delta (job['created_at'] / 1000.0) + 60, job['expiry'], 0.01
  end

  def test_no_expiry_without_the_option
    PlainJob.set(queue: @queue).perform_async(@token)

    refute queued.first.key?('expiry')
  end

  # §7's worked example is the precise half of that bullet: `perform_in(2h)`
  # with `expires_in: 1h` expires 3h after the perform_in call, i.e. the
  # duration counts from the time the job is due on its queue.
  def test_scheduled_job_expires_duration_after_it_is_due
    jid = ExpiringJob.set(queue: @queue).perform_in(7200, @token)
    entry = Sidekiq::ScheduledSet.new.find_job(jid)

    assert_in_delta entry.score + 3600, entry.item['expiry'], 0.01
  end

  # --- §7 execution -------------------------------------------------------

  def test_job_in_time_runs
    ExpiringJob.set(queue: @queue).perform_async(@token)
    run_one

    assert_equal [@token], Log.entries
  end

  def test_expired_job_is_skipped_and_not_retried
    jid = push_raw('expiry' => Time.now.to_f - 10)
    run_one

    assert_empty Log.entries
    assert_equal(0, Sidekiq.redis { |c| c.call('LLEN', "queue:#{@queue}") })
    assert_nil Sidekiq::RetrySet.new.find_job(jid)
    assert_nil Sidekiq::DeadSet.new.find_job(jid)
  end

  # --- §12 batches --------------------------------------------------------

  def test_expired_job_counts_as_success_in_a_batch
    batch = Sidekiq::Batch.new
    @bids << batch.bid
    batch.jobs { push_raw('expiry' => Time.now.to_f - 10) }
    run_one
    status = Sidekiq::Batch::Status.new(batch.bid)

    assert_empty Log.entries
    assert_equal 0, status.pending
    assert_equal 0, status.failures
    assert_predicate status, :complete?
  end

  private

  def queued = Sidekiq.redis { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |p| JSON.parse(p) }

  def push_raw(extra)
    Sidekiq::Client.push({ 'class' => PlainJob, 'queue' => @queue, 'args' => [@token] }.merge(extra))
  end

  def run_one
    @processor.process_one
  rescue StandardError
    nil # the job's fate is asserted from Redis, not from the processor's raise
  ensure
    @capsule.fetcher.flush_pending_acks
  end
end

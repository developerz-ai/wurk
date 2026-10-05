# frozen_string_literal: true

require_relative '../test_helper'
require 'digest'
require 'json'
require 'securerandom'

# Parity oracle for Sidekiq Enterprise unique jobs, written from
# docs/target/sidekiq-ent.md §3, not from Wurk's unique code. Jobs run through
# a real `Sidekiq::Processor` over the default configuration's server chain,
# against real Redis.
#
# Enforced:
# - §3.1 `Sidekiq::Enterprise.unique!` installs lock-on-push.
# - §3.2 / §3.7 a duplicate push returns nil while the lock is held;
#   `unique_until: :success` keeps the lock through a failure (the retry
#   still runs) and drops it on success; `:start` drops it before perform.
# - §3.3 `set(unique_for: false)` bypasses, `set(unique_for: n)` overrides.
# - §3.4 a scheduled job's lock lives `delay + unique_for`.
# - §3.5 `sidekiq_unique_context` replaces the digest context.
# - §3.6 `Unique.locked?` returns the holding JID.
# - §3.9 the lock is `unique:{sha256}` of the JSON context, holding the JID.
#
# `unique!` mutates the default configuration's middleware chains; every test
# restores them, so later classes in this worker see a stock chain.
class UniqueParityTest < Wurk::Test::UnitCase
  parallelize_me!

  module Log
    MUTEX = Mutex.new
    @seen = []
    def self.record(entry) = MUTEX.synchronize { @seen << entry }
    def self.entries = MUTEX.synchronize { @seen.dup }
    def self.clear = MUTEX.synchronize { @seen.clear }
  end

  class UntilSuccessJob
    include Sidekiq::Job

    sidekiq_options unique_for: 600

    def perform(token, mode)
      Log.record([token, :performed])
      raise 'fail' if mode == 'fail'
    end
  end

  def self.lock_key(klass, queue, args)
    "unique:#{Digest::SHA256.hexdigest(JSON.generate([klass, queue, args]))}"
  end

  class UntilStartJob
    include Sidekiq::Job

    sidekiq_options unique_for: 600, unique_until: :start

    def perform(token, mode)
      key = UniqueParityTest.lock_key(self.class.name, "up-#{token}", [token, mode])
      Log.record([token, :lock_during_perform, Sidekiq.redis { |c| c.call('GET', key) }])
      raise 'fail' if mode == 'fail'
    end
  end

  class ContextJob
    include Sidekiq::Job

    sidekiq_options unique_for: 600

    def self.sidekiq_unique_context(job)
      a = job['args'].dup
      a.pop if a.size == 3
      [job['class'], job['queue'], a]
    end

    def perform(*); end
  end

  def setup
    super
    @token = SecureRandom.hex(6)
    @queue = "up-#{@token}"
    @config = Sidekiq.default_configuration
    @client_before = @config.client_middleware.entries.map(&:klass)
    @server_before = @config.server_middleware.entries.map(&:klass)
    @was_unique = Sidekiq::Enterprise.unique?
    Sidekiq::Enterprise.unique!
    @capsule = Sidekiq::Capsule.new("unique-parity-#{@token}", @config)
    @capsule.queues = [@queue]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
    Log.clear
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
    (@config.client_middleware.entries.map(&:klass) - @client_before).each { |k| @config.client_middleware.remove(k) }
    (@config.server_middleware.entries.map(&:klass) - @server_before).each { |k| @config.server_middleware.remove(k) }
    Wurk::Unique.disable! unless @was_unique # spec §3 has no off switch; Wurk's test helper keeps later classes clean
  ensure
    super
  end

  # --- §3.7 push / duplicate ---------------------------------------------

  def test_duplicate_push_returns_nil_while_locked
    jid = push(UntilSuccessJob, [@token, 'ok'])

    refute_nil jid
    assert_nil push(UntilSuccessJob, [@token, 'ok'])
    assert_equal 1, queue_size
  end

  def test_different_args_are_not_duplicates
    refute_nil push(UntilSuccessJob, [@token, 'ok'])
    refute_nil push(UntilSuccessJob, [@token, 'other'])
    assert_equal 2, queue_size
  end

  def test_different_queue_is_not_a_duplicate
    refute_nil push(UntilSuccessJob, [@token, 'ok'])
    refute_nil UntilSuccessJob.set(queue: "#{@queue}-b").perform_async(@token, 'ok')
  ensure
    Sidekiq.redis { |c| c.call('DEL', "queue:#{@queue}-b") }
  end

  # --- §3.9 lock key ------------------------------------------------------

  def test_lock_key_is_sha256_of_json_context_holding_the_jid_with_unique_for_ttl
    args = [@token, 'ok']
    jid = push(UntilSuccessJob, args)
    key = lock_key(UntilSuccessJob.name, @queue, args)

    assert_equal jid, redis('GET', key)
    assert_in_delta 600, redis('TTL', key), 5
  end

  # --- §3.6 locked? -------------------------------------------------------

  def test_locked_returns_the_holding_jid_or_nil
    args = [@token, 'ok']

    assert_nil Sidekiq::Enterprise::Unique.locked?(@queue, UntilSuccessJob.name, args)
    jid = push(UntilSuccessJob, args)

    assert_equal jid, Sidekiq::Enterprise::Unique.locked?(@queue, UntilSuccessJob.name, args)
  end

  def test_locked_defaults_the_queue
    args = [@token, 'ok']
    jid = UntilSuccessJob.perform_async(*args)

    assert_equal jid, Sidekiq::Enterprise::Unique.locked?(UntilSuccessJob.name, args)
  ensure
    Sidekiq.redis { |c| c.call('DEL', 'queue:default') }
  end

  # --- §3.3 per-call override --------------------------------------------

  def test_unique_for_false_bypasses_the_lock
    args = [@token, 'ok']

    refute_nil UntilSuccessJob.set(queue: @queue, unique_for: false).perform_async(*args)
    refute_nil UntilSuccessJob.set(queue: @queue, unique_for: false).perform_async(*args)
    assert_nil redis('GET', lock_key(UntilSuccessJob.name, @queue, args))
  end

  def test_unique_for_override_sets_the_ttl
    args = [@token, 'ok']
    UntilSuccessJob.set(queue: @queue, unique_for: 60).perform_async(*args)

    assert_in_delta 60, redis('TTL', lock_key(UntilSuccessJob.name, @queue, args)), 5
  end

  # --- §3.4 scheduled -----------------------------------------------------

  def test_scheduled_lock_covers_delay_plus_unique_for
    args = [@token, 'ok']
    jid = UntilSuccessJob.set(queue: @queue).perform_in(3600, *args)
    key = lock_key(UntilSuccessJob.name, @queue, args)

    assert_equal jid, redis('GET', key)
    assert_in_delta 3600 + 600, redis('TTL', key), 5
    assert_nil UntilSuccessJob.set(queue: @queue).perform_in(3600, *args)
    assert_nil push(UntilSuccessJob, args)
  end

  # --- §3.5 custom context ------------------------------------------------

  def test_unique_context_controls_the_digest
    jid = push(ContextJob, [@token, 1, { 'opt' => 'a' }])

    assert_nil push(ContextJob, [@token, 1, { 'opt' => 'b' }])
    assert_equal jid, redis('GET', lock_key(ContextJob.name, @queue, [@token, 1]))
  end

  # --- §3.7 :success ------------------------------------------------------

  def test_until_success_releases_on_success
    args = [@token, 'ok']
    push(UntilSuccessJob, args)
    run_one

    assert_includes Log.entries, [@token, :performed]
    assert_nil redis('GET', lock_key(UntilSuccessJob.name, @queue, args))
    refute_nil push(UntilSuccessJob, args)
  end

  def test_until_success_keeps_the_lock_through_a_failure_and_the_retry_runs
    args = [@token, 'fail']
    jid = push(UntilSuccessJob, args)
    key = lock_key(UntilSuccessJob.name, @queue, args)
    run_one

    assert_equal jid, redis('GET', key)
    assert_nil push(UntilSuccessJob, args)
    retry_entry = Sidekiq::RetrySet.new.find_job(jid)

    refute_nil retry_entry
    retry_entry.add_to_queue
    run_one

    assert_equal 2, Log.entries.count([@token, :performed])
  end

  # --- §3.7 :start --------------------------------------------------------

  def test_until_start_drops_the_lock_before_perform
    args = [@token, 'ok']
    jid = push(UntilStartJob, args)
    key = lock_key(UntilStartJob.name, @queue, args)

    assert_equal jid, redis('GET', key)
    run_one

    assert_includes Log.entries, [@token, :lock_during_perform, nil]
    assert_nil redis('GET', key)
  end

  def test_until_start_lock_stays_gone_after_a_failure
    args = [@token, 'fail']
    push(UntilStartJob, args)
    run_one

    assert_includes Log.entries, [@token, :lock_during_perform, nil]
    assert_nil redis('GET', lock_key(UntilStartJob.name, @queue, args))
    refute_nil push(UntilStartJob, args), 'a duplicate may be enqueued once the lock is gone'
  end

  private

  def push(klass, args) = klass.set(queue: @queue).perform_async(*args)

  def lock_key(...) = self.class.lock_key(...)

  def redis(*cmd) = Sidekiq.redis { |c| c.call(*cmd) }

  def queue_size = redis('LLEN', "queue:#{@queue}")

  def run_one
    @processor.process_one
  rescue StandardError
    nil # the job's fate is asserted from Redis, not from the processor's raise
  ensure
    @capsule.fetcher.flush_pending_acks
  end
end

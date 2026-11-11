# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'securerandom'
require 'active_job'
require 'active_support/core_ext/integer/time'
require 'wurk/active_job/wrapper'
require 'active_job/queue_adapters/wurk_adapter'

# `unique_for: 5.minutes` is the form the Ent docs lead with (sidekiq-ent.md
# §3). The Duration survives until the push, where JSON.generate writes it as
# the string "300" — the same bytes Sidekiq writes — so every reader after the
# push sees a numeric string, not a number. These run the declaration through
# a real push, a real Processor and real Redis so the release is asserted on
# the payload as it comes back off the queue (tesote/tesote.com#519).
class UniqueDurationTest < Wurk::Test::UnitCase
  module Log
    MUTEX = Mutex.new
    @seen = []
    def self.record(entry) = MUTEX.synchronize { @seen << entry }
    def self.entries = MUTEX.synchronize { @seen.dup }
    def self.clear = MUTEX.synchronize { @seen.clear }
  end

  class DurationJob
    include Sidekiq::Job

    sidekiq_options unique_for: 5.minutes

    def perform(token) = Log.record([token, :performed])
  end

  class DurationStartJob
    include Sidekiq::Job

    sidekiq_options unique_for: 5.minutes, unique_until: :start

    def perform(token) = Log.record([token, :performed])
  end

  class DurationActiveJob < ::ActiveJob::Base
    self.queue_adapter = :wurk
    self.logger = ::Logger.new(nil)
    sidekiq_options unique_for: 5.minutes

    def perform(token) = Log.record([token, :performed])
  end

  def setup
    super
    @token = SecureRandom.hex(6)
    @queue = "ud-#{@token}"
    @config = Sidekiq.default_configuration
    @client_before = @config.client_middleware.entries.map(&:klass)
    @server_before = @config.server_middleware.entries.map(&:klass)
    @handlers_before = @config.death_handlers.dup
    @was_unique = Sidekiq::Enterprise.unique?
    Sidekiq::Enterprise.unique!
    @capsule = Sidekiq::Capsule.new("unique-duration-#{@token}", @config)
    @capsule.queues = [@queue]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
    Log.clear
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
    (@config.client_middleware.entries.map(&:klass) - @client_before).each { |k| @config.client_middleware.remove(k) }
    (@config.server_middleware.entries.map(&:klass) - @server_before).each { |k| @config.server_middleware.remove(k) }
    @config.death_handlers.replace(@handlers_before)
    Wurk::Unique.disable! unless @was_unique
  ensure
    super
  end

  def test_duration_is_written_as_sidekiq_writes_it
    DurationJob.set(queue: @queue).perform_async(@token)

    assert_equal '300', queued.first['unique_for']
  end

  def test_duration_locks_for_its_seconds
    DurationJob.set(queue: @queue).perform_async(@token)

    assert_in_delta 300, redis('TTL', lock_key_of(queued.first)), 5
  end

  def test_duration_lock_is_released_on_success
    jid = DurationJob.set(queue: @queue).perform_async(@token)
    key = lock_key_of(queued.first)

    assert_equal jid, redis('GET', key)
    run_one

    assert_includes Log.entries, [@token, :performed]
    assert_nil redis('GET', key)
    refute_nil DurationJob.set(queue: @queue).perform_async(@token)
  end

  def test_duration_lock_is_released_before_perform_with_until_start
    DurationStartJob.set(queue: @queue).perform_async(@token)
    key = lock_key_of(queued.first)
    run_one

    assert_includes Log.entries, [@token, :performed]
    assert_nil redis('GET', key)
  end

  def test_active_job_duration_dedups_and_releases
    DurationActiveJob.set(queue: @queue).perform_later(@token)
    DurationActiveJob.set(queue: @queue).perform_later(@token)

    assert_equal 1, queued.size, 'the second ActiveJob push must be deduped'
    payload = queued.first
    key = lock_key_of(payload)

    assert_equal '300', payload['unique_for']
    assert_in_delta 300, redis('TTL', key), 5
    run_one

    assert_includes Log.entries, [@token, :performed]
    assert_nil redis('GET', key)
  end

  private

  def queued = redis('LRANGE', "queue:#{@queue}", 0, -1).map { |s| JSON.parse(s) }

  def lock_key_of(payload) = Wurk::Unique.lock_key_for(payload)

  def redis(*cmd) = Sidekiq.redis { |c| c.call(*cmd) }

  def run_one
    @processor.process_one
  ensure
    @capsule.fetcher.flush_pending_acks
  end
end

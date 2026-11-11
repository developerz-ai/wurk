# frozen_string_literal: true

require_relative '../test_helper'
require 'active_job'
require 'active_job/queue_adapters/wurk_adapter'
require 'securerandom'

# Parity oracle for how `Sidekiq::Testing` modes meet the rest of the job API,
# written from docs/target/sidekiq-free.md §24 and docs/target/sidekiq-ent.md §3.
#
# - §24.3: in `inline!` mode the client's push runs `klass.process_job` for every
#   payload. Upstream's TestingClient#atomic_push (sidekiq-8.1.6
#   lib/sidekiq/test_api.rb) does not look at `at`, so `perform_in`,
#   `perform_at` and an ActiveJob `set(wait:)` run right away. An adopter suite
#   that patches `perform_in` / `enqueue_at` to run inline is reproducing what
#   the mode already does.
# - Ent §3.1 / §3.7: uniqueness is client middleware, and the testing hook sits
#   after the client chain (§24.3 patches `atomic_push`), so the lock is taken
#   in Redis and a duplicate is dropped in `fake!` mode too. Ent's own setup line
#   is `Sidekiq::Enterprise.unique! unless Rails.env.test?`: skipping it in tests
#   is upstream's answer, not a Wurk workaround.
class TestingModeParityTest < Wurk::Test::UnitCase
  parallelize_me!

  RAN = Queue.new

  class ScheduledJob
    include Sidekiq::Job

    def perform(tag) = RAN << tag
  end

  class UniqueJob
    include Sidekiq::Job

    sidekiq_options unique_for: 600

    def perform(*); end
  end

  class AJob < ActiveJob::Base
    self.queue_adapter = :wurk

    def perform(tag) = RAN << tag
  end

  def setup
    super
    RAN.clear
    ActiveJob::Base.logger = ::Logger.new(IO::NULL)
  end

  def teardown
    Sidekiq::Testing.disable!
    Sidekiq::Queues.clear_all
  ensure
    super
  end

  # --- §24.3 inline runs scheduled pushes now -------------------------------

  def test_inline_runs_perform_in_and_perform_at_immediately
    Sidekiq::Testing.inline! do
      ScheduledJob.perform_in(3600, 'in')
      ScheduledJob.perform_at(Time.now + 3600, 'at')
      ScheduledJob.set(wait: 3600).perform_async('set')
    end

    assert_equal %w[in at set], ran
  end

  def test_inline_runs_active_job_enqueue_and_enqueue_at_immediately
    Sidekiq::Testing.inline! do
      AJob.perform_later('now')
      AJob.set(wait: 3600).perform_later('wait')
      AJob.set(wait_until: Time.now + 3600).perform_later('until')
    end

    assert_equal %w[now wait until], ran
  end

  # --- Ent §3: unique is not bypassed by a test mode -------------------------

  def test_unique_still_locks_and_drops_the_duplicate_in_fake_mode
    with_unique do
      args = [SecureRandom.hex(6)]
      Sidekiq::Testing.fake! do
        refute_nil UniqueJob.perform_async(*args)
        assert_nil UniqueJob.perform_async(*args)
      end

      assert_equal 1, UniqueJob.jobs.size
      refute_nil Sidekiq::Enterprise::Unique.locked?('default', UniqueJob.name, args)
    end
  end

  private

  def ran = Array.new(RAN.size) { RAN.pop }

  def with_unique
    config = Sidekiq.default_configuration
    client_before = config.client_middleware.entries.map(&:klass)
    server_before = config.server_middleware.entries.map(&:klass)
    was_unique = Sidekiq::Enterprise.unique?
    Sidekiq::Enterprise.unique!
    yield
  ensure
    (config.client_middleware.entries.map(&:klass) - client_before).each { |k| config.client_middleware.remove(k) }
    (config.server_middleware.entries.map(&:klass) - server_before).each { |k| config.server_middleware.remove(k) }
    Wurk::Unique.disable! unless was_unique
  end
end

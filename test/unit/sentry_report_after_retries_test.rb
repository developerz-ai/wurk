# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/fake_sentry'
require 'securerandom'
require 'wurk/sentry'

# The contract an app gets from sentry-sidekiq with
# `config.sidekiq.report_after_job_retries = true` plus a death handler for jobs
# a `sidekiq_retry_in` kills early, through the real pieces: the installed
# server middleware inside JobRetry#local, and the death handlers JobRetry runs.
# One Sentry event per job, on its last attempt or its early death; none for a
# shutdown.
class SentryReportAfterRetriesTest < Wurk::Test::UnitCase
  include SentryConstantSwap

  parallelize_me!

  class Boom < StandardError; end

  class RetriedJob
    include Wurk::Worker

    sidekiq_options retry: 2
  end

  class KilledEarlyJob
    include Wurk::Worker

    sidekiq_options retry: 5
    sidekiq_retry_in { :kill }
  end

  class DiscardedEarlyJob
    include Wurk::Worker

    sidekiq_options retry: 5
    sidekiq_retry_in { :discard }
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    Wurk::Sentry.install!(@config)
    @retrier = Wurk::JobRetry.new(@config)
    @queue = "sentry-retries-#{SecureRandom.hex(4)}"
  end

  def teardown
    Wurk.redis do |c|
      [Wurk::Keys::RETRY, Wurk::Keys::DEAD].each do |key|
        c.call('ZRANGE', key, 0, -1).each { |entry| c.call('ZREM', key, entry) if entry.include?(@queue) }
      end
    end
  ensure
    super
  end

  def test_a_retryable_failure_reports_only_its_last_attempt
    job = payload(RetriedJob)
    attempts = [events_from_attempt(RetriedJob, job), events_from_attempt(RetriedJob, job.merge('retry_count' => 0)),
                events_from_attempt(RetriedJob, job.merge('retry_count' => 1))]

    assert_equal [0, 0, 1], attempts
  end

  def test_a_kill_from_sidekiq_retry_in_reports_once_on_the_first_attempt
    assert_equal 1, events_from_attempt(KilledEarlyJob, payload(KilledEarlyJob))
    assert_equal({ wurk_context: 'dead' }, FakeSentry.captured.last[:options][:tags])
  end

  def test_a_discard_from_sidekiq_retry_in_reports_once
    assert_equal 1, events_from_attempt(DiscardedEarlyJob, payload(DiscardedEarlyJob))
  end

  def test_a_shutdown_never_reports
    assert_raises(Wurk::Shutdown) do
      @retrier.local(RetriedJob.new, Wurk.dump_json(payload(RetriedJob)), @queue) do
        invoke(RetriedJob, payload(RetriedJob)) { raise Wurk::Shutdown }
      end
    end

    assert_empty FakeSentry.captured
  end

  private

  def payload(klass)
    { 'class' => klass.name, 'args' => [], 'queue' => @queue, 'jid' => SecureRandom.hex(12),
      'retry' => klass.get_sidekiq_options['retry'], 'created_at' => ::Time.now.to_f }
  end

  # One attempt that raises; the number of Sentry events it produced.
  def events_from_attempt(klass, job)
    before = FakeSentry.captured.size
    assert_raises(Wurk::JobRetry::Handled) do
      @retrier.local(klass.new, Wurk.dump_json(job), @queue) { invoke(klass, job) { raise Boom, 'failed' } }
    end
    FakeSentry.captured.size - before
  end

  def invoke(klass, job, &)
    @config.server_middleware.invoke(klass.new, job, @queue, &)
  end
end

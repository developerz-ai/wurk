# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Parity oracle: a job's own exception reaches `config.error_handlers`.
#
# Spec: docs/target/sidekiq-free.md §4.2 (`error_handlers` — callables taking
# `[ex, ctx, cfg]`), §14 (Processor#process: `Skip`/`Handled` are acked) and
# §17 (JobRetry#local books the retry and raises `Handled`). Sidekiq's
# processor treats `Handled` as "the failure has been dealt with by the retry
# subsystem but still needs to be logged and dispatched to error_handlers":
# it unwraps the job's exception (the `Handled` cause) and calls every handler
# once with `context: "Job raised exception"` and the job hash. `Skip` means
# the outcome was booked elsewhere and is not reported. This is the contract
# every error reporter wired through `error_handlers` (Honeybadger, Rollbar,
# Bugsnag, Airbrake, AppSignal, a custom notifier) depends on.
class ErrorHandlersParityTest < Wurk::Test::UnitCase
  parallelize_me!

  class ParityError < StandardError; end

  def setup
    super
    @queue_name = "ehp-#{Process.pid}-#{SecureRandom.hex(4)}"
    @config = Sidekiq::Config.new
    @config.logger = ::Logger.new(IO::NULL)
    @calls = []
    @config.error_handlers.replace([->(ex, ctx, cfg) { @calls << [ex, ctx, cfg] }])
    @capsule = Sidekiq::Capsule.new('parity', @config)
    @capsule.queues = [@queue_name]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
    @jids = []
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
    @capsule.redis_pool.with do |c|
      c.call('DEL', "queue:#{@queue_name}", Sidekiq::BasicFetch.private_queue_name("queue:#{@queue_name}"))
      %w[retry dead].each do |set|
        c.call('ZRANGE', set, 0, -1).each { |raw| c.call('ZREM', set, raw) if @jids.any? { |j| raw.include?(j) } }
      end
    end
  ensure
    super
  end

  def test_a_failing_job_calls_each_handler_once
    second = []
    @config.error_handlers << ->(ex, ctx, _cfg) { second << [ex, ctx] }
    run_job(failing_worker, 'retry' => true)

    assert_equal 1, @calls.size
    assert_equal 1, second.size
  end

  def test_the_handler_receives_the_jobs_own_exception
    run_job(failing_worker, 'retry' => true)
    ex, = @calls.first

    assert_instance_of ParityError, ex
    assert_equal 'parity failure', ex.message
  end

  def test_the_context_names_the_job_failure_and_carries_the_job
    jid = run_job(failing_worker, 'retry' => true)
    _, ctx, = @calls.first

    assert_equal 'Job raised exception', ctx[:context]
    assert_equal jid, ctx[:job]['jid']
    assert_equal @queue_name, ctx[:job]['queue']
  end

  def test_the_handler_receives_the_configuration
    run_job(failing_worker, 'retry' => true)

    assert_same @config, @calls.first[2]
  end

  def test_a_job_without_retries_is_reported_once
    run_job(failing_worker, 'retry' => false)

    assert_equal 1, @calls.size
    assert_instance_of ParityError, @calls.first[0]
  end

  def test_an_exhausted_job_is_reported_once
    run_job(failing_worker, 'retry' => 1, 'retry_count' => 0)

    assert_equal 1, @calls.size
  end

  def test_a_successful_job_reports_nothing
    run_job(worker { |*| nil })

    assert_empty @calls
  end

  def test_a_skip_reports_nothing
    run_job(worker { |*| raise Sidekiq::JobRetry::Skip })

    assert_empty @calls
  end

  def test_a_raising_handler_does_not_stop_the_next
    @config.error_handlers.unshift(->(*) { raise 'handler bug' })
    run_job(failing_worker, 'retry' => true)

    assert_equal 1, @calls.size
  end

  private

  def failing_worker = worker { |*| raise ParityError, 'parity failure' }

  def worker(&perform)
    klass = Class.new do
      include Sidekiq::Job

      define_method(:perform, &perform)
    end
    Object.const_set("EHP_Worker_#{Process.pid}_#{SecureRandom.hex(6)}", klass)
  end

  def run_job(klass, extra = {})
    jid = SecureRandom.hex(12)
    @jids << jid
    payload = { 'class' => klass.name, 'args' => [], 'queue' => @queue_name, 'jid' => jid }.merge(extra)
    @capsule.redis_pool.with { |c| c.call('LPUSH', "queue:#{@queue_name}", Sidekiq.dump_json(payload)) }
    @processor.process_one
    jid
  end
end

# frozen_string_literal: true

require_relative '../test_helper'
require 'active_support'
require 'active_support/reloader'
require 'securerandom'

# Parity oracle: what a `Rails.error` subscriber (sentry-rails with
# `register_error_subscriber`, a hand-rolled one) receives from a failing job.
#
# Upstream's processor (sidekiq-8.1.6 lib/sidekiq/processor.rb `dispatch`) runs
# the class lookup, `new`, `JobRetry#local`, the server middleware and `perform`
# inside `config[:reloader]`, which under Rails is
# `app.reloader.wrap(source: "job.sidekiq")` (lib/sidekiq/rails.rb). Rails'
# ExecutionWrapper.wrap reports whatever escapes that block to the error
# reporter, `handled: false`, and re-raises. So, on EVERY attempt, not only the
# terminal one:
#   * a job that raises → `JobRetry::Handled` (raised by `local` after it booked
#     the retry; its cause is the job's exception);
#   * a class that will not load → the NameError itself (it is raised before
#     `local`, so `global` books the retry outside the reloader);
#   * `JobRetry::Skip` → the Skip.
# `config.error_handlers` sees the job's own exception for the first two and
# nothing for Skip (error_handlers_test.rb). Observed against stock Sidekiq
# 8.1.6 + Rails 8.1.4.1 before this file was written; the reloader below is
# upstream's Sidekiq::Rails::Reloader#call with the application factored out.
class RailsErrorReportingParityTest < Wurk::Test::UnitCase
  parallelize_me!

  SOURCE = 'job.sidekiq'

  class ParityError < StandardError; end

  class Subscriber
    attr_reader :reports

    def initialize = @reports = []

    def report(error, handled:, source: nil, **)
      @reports << { error: error, handled: handled, source: source }
    end
  end

  def setup
    super
    @queue_name = "rerp-#{Process.pid}-#{SecureRandom.hex(4)}"
    @config = Sidekiq::Config.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:reloader] = ->(&job) { ActiveSupport::Reloader.wrap(source: SOURCE, &job) }
    @handled = []
    @config.error_handlers.replace([->(ex, ctx, _cfg) { @handled << [ex, ctx[:context]] }])
    @capsule = Sidekiq::Capsule.new('parity', @config)
    @capsule.queues = [@queue_name]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
    @subscriber = Subscriber.new
    ActiveSupport.error_reporter.subscribe(@subscriber)
    @classes = []
  end

  def teardown
    ActiveSupport.error_reporter.unsubscribe(@subscriber)
    @classes.each { |name| Object.send(:remove_const, name) }
    @capsule.fetcher.flush_pending_acks
  ensure
    super
  end

  def test_a_failing_job_reports_handled_with_the_jobs_exception_as_its_cause
    run_job(failing_worker, 'retry' => 3)

    assert_equal 1, @subscriber.reports.size
    report = @subscriber.reports.first

    assert_instance_of Sidekiq::JobRetry::Handled, report[:error]
    assert_instance_of ParityError, report[:error].cause
    assert_equal({ handled: false, source: SOURCE }, report.slice(:handled, :source))
  end

  # Not terminal-only: every attempt that crosses the reloader is reported.
  def test_each_attempt_is_reported_not_only_the_last
    klass = failing_worker
    [nil, 0, 1].each { |count| run_job(klass, 'retry' => 3, 'retry_count' => count) }

    assert_equal 3, @subscriber.reports.size
    assert(@subscriber.reports.all? { |r| r[:error].is_a?(Sidekiq::JobRetry::Handled) })
  end

  def test_a_class_that_will_not_load_reports_the_name_error_each_attempt
    [nil, 0].each { |count| run_job_named('RERP::Missing::Klass', 'retry' => 3, 'retry_count' => count) }

    assert_equal 2, @subscriber.reports.size
    assert(@subscriber.reports.all? { |r| r[:error].instance_of?(NameError) && r[:source] == SOURCE })
    assert_equal([NameError, NameError], @handled.map { |ex, _| ex.class })
  end

  def test_a_skip_reaches_the_reporter_but_not_the_error_handlers
    run_job(worker { |*| raise Sidekiq::JobRetry::Skip })

    assert_equal([Sidekiq::JobRetry::Skip], @subscriber.reports.map { |r| r[:error].class })
    assert_empty @handled
  end

  def test_the_error_handlers_still_get_the_jobs_own_exception
    run_job(failing_worker, 'retry' => 3)

    assert_equal([[ParityError, 'Job raised exception']], @handled.map { |ex, ctx| [ex.class, ctx] })
  end

  def test_a_successful_job_reports_nothing
    run_job(worker { |*| nil })

    assert_empty @subscriber.reports
  end

  private

  def failing_worker = worker { |*| raise ParityError, 'parity failure' }

  def worker(&perform)
    klass = Class.new do
      include Sidekiq::Job

      define_method(:perform, &perform)
    end
    name = "RERP_Worker_#{Process.pid}_#{SecureRandom.hex(6)}"
    @classes << name
    Object.const_set(name, klass)
  end

  def run_job(klass, extra = {}) = run_job_named(klass.name, extra)

  # On its own thread: Rails' wrap reports nothing when an executor is already
  # active on the calling thread.
  def run_job_named(class_name, extra)
    payload = { 'class' => class_name, 'args' => [], 'queue' => @queue_name,
                'jid' => SecureRandom.hex(12) }.merge(extra).compact
    @capsule.redis_pool.with { |c| c.call('LPUSH', "queue:#{@queue_name}", Sidekiq.dump_json(payload)) }
    Thread.new { @processor.process_one }.join
  end
end

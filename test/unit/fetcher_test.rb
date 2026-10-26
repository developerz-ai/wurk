# frozen_string_literal: true

require_relative '../test_helper'

# The abstract Wurk::Fetcher base class defines the drop-in fetcher contract
# (retrieve_work / bulk_requeue / terminate / flush_pending_acks). Retrieval is
# required: an un-overridden retrieve_work returning instant nil would spin
# Processor#run's process_one loop, so the base raises NotImplementedError and
# concrete fetchers must block or back off when empty. The lifecycle hooks stay
# callable no-ops a custom config[:fetch_class] inherits, so Manager and
# Processor can call them without raising; requeue and recovery policy belong
# to the subclass.
class FetcherTest < Wurk::Test::UnitCase
  parallelize_me!

  class PrivateInflightFetcher < Wurk::Fetcher
    attr_reader :pending, :in_flight

    def initialize(job)
      super()
      @pending = [job]
      @in_flight = []
    end

    def retrieve_work
      job = @pending.shift
      @in_flight << job if job
      job
    end
  end

  def setup
    super
    @fetcher = Wurk::Fetcher.new
  end

  class DelegatingFetcher < Wurk::Fetcher
    attr_reader :calls

    def initialize
      super
      @calls = 0
    end

    def retrieve_work
      @calls += 1
      # Bound the old instant-nil loop without threads, timers, or a fetch retry.
      raise ScriptError, 'Processor repeated unimplemented retrieval' if @calls > 1

      super
    end
  end

  def test_base_retrieval_requires_an_override
    error = assert_raises(NotImplementedError) { @fetcher.retrieve_work }

    assert_match(/override #retrieve_work/, error.message)
    assert_match(/block or back off/, error.message)
  end

  def test_inherited_retrieval_requires_an_override
    fetcher = Class.new(Wurk::Fetcher).new

    error = assert_raises(NotImplementedError) { fetcher.retrieve_work }

    assert_match(/override #retrieve_work/, error.message)
  end

  def test_custom_retrieval_preserves_results_and_inherits_optional_hooks
    work = Object.new
    fetcher = Class.new(Wurk::Fetcher) do
      attr_accessor :result

      def retrieve_work
        result
      end
    end.new
    fetcher.result = work

    assert_same work, fetcher.retrieve_work
    fetcher.result = nil

    assert_nil fetcher.retrieve_work
    assert_nil fetcher.bulk_requeue([work])
    assert_nil fetcher.terminate
    assert_nil fetcher.flush_pending_acks
  end

  def test_processor_reports_and_propagates_unimplemented_retrieval_without_looping
    errors = []
    callbacks = []
    config = Wurk::Configuration.new
    config.logger = Logger.new(IO::NULL)
    config.error_handlers.replace([->(error, context, _config) { errors << [error, context] }])
    capsule = Wurk::Capsule.new('unimplemented-fetcher', config)
    capsule.fetcher = DelegatingFetcher.new
    processor = Wurk::Processor.new(capsule) { |stopped| callbacks << stopped }

    error = assert_raises(NotImplementedError) { processor.send(:run) }

    assert_match(/override #retrieve_work/, error.message)
    assert_equal 1, capsule.fetcher.calls
    assert_equal [[error, { context: '!shutdown' }]], errors
    assert_equal [processor], callbacks
  end

  def test_bulk_requeue_defaults_to_noop
    assert_nil @fetcher.bulk_requeue([:anything])
  end

  def test_expired_manager_stop_can_call_inherited_noop_without_recovering_private_work
    job = { 'jid' => 'custom-in-flight' }
    fetcher = PrivateInflightFetcher.new(job)
    config = Wurk::Configuration.new
    config.logger = Logger.new(IO::NULL)
    capsule = Wurk::Capsule.new('custom-fetcher', config)
    capsule.concurrency = 1
    capsule.fetcher = fetcher
    manager = Wurk::Manager.new(capsule)
    worker = manager.workers.first
    in_progress = fetcher.retrieve_work

    # Deterministic stand-in: quiet must leave the worker alive until hard kill.
    killed = false
    thread = Object.new
    thread.define_singleton_method(:alive?) { !killed }
    worker.define_singleton_method(:thread) { thread }
    worker.define_singleton_method(:job) { in_progress }
    worker.define_singleton_method(:kill) { killed = true }

    assert_same job, in_progress
    assert_same Wurk::Fetcher, fetcher.method(:bulk_requeue).owner
    assert_predicate thread, :alive?

    manager.stop(Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)

    # Custom fetchers own recovery; this in-memory private state is not durable
    # across process exit, unlike Reliable's Redis-backed private lists.
    assert_equal 1, fetcher.in_flight.size
    assert_same job, fetcher.in_flight.first
    assert_empty fetcher.pending, 'inherited bulk_requeue must not return private work to the public queue'
    assert killed, 'expired drain must reach the real hard_shutdown and kill the worker'
    refute_predicate thread, :alive?
  end

  def test_terminate_defaults_to_noop
    # Quiet hook: a subclass without its own terminate must not raise when quieted.
    assert_nil @fetcher.terminate
  end

  def test_flush_pending_acks_defaults_to_noop
    # Only Reliable defers its ACK; a subclass that ACKs inline has nothing to send.
    assert_nil @fetcher.flush_pending_acks
  end
end

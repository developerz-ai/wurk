# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/telemetry'
require 'logger'

# Wurk::Telemetry::ServerMiddleware — the consumer half of the Redis hop.
#
# opentelemetry-api is deliberately not a dependency (see wurk.gemspec), so the
# slice of it this middleware touches is stood up below as a *behavioral* fake
# modelled on opentelemetry-api 1.8: `with_span` returns the block's value and
# restores the previously-active span, `current_span` falls back to an invalid
# span when the context holds none, `start_span` parents to whatever context it
# is handed while `start_root_span` detaches, and a SpanContext is `valid?` only
# with both ids set. A fake more permissive than the gem would make every
# assertion here worthless.
#
# Takes GLOBAL_STATE_MUTEX for the whole class: `::OpenTelemetry` is a process
# constant, and TelemetryTest / TelemetryClientMiddlewareTest install and remove
# it too.
class TelemetryServerMiddlewareTest < Wurk::Test::UnitCase
  parallelize_me!

  TRACE_ID = 'd4cda95b652f4a1592b449d5929fda1b'
  SPAN_ID  = '00f067aa0ba902b7'
  JID      = 'aaaabbbbccccddddeeeeffff'

  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  def setup
    super
    @queue      = "ts-q-#{Process.pid}-#{object_id}"
    @class_name = "TelemetryJob@#{Process.pid}-#{object_id}"
  end

  # --- span shape ----------------------------------------------------------

  def test_consumer_span_is_named_for_the_job_class
    with_otel { perform(job) }

    assert_equal "#{@class_name} process", span.name
  end

  # An ActiveJob payload's `class` is the adapter's wrapper; without `wrapped`
  # every AJ span in the system would read as that one class.
  def test_consumer_span_is_named_for_the_wrapped_class_under_activejob
    with_otel { perform(job('wrapped' => 'SomeMailerJob')) }

    assert_equal 'SomeMailerJob process', span.name
  end

  def test_consumer_span_kind_is_consumer
    with_otel { perform(job) }

    assert_equal :consumer, span.kind
  end

  def test_consumer_span_carries_the_messaging_conventions
    with_otel { perform(job) }

    assert_equal({ 'messaging.system' => 'wurk',
                   'messaging.destination.name' => @queue,
                   'messaging.message.id' => JID,
                   'messaging.wurk.job_class' => @class_name },
                 span.attributes)
  end

  # The queue the job was consumed from, not the one the payload claims — a
  # re-pushed or re-routed job is reported where it actually ran.
  def test_the_destination_is_the_queue_the_job_was_fetched_from
    with_otel { perform(job('queue' => 'stale-name')) }

    assert_equal @queue, span.attributes['messaging.destination.name']
  end

  def test_the_tracer_is_scoped_to_this_gem
    with_otel { perform(job) }

    assert_equal ['wurk', Wurk::VERSION], [tracer.name, tracer.version]
  end

  # --- the producer relationship -------------------------------------------

  def test_a_fresh_job_is_a_child_of_the_producer_span
    with_otel { perform(traced_job) }

    assert_equal [TRACE_ID, SPAN_ID], [parent_context.trace_id, parent_context.span_id]
  end

  # Redundant with the parent edge, and an empty array is not the API's "none".
  def test_a_child_span_carries_no_link
    with_otel { perform(traced_job) }

    assert_nil span.links
  end

  # A job scheduled hours out has a long-dead producer span: parenting to it
  # would stretch one trace across the delay.
  def test_a_job_older_than_the_parent_window_links_instead_of_parenting
    with_otel { perform(traced_job('created_at' => millis_ago(3600))) }

    assert_equal :root, span.parent
    assert_equal [TRACE_ID, SPAN_ID], link_target(span)
  end

  # The window is the whole of the decision: same context, same job, one second
  # either side of PARENT_WINDOW_SECONDS.
  def test_the_window_is_what_decides_parent_versus_link
    inside  = with_otel { perform(traced_job('created_at' => millis_ago(59))) } && span.parent
    outside = with_otel { perform(traced_job('created_at' => millis_ago(61))) } && span.parent

    assert_equal [FakeOtel::Trace::Context, :root], [inside.class, outside]
  end

  # The other `created_at` shape a drop-in has to read: Sidekiq <= 7.x wrote a
  # Float of epoch seconds, and those payloads survive the upgrade in the retry
  # and scheduled sets. Divided by 1000 they date to 1970, so a millis-only read
  # links every one of them — including the ones enqueued a second ago.
  def test_the_window_decides_on_a_seconds_shaped_created_at_too
    inside  = with_otel { perform(traced_job('created_at' => seconds_ago(1))) } && span.parent
    outside = with_otel { perform(traced_job('created_at' => seconds_ago(3600))) } && span.parent

    assert_equal [FakeOtel::Trace::Context, :root], [inside.class, outside]
  end

  def test_a_seconds_shaped_child_points_at_the_producer
    with_otel { perform(traced_job('created_at' => seconds_ago(1))) }

    assert_equal [TRACE_ID, SPAN_ID], [parent_context.trace_id, parent_context.span_id]
  end

  # Conservative on an unknown age: a link where a parent belonged costs one hop
  # in the UI; a parent where a link belonged can lose the trace outright.
  def test_a_job_with_no_created_at_links_instead_of_parenting
    with_otel { perform(traced_job.tap { |j| j.delete('created_at') }) }

    assert_equal :root, span.parent
    assert_equal [TRACE_ID, SPAN_ID], link_target(span)
  end

  # The drop-in direction: a job enqueued by stock Sidekiq, or by a Wurk process
  # with tracing off, still gets a span — it simply has nothing to point at.
  def test_a_job_with_no_trace_context_is_a_root_span_with_no_link
    with_otel { perform(job) }

    assert_equal :root, span.parent
    assert_nil span.links
  end

  def test_a_malformed_trace_context_is_treated_as_absent
    with_otel { perform(job('traceparent' => 'not-a-traceparent')) }

    assert_equal :root, span.parent
    assert_nil span.links
  end

  # JobRetry#schedule_retry re-ZADDs the same hash, so a retry still carries the
  # *original* producer context — every attempt stays reachable from the enqueue
  # that caused it rather than becoming an unrelated root.
  def test_a_retried_job_still_points_at_the_original_trace
    with_otel { perform(traced_job('retry_count' => 4, 'created_at' => millis_ago(900))) }

    assert_equal [TRACE_ID, SPAN_ID], link_target(span)
  end

  # --- the chain contract --------------------------------------------------

  def test_the_chains_return_value_survives_the_span
    with_otel { assert_equal :the_result, perform(job) { :the_result } }
  end

  def test_the_job_body_runs_inside_the_consumer_span
    active = nil
    with_otel { perform(job) { active = FakeOtel::Trace.current } }

    assert_same span, active
  end

  def test_the_previously_active_span_is_restored
    with_otel { perform(job) }

    assert_nil FakeOtel::Trace.current
  end

  def test_a_successful_job_finishes_its_span_exactly_once
    with_otel { perform(job) }

    assert_equal 1, span.finishes
  end

  def test_a_successful_job_leaves_the_span_status_unset
    with_otel { perform(job) }

    assert_nil span.status
  end

  # Tracing that fails while opening the span surfaces loudly rather than
  # silently turning itself off — and neither the rescue nor the ensure may trip
  # over the span they never got.
  def test_a_failure_opening_the_span_propagates_without_a_second_error
    with_otel do
      FakeOtel.propagation = ExplodingPropagator.new

      assert_raises(ExplodingPropagator::Boom) { perform(job) }
      assert_empty tracer.spans
    end
  end

  # --- the error taxonomy --------------------------------------------------
  #
  # The canonical not-an-error list (Batch::ServerMiddleware): each of these is
  # a job that was put back and will run again, not one that went wrong.

  NOT_ERRORS = {
    cooperative_interruption: Wurk::Job::Interrupted,
    interrupt_handler_skip: Wurk::JobRetry::Skip,
    limiter_reschedule: Wurk::Limiter::Rescheduled,
    handled_retry: Wurk::JobRetry::Handled
  }.freeze

  NOT_ERRORS.each do |label, error|
    define_method(:"test_a_#{label}_is_not_a_span_error") do
      with_otel { assert_raises(error) { perform(job) { raise error } } }

      assert_nil span.status, "#{label} must not set an error status"
      assert_empty span.exceptions, "#{label} must not be recorded as an exception"
    end

    define_method(:"test_a_#{label}_still_finishes_the_span") do
      with_otel { assert_raises(error) { perform(job) { raise error } } }

      assert_equal 1, span.finishes
    end
  end

  def test_a_failing_job_records_the_exception_and_an_error_status
    boom = ArgumentError.new('boom')

    with_otel { assert_raises(ArgumentError) { perform(job) { raise boom } } }

    assert_equal [boom], span.exceptions
    assert_equal 'Unhandled exception of type: ArgumentError', span.status.description
  end

  def test_a_failing_job_finishes_its_span
    with_otel { assert_raises(ArgumentError) { perform(job) { raise ArgumentError } } }

    assert_equal 1, span.finishes
  end

  def test_a_failing_job_re_raises_untouched
    with_otel do
      raised = assert_raises(ArgumentError) { perform(job) { raise ArgumentError, 'boom' } }

      assert_equal 'boom', raised.message
    end
  end

  # `Wurk::Shutdown` is an Interrupt, not a StandardError: a job killed by a
  # hard shutdown did not complete, and that is the signal an operator tuning
  # `shutdown_timeout` is looking for.
  def test_a_hard_shutdown_is_recorded_as_an_error
    with_otel { assert_raises(Wurk::Shutdown) { perform(job) { raise Wurk::Shutdown } } }

    assert_equal 'Unhandled exception of type: Wurk::Shutdown', span.status.description
    assert_equal 1, span.finishes
  end

  # --- registration --------------------------------------------------------

  def test_opting_in_registers_one_position_inside_the_interrupt_handler
    with_otel do
      config = booted_config
      config.telemetry = true

      assert_equal [Wurk::Middleware::InterruptHandler, Wurk::Telemetry::ServerMiddleware, Wurk::Metrics::History],
                   config.server_middleware.entries.map(&:klass)
    end
  end

  # A chain with no interrupt handler to stay inside of — a client-only capsule,
  # a hand-built chain — takes the head. `insert_after`'s own miss behaviour is
  # the tail, which is the innermost position and the opposite of the intent.
  def test_opting_in_takes_the_head_when_there_is_no_interrupt_handler
    with_otel do
      config = silent_config
      config.server_middleware.add(Wurk::Metrics::History)
      config.telemetry = true

      assert_equal [Wurk::Telemetry::ServerMiddleware, Wurk::Metrics::History],
                   config.server_middleware.entries.map(&:klass)
    end
  end

  def test_opting_back_out_unregisters_the_server_middleware
    with_otel do
      config = booted_config
      config.telemetry = true
      config.telemetry = false

      refute config.server_middleware.exists?(Wurk::Telemetry::ServerMiddleware)
    end
  end

  def test_nothing_registers_without_the_gem
    config = booted_config
    config.telemetry = true

    refute config.server_middleware.exists?(Wurk::Telemetry::ServerMiddleware)
  end

  def test_nothing_registers_without_the_opt_in
    with_otel do
      config = booted_config
      Wurk::Telemetry.install!(config)

      refute config.server_middleware.exists?(Wurk::Telemetry::ServerMiddleware)
    end
  end

  def test_opting_in_twice_registers_one_entry
    with_otel do
      config = booted_config
      2.times { config.telemetry = true }

      assert_equal 1, config.server_middleware.entries.map(&:klass).count(Wurk::Telemetry::ServerMiddleware)
    end
  end

  private

  # --- fixtures ------------------------------------------------------------

  def job(overrides = {})
    { 'class' => @class_name, 'args' => [1, 'two'], 'queue' => @queue,
      'jid' => JID, 'created_at' => millis_ago(0) }.merge(overrides)
  end

  def traced_job(overrides = {})
    job({ 'traceparent' => "00-#{TRACE_ID}-#{SPAN_ID}-01" }.merge(overrides))
  end

  def millis_ago(seconds)
    ((Process.clock_gettime(Process::CLOCK_REALTIME) - seconds) * 1000).to_i
  end

  # Float epoch seconds — what Sidekiq <= 7.x stamped, and still the shape of
  # anything it left behind in a sorted set.
  def seconds_ago(seconds) = Process.clock_gettime(Process::CLOCK_REALTIME) - seconds

  # Through a real Chain so entry construction and config binding are exercised
  # the way the Processor exercises them.
  def perform(job, &block)
    block ||= -> { :ok }
    chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    chain.add(Wurk::Telemetry::ServerMiddleware)
    chain.invoke(nil, job, @queue, &block)
  end

  def silent_config
    Wurk::Configuration.new.tap { |c| c.logger = ::Logger.new(IO::NULL) }
  end

  # A config shaped like a booted process: InterruptHandler at the head (it
  # prepends itself when wurk.rb loads) with a built-in behind it.
  def booted_config
    silent_config.tap do |c|
      c.server_middleware.prepend(Wurk::Middleware::InterruptHandler)
      c.server_middleware.add(Wurk::Metrics::History)
    end
  end

  # --- span accessors ------------------------------------------------------

  def tracer = FakeOtel.tracer_provider.tracer('wurk', Wurk::VERSION)
  def span   = tracer.spans.fetch(0)

  def parent_context = FakeOtel::Trace.current_span(span.parent).context

  def link_target(span)
    context = span.links.fetch(0).span_context
    [context.trace_id, context.span_id]
  end

  # --- the opentelemetry-api stand-in --------------------------------------

  def with_otel
    FakeOtel.tracer_provider = FakeTracerProvider.new
    FakeOtel.propagation     = FakePropagator.new
    FakeOtel::Trace.current  = nil
    Object.const_set(:OpenTelemetry, FakeOtel)
    yield
  ensure
    Object.send(:remove_const, :OpenTelemetry)
  end

  module FakeOtel
    class << self
      attr_accessor :tracer_provider, :propagation
    end

    module Trace
      SpanContext = Struct.new(:trace_id, :span_id) do
        def valid? = !(trace_id.nil? || span_id.nil?)
      end

      INVALID_CONTEXT = SpanContext.new(nil, nil).freeze

      Link = Struct.new(:span_context)

      module Status
        Error = Struct.new(:description)

        def self.error(description) = Error.new(description)
      end

      class Span
        attr_reader :name, :attributes, :kind, :links, :parent, :context, :exceptions, :finishes
        attr_accessor :status

        def initialize(name: nil, attributes: nil, kind: nil, links: nil, parent: nil, context: INVALID_CONTEXT)
          @name = name
          @attributes = attributes
          @kind = kind
          @links = links
          @parent = parent
          @context = context
          @status = nil
          @exceptions = []
          @finishes = 0
        end

        def record_exception(exception) = @exceptions << exception
        def finish = @finishes += 1
      end

      INVALID = Span.new.freeze

      # A Context is opaque to the middleware; all it ever does is hand one back
      # to `current_span`. Modelling it as "the span the propagator extracted"
      # is the whole of the surface under test.
      Context = Struct.new(:span)

      class << self
        attr_accessor :current

        def current_span(context = nil)
          context.respond_to?(:span) && context.span ? context.span : INVALID
        end

        # Returns the block's value and restores the previously-active span,
        # like Context.with_value's attach/detach pair.
        def with_span(span)
          previous = @current
          @current = span
          yield span
        ensure
          @current = previous
        end
      end
    end
  end

  # TraceContext::TextMapPropagator#extract: a context holding the remote span
  # when the header parses, and one holding nothing when it does not — which is
  # what makes an absent or malformed `traceparent` resolve to Span::INVALID.
  class FakePropagator
    FORMAT = /\A00-(?<trace_id>\h{32})-(?<span_id>\h{16})-\h{2}\z/

    def extract(carrier)
      match = FORMAT.match(carrier['traceparent'].to_s)
      return FakeOtel::Trace::Context.new(nil) unless match

      context = FakeOtel::Trace::SpanContext.new(match[:trace_id], match[:span_id])
      FakeOtel::Trace::Context.new(FakeOtel::Trace::Span.new(context: context))
    end
  end

  class ExplodingPropagator
    class Boom < StandardError; end

    def extract(_carrier) = raise(Boom)
  end

  class FakeTracer
    attr_reader :name, :version, :spans

    def initialize(name, version)
      @name    = name
      @version = version
      @spans   = []
    end

    def start_span(name, with_parent: nil, attributes: nil, links: nil, kind: nil)
      record(name, attributes, links, kind, with_parent)
    end

    # The SDK's start_root_span is start_span with an empty parent context —
    # `:root` here so a test can tell "detached" from "parented" at a glance.
    def start_root_span(name, attributes: nil, links: nil, kind: nil)
      record(name, attributes, links, kind, :root)
    end

    private

    def record(name, attributes, links, kind, parent)
      span = FakeOtel::Trace::Span.new(
        name: name, attributes: attributes, links: links, kind: kind, parent: parent,
        context: FakeOtel::Trace::SpanContext.new('0' * 32, format('%016x', @spans.size + 1))
      )
      @spans << span
      span
    end
  end

  # Memoizes per (name, version) like OpenTelemetry::SDK::Trace::TracerProvider.
  class FakeTracerProvider
    def initialize = @tracers = {}

    def tracer(name, version) = @tracers[[name, version]] ||= FakeTracer.new(name, version)
  end
end

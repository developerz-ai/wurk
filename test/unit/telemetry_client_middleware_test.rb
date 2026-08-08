# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/telemetry'
require 'json'
require 'logger'

# Wurk::Telemetry::ClientMiddleware — the producer half of the Redis hop.
#
# opentelemetry-api is deliberately not a dependency (see wurk.gemspec), so the
# slice of it this middleware touches is stood up below as a *behavioral* fake:
# `in_span` returns the block's value and lets exceptions through like the real
# Tracer, and `inject` writes only while a span is open, and only the keys the
# W3C propagator writes (`tracestate` solely when the trace carries vendor
# state). A fake more permissive than the gem would make every assertion here
# worthless.
#
# Takes GLOBAL_STATE_MUTEX for the whole class: `::OpenTelemetry` is a process
# constant, and TelemetryTest installs and removes it too.
class TelemetryClientMiddlewareTest < Wurk::Test::UnitCase
  parallelize_me!

  TRACE_ID = 'd4cda95b652f4a1592b449d5929fda1b'
  JID      = 'aaaabbbbccccddddeeeeffff'
  CREATED  = 1_700_000_000_000

  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  def setup
    super
    @pool       = Wurk.configuration.redis_pool
    @queue      = "tc-q-#{Process.pid}-#{object_id}"
    @class_name = "TelemetryJob@#{Process.pid}-#{object_id}"
    @bid        = "TC-#{Process.pid}-#{object_id}"
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}", "b-#{@bid}", "b-#{@bid}-jids")
      conn.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  # --- injection -----------------------------------------------------------

  def test_push_injects_the_producer_spans_trace_context
    with_otel do |provider|
      client = recording_client
      client.push(item)

      assert_equal "00-#{TRACE_ID}-#{span(provider).span_id}-01", client.pushed.first['traceparent']
    end
  end

  def test_push_omits_tracestate_when_the_trace_carries_none
    with_otel do
      client = recording_client
      client.push(item)

      refute client.pushed.first.key?('tracestate'), 'an empty tracestate must not reach the wire'
    end
  end

  def test_push_injects_tracestate_when_the_trace_carries_vendor_state
    with_otel(tracestate: 'rojo=00f067aa0ba902b7') do
      client = recording_client
      client.push(item)

      assert_equal 'rojo=00f067aa0ba902b7', client.pushed.first['tracestate']
    end
  end

  # The chain runs per item in the bulk path (Client#build_bulk_payloads), so
  # each job carries the context of its own producer span — not one context
  # smeared across the slice.
  def test_push_bulk_injects_a_distinct_context_into_every_item
    with_otel do |provider|
      client = recording_client
      client.push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[1], [2], [3]])

      traceparents = client.pushed.map { |p| p['traceparent'] }

      assert_equal 3, traceparents.compact.uniq.size
      assert_equal 3, spans(provider).size
    end
  end

  # --- the byte-compare proof ---------------------------------------------
  #
  # Every case below drives the real registration gate (Configuration#telemetry=
  # → Telemetry.install!) rather than hand-building a chain, because "keys only
  # when tracing is enabled" is a claim about that gate, not about the middleware.

  def test_payload_bytes_are_unchanged_when_the_host_never_opted_in
    with_otel do
      assert_equal baseline_json, pushed_json(silent_config)
    end
  end

  # An explicit `= false` on a config that never traced must stay a no-op — it
  # has nothing to unregister, and must not pay the require to find that out.
  def test_opting_out_without_ever_opting_in_registers_nothing
    config = silent_config
    config.telemetry = false

    assert_empty config.client_middleware.entries
    assert_equal baseline_json, pushed_json(config)
  end

  def test_payload_bytes_are_unchanged_when_the_gem_is_missing
    config = silent_config
    config.telemetry = true

    assert_equal baseline_json, pushed_json(config)
  end

  def test_opting_in_adds_the_trace_context_and_nothing_else
    with_otel do
      config = silent_config
      config.telemetry = true
      traced = JSON.parse(pushed_json(config))

      assert_equal ['traceparent'], traced.keys - JSON.parse(baseline_json).keys
      assert_equal baseline_json, Wurk.dump_json(traced.except('traceparent'))
    end
  end

  # Tail, so a middleware that halts the push runs outside the span and nothing
  # downstream can strip the injected key back off.
  def test_opting_in_registers_at_the_tail_of_the_chain
    with_otel do
      config = silent_config
      config.client_middleware.add(HaltingMiddleware)
      config.telemetry = true

      assert_equal [HaltingMiddleware, Wurk::Telemetry::ClientMiddleware],
                   config.client_middleware.entries.map(&:klass)
    end
  end

  def test_opting_back_out_restores_the_untraced_bytes
    with_otel do
      config = silent_config
      config.telemetry = true
      config.telemetry = false

      assert_equal baseline_json, pushed_json(config)
    end
  end

  # --- span shape ----------------------------------------------------------

  def test_producer_span_is_named_for_the_destination
    with_otel do |provider|
      recording_client.push(item)

      assert_equal "#{@queue} publish", span(provider).name
    end
  end

  def test_producer_span_kind_is_producer
    with_otel do |provider|
      recording_client.push(item)

      assert_equal :producer, span(provider).kind
    end
  end

  def test_producer_span_carries_the_messaging_conventions
    with_otel do |provider|
      recording_client.push(item)

      assert_equal({ 'messaging.system' => 'wurk',
                     'messaging.destination.name' => @queue,
                     'messaging.message.id' => JID,
                     'messaging.wurk.job_class' => @class_name },
                   span(provider).attributes)
    end
  end

  # An ActiveJob payload's `class` is the adapter's wrapper; without `wrapped`
  # every AJ span in the system would read as that one class.
  def test_producer_span_reports_the_wrapped_class_for_activejob
    with_otel do |provider|
      recording_client.push(item('wrapped' => 'SomeMailerJob'))

      assert_equal 'SomeMailerJob', span(provider).attributes['messaging.wurk.job_class']
    end
  end

  def test_the_tracer_is_scoped_to_this_gem
    with_otel do |provider|
      recording_client.push(item)

      assert_equal ['wurk', Wurk::VERSION], [tracer(provider).name, tracer(provider).version]
    end
  end

  # --- the chain contract --------------------------------------------------

  def test_the_chains_return_value_survives_the_span
    with_otel do
      assert_equal JID, recording_client.push(item)
    end
  end

  # Tail registration is what buys this: a middleware that drops the job runs
  # outside the span, so nothing reports a publish that never happened.
  def test_a_job_dropped_upstream_opens_no_producer_span
    with_otel do |provider|
      client = recording_client(outer: HaltingMiddleware)

      assert_nil client.push(item)
      assert_empty spans(provider)
      assert_empty client.pushed
    end
  end

  # --- the single args walk (plan 04/S6) -----------------------------------
  #
  # `verify_json` recurses the whole args tree and runs exactly once per job:
  # after the chain in #push, inside it in #push_bulk. Injection adds top-level
  # String keys and never verifies, so the count must not move — and the walk
  # must already be looking at an injected payload, which is what pins the
  # ordering rather than merely the arithmetic.

  def test_push_still_walks_the_args_exactly_once
    with_otel do
      client = recording_client
      client.push(item)

      assert_equal 1, client.verified.size
    end
  end

  def test_push_bulk_still_walks_the_args_exactly_once_per_job
    with_otel do
      client = recording_client
      client.push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[1], [2], [3]])

      assert_equal 3, client.verified.size
    end
  end

  def test_the_walk_sees_the_injected_payload
    with_otel do
      client = recording_client
      client.push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[1]])

      assert client.verified.first.key?('traceparent'), 'injection must precede the bulk walk, not follow it'
    end
  end

  # The bulk walk runs inside the span, so a rejected payload surfaces through
  # `in_span` — which must re-raise, not swallow.
  def test_a_rejected_payload_raises_through_the_span
    with_otel do |provider|
      client = recording_client

      assert_raises(ArgumentError) do
        client.push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[:not_json]])
      end
      assert_equal 1, spans(provider).size
      assert_empty client.pushed
    end
  end

  # --- survival to Redis ---------------------------------------------------

  def test_the_context_survives_a_plain_push_to_redis
    with_otel do
      traced_client.push(item)

      assert_match(/\A00-#{TRACE_ID}-/, stored.first['traceparent'])
    end
  end

  # The batched path serializes inside Lua (BATCH_PUSH), not in Ruby — the
  # injected key has to ride that too.
  def test_the_context_survives_the_lua_batch_path
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
    with_otel do
      traced_client.push(item('bid' => @bid))

      assert_match(/\A00-#{TRACE_ID}-/, stored.first['traceparent'])
    end
  end

  # --- tracer resolution ---------------------------------------------------

  def test_the_tracer_is_resolved_once_per_provider
    with_otel do |provider|
      3.times { recording_client.push(item) }

      assert_equal 1, provider.tracer_calls
    end
  end

  # An SDK installed after the opt-in replaces the provider object; a tracer
  # cached across that swap would export nothing for the rest of the process.
  def test_the_tracer_is_re_resolved_when_the_provider_is_replaced
    with_otel do
      recording_client.push(item)
      swapped = FakeOtel.tracer_provider = FakeTracerProvider.new
      recording_client.push(item)

      assert_equal 1, spans(swapped).size
    end
  end

  private

  # --- fixtures ------------------------------------------------------------

  def item(overrides = {})
    { 'class' => @class_name, 'args' => [1, 'two'], 'queue' => @queue,
      'jid' => JID, 'created_at' => CREATED }.merge(overrides)
  end

  def silent_config
    Wurk::Configuration.new.tap { |c| c.logger = ::Logger.new(IO::NULL) }
  end

  def recording_client(outer: nil)
    chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    chain.add(outer) if outer
    chain.add(Wurk::Telemetry::ClientMiddleware)
    RecordingClient.new(pool: @pool, chain: chain)
  end

  def traced_client
    chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    chain.add(Wurk::Telemetry::ClientMiddleware)
    Wurk::Client.new(pool: @pool, chain: chain)
  end

  # The exact bytes an untraced enqueue writes. Same item, same jid, same
  # created_at, so any difference is the middleware's doing.
  def baseline_json
    @baseline_json ||= Wurk.dump_json(
      RecordingClient.new(pool: @pool, chain: Wurk::Middleware::Chain.new).tap { |c| c.push(item) }.pushed.first
    )
  end

  def pushed_json(config)
    client = RecordingClient.new(pool: @pool, chain: config.client_middleware)
    client.push(item)
    Wurk.dump_json(client.pushed.first)
  end

  def stored
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end

  # --- the opentelemetry-api stand-in --------------------------------------

  def with_otel(tracestate: nil)
    FakeOtel.tracer_provider = FakeTracerProvider.new
    FakeOtel.propagation     = FakePropagator.new(tracestate)
    FakeOtel.current_span    = nil
    Object.const_set(:OpenTelemetry, FakeOtel)
    yield FakeOtel.tracer_provider
  ensure
    Object.send(:remove_const, :OpenTelemetry)
  end

  def tracer(provider) = provider.tracer('wurk', Wurk::VERSION)
  def spans(provider)  = tracer(provider).spans
  def span(provider)   = spans(provider).first

  class FakeTracer
    Span = Struct.new(:name, :attributes, :kind, :span_id)

    attr_reader :name, :version, :spans

    def initialize(name, version)
      @name    = name
      @version = version
      @spans   = []
    end

    # OpenTelemetry::Trace::Tracer#in_span: the block's value is the return
    # value (Client#push threads the payload back through it), and an exception
    # propagates after the span is finished.
    def in_span(name, attributes: nil, kind: nil)
      span = Span.new(name, attributes, kind, format('%016x', @spans.size + 1))
      @spans << span
      previous = FakeOtel.current_span
      FakeOtel.current_span = span
      begin
        yield span
      ensure
        FakeOtel.current_span = previous
      end
    end
  end

  # Memoizes per (name, version) like OpenTelemetry::SDK::Trace::TracerProvider,
  # and counts the lookups so the caller-side memo is observable.
  class FakeTracerProvider
    attr_reader :tracer_calls

    def initialize
      @tracer_calls = 0
      @tracers      = {}
    end

    def tracer(name, version)
      @tracer_calls += 1
      @tracers[[name, version]] ||= FakeTracer.new(name, version)
    end
  end

  # TraceContext::TextMapPropagator#inject: nothing without a valid current
  # span context, `traceparent` always, `tracestate` only when non-empty.
  class FakePropagator
    def initialize(tracestate) = @tracestate = tracestate

    def inject(carrier)
      span = FakeOtel.current_span
      return if span.nil?

      carrier['traceparent'] = "00-#{TRACE_ID}-#{span.span_id}-01"
      carrier['tracestate']  = @tracestate if @tracestate && !@tracestate.empty?
      nil
    end
  end

  module FakeOtel
    class << self
      attr_accessor :current_span, :tracer_provider, :propagation
    end
  end

  # Stands in for a uniqueness/throttling gem dropping the job.
  class HaltingMiddleware
    def call(_worker, _job, _queue, _redis) = nil
  end

  class RecordingClient < Wurk::Client
    attr_reader :pushed, :verified

    def initialize(**)
      super
      @pushed   = []
      @verified = []
    end

    # Snapshots rather than the live Hash: #push_plain_group stamps
    # `enqueued_at` onto the payload it was handed, and a byte-compare against a
    # mutated object would be measuring the clock.
    def verify_json(item)
      @verified << item.dup
      super
    end

    def raw_push(payloads)
      @pushed.concat(payloads.map(&:dup))
      nil
    end
  end
end

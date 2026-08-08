# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/telemetry'
require 'securerandom'
require 'json'

# A Redis-backed stand-in for opentelemetry-api that survives a real fork.
#
# opentelemetry-api is deliberately not a dependency (see wurk.gemspec) and
# still isn't installable in this sandbox (no network) — see TelemetryTest /
# TelemetryClientMiddlewareTest / TelemetryServerMiddlewareTest, which fake it
# per-process. This one has to fake it *across* a `Process.fork`: the producer
# span opens in the test process, the consumer span opens in a forked child,
# and nothing in that child can see this process's in-memory span list. So
# instead of collecting spans in an array, every span writes itself to a Redis
# LIST on finish — the one channel both sides of the fork actually share.
#
# Assigned onto the top-level `OpenTelemetry` constant before `swarm.boot`
# forks, so the child inherits it via the fork's copy-on-write memory exactly
# like it inherits every other loaded class — no marshaling, no IPC beyond the
# Redis writes themselves.
module TelemetryForkFakeOtel
  SpanContext = Struct.new(:trace_id, :span_id) do
    def valid? = !(trace_id.nil? || span_id.nil?)
  end

  RemoteSpan = Struct.new(:context)
  Context = Struct.new(:span)
  Link = Struct.new(:span_context)

  module Status
    Error = Struct.new(:description)

    def self.error(description) = Error.new(description)
  end

  # One instance per producer or consumer span. `role` is stamped by whichever
  # Tracer method built it, so the Redis record self-identifies without the
  # test needing to infer it from shape. `attributes` rides along too — proof
  # that the messaging.* conventions survive the fork, not just the trace ids.
  class Span
    attr_reader :trace_id, :span_id
    attr_accessor :status

    def initialize(role:, name:, kind:, trace_id:, span_id:, attributes: nil, parent_span_id: nil, link: nil)
      @role = role
      @name = name
      @kind = kind
      @trace_id = trace_id
      @span_id = span_id
      @attributes = attributes
      @parent_span_id = parent_span_id
      @link = link
      @exception = nil
      @finished = false
    end

    def record_exception(exception) = @exception = exception.class.name

    # Idempotent: ClientMiddleware relies on `in_span` to finish the producer
    # span implicitly, ServerMiddleware finishes the consumer span explicitly
    # in its `ensure` — neither may double-write.
    def finish
      return if @finished

      @finished = true
      TelemetryForkFakeOtel.record(
        role: @role, name: @name, kind: @kind.to_s, trace_id: @trace_id, span_id: @span_id,
        attributes: @attributes, parent_span_id: @parent_span_id,
        link_trace_id: @link&.trace_id, link_span_id: @link&.span_id,
        error: !(@status.nil? && @exception.nil?), exception: @exception
      )
    end
  end

  class Tracer
    # Producer half — ClientMiddleware's `in_span`. Always a fresh trace: a
    # push has nothing upstream to inherit a context from.
    def in_span(name, attributes: nil, kind: nil)
      span = Span.new(role: 'producer', name: name, kind: kind, attributes: attributes,
                      trace_id: SecureRandom.hex(16), span_id: SecureRandom.hex(8))
      previous = Thread.current[:telemetry_fork_current_span]
      Thread.current[:telemetry_fork_current_span] = span
      begin
        yield span
      ensure
        span.finish
        Thread.current[:telemetry_fork_current_span] = previous
      end
    end

    # Consumer half, in-window case — ServerMiddleware's `start_span` when the
    # producer context is fresh enough to parent to.
    def start_span(name, with_parent:, attributes: nil, kind: nil)
      parent = with_parent.span.context
      Span.new(role: 'consumer', name: name, kind: kind, attributes: attributes, trace_id: parent.trace_id,
               span_id: SecureRandom.hex(8), parent_span_id: parent.span_id)
    end

    # Consumer half, no-parent / stale case — a fresh trace carrying a link
    # back to the producer instead of a parent edge.
    def start_root_span(name, attributes: nil, links: nil, kind: nil)
      Span.new(role: 'consumer', name: name, kind: kind, attributes: attributes, trace_id: SecureRandom.hex(16),
               span_id: SecureRandom.hex(8), link: links&.first&.span_context)
    end
  end

  class TracerProvider
    def tracer(_name, _version) = Tracer.new
  end

  class Propagation
    # ClientMiddleware calls this from inside `in_span`'s block, so "the
    # current span" is always whatever `in_span` just pushed.
    def inject(carrier)
      span = Thread.current[:telemetry_fork_current_span]
      return unless span

      carrier['traceparent'] = "00-#{span.trace_id}-#{span.span_id}-01"
    end

    def extract(carrier)
      match = /\A00-(?<trace_id>\h{32})-(?<span_id>\h{16})-\h{2}\z/.match(carrier['traceparent'].to_s)
      return Context.new(nil) unless match

      Context.new(RemoteSpan.new(SpanContext.new(match[:trace_id], match[:span_id])))
    end
  end

  module Trace
    class << self
      def current_span(context = nil)
        (context.respond_to?(:span) && context.span) || RemoteSpan.new(SpanContext.new(nil, nil))
      end

      def with_span(span)
        previous = Thread.current[:telemetry_fork_current_span]
        Thread.current[:telemetry_fork_current_span] = span
        yield span
      ensure
        Thread.current[:telemetry_fork_current_span] = previous
      end
    end

    Status = TelemetryForkFakeOtel::Status
    Link = TelemetryForkFakeOtel::Link
  end

  class << self
    attr_accessor :redis_url, :redis_key

    def configure(url, key)
      self.redis_url = url
      self.redis_key = key
    end

    def tracer_provider = @tracer_provider ||= TracerProvider.new
    def propagation = @propagation ||= Propagation.new

    # Opens its own connection every call rather than memoizing one: this runs
    # from both the test process (producer) and a forked child (consumer), and
    # a Redis socket does not survive a fork shared between two processes.
    def record(payload)
      client = RedisClient.config(url: redis_url).new_client
      client.call('RPUSH', redis_key, JSON.generate(payload))
    ensure
      client&.close
    end
  end
end

# Top-level so Object.const_get(name) resolves inside the forked child (which
# inherits the constant table but has no Minitest test-class lexical scope) —
# same reasoning as SwarmBootSentinelWorker / StatusCrossProcessWorker.
class TelemetryForkWorker
  include Wurk::Job

  def perform(*)
    :ok
  end
end

# #05 done-when: "Enqueue and execute spans link across the Redis hop, in-
# process and across forks." The unit-level middleware tests already pin the
# parent/link decision and the error taxonomy against a same-process fake;
# this is the one test that proves the W3C context and the taxonomy actually
# survive a real `Process.fork` with a real Redis round trip in between —
# nothing here may mock Redis.
class TelemetryForkTest < Wurk::Test::UnitCase
  parallelize_me!

  # `OpenTelemetry` is a process-wide constant, same as every other telemetry
  # test — serialize against them via the same mutex.
  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  def setup
    super
    @ns = "telfork-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @span_key = "#{@ns}-spans"
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    Object.const_set(:OpenTelemetry, TelemetryForkFakeOtel)
    TelemetryForkFakeOtel.configure(Wurk::Test.redis_url, @span_key)
    @config = build_config
  end

  def teardown
    @observer&.call('UNLINK', @span_key, "queue:#{@queue_name}", private_queue_key(@queue_name))
    @observer&.call('SREM', 'queues', @queue_name)
    @observer&.close
    @config&.reset_redis_pools!
    Object.send(:remove_const, :OpenTelemetry) if Object.const_defined?(:OpenTelemetry)
  ensure
    super
  end

  def test_traced_enqueue_links_to_traced_execute_across_a_real_fork
    jid = push_traced_job

    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      spans = wait_for_spans(2)

      refute_nil spans, "expected a producer and a consumer span for #{jid}, got #{read_spans.inspect}"
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end

    assert_producer_linked_to_consumer(spans)
  end

  # The other drop-in direction: a job that a stock Sidekiq client actually
  # enqueued — no `traceparent`, no field Wurk itself would add — must still
  # run cleanly here with tracing on. Hand-built and LPUSHed directly (the
  # exact two commands Client#push_plain_group issues: SADD queues + LPUSH),
  # never through Wurk::Client, so nothing Wurk-specific rides along by
  # accident.
  def test_a_stock_sidekiq_shaped_job_with_no_traceparent_is_consumed_here
    jid = push_stock_sidekiq_job

    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      spans = wait_for_spans(1)

      refute_nil spans, "expected the job to run and a consumer span to be recorded for #{jid}"
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end

    consumer = spans.find { |s| s['role'] == 'consumer' }

    refute_nil consumer, 'a stock-Sidekiq-shaped job must still be picked up and run'
    assert_equal 'TelemetryForkWorker process', consumer['name']
    refute consumer['error'], 'a clean run must not be recorded as a span error'
    assert_nil consumer['parent_span_id'], 'nothing to parent to — there was no traceparent on the wire'
    assert_nil consumer['link_trace_id'], 'nothing to link to either — a root span with no relation at all'
  end

  private

  def assert_producer_linked_to_consumer(spans)
    producer = spans.find { |s| s['role'] == 'producer' }
    consumer = spans.find { |s| s['role'] == 'consumer' }

    refute_nil producer, 'no producer span was recorded'
    refute_nil consumer, 'no consumer span was recorded — the fork never ran ServerMiddleware'

    assert_equal "#{@queue_name} publish", producer['name']
    assert_equal 'TelemetryForkWorker process', consumer['name']
    assert_equal producer['trace_id'], consumer['trace_id'],
                 'the consumer span must belong to the same trace as the producer — the link across the fork'
    assert_equal producer['span_id'], consumer['parent_span_id'],
                 'a job run within the parent window must be a CHILD of the producer span, not merely linked'
    assert_nil consumer['link_trace_id'], 'an in-window job is parented, not linked — no link should be recorded'
    refute consumer['error'], 'a clean run must not be recorded as a span error'
    assert_equal @queue_name, consumer['attributes']['messaging.destination.name'],
                 'the consumer span must report the queue the fork actually consumed from'
    assert_equal producer['attributes']['messaging.message.id'], consumer['attributes']['messaging.message.id'],
                 'both ends of the hop must agree on the jid — the messaging conventions survive the fork too'
  end

  # Only the keys `Sidekiq::Client` actually writes, built by hand rather than
  # pushed through Wurk::Client so no Wurk-only field (`traceparent` chief among
  # them) can leak in. `created_at`/`enqueued_at` are Float epoch *seconds* —
  # what Sidekiq <= 7.x stamped, not the millis Wurk and Sidekiq 8.x write —
  # because the old shape is the one a drop-in still has to read. That shape is
  # incidental to what this case proves, though: with no `traceparent` there is
  # no producer context to age, so the span is a root either way and
  # `ServerMiddleware#age_of` never runs. The shape itself is pinned in the unit
  # suite instead.
  def push_stock_sidekiq_job
    jid = SecureRandom.hex(12)
    now = Time.now.to_f
    payload = JSON.generate(
      'class' => TelemetryForkWorker.name, 'args' => [], 'queue' => @queue_name,
      'jid' => jid, 'retry' => true, 'created_at' => now, 'enqueued_at' => now
    )
    @observer.call('SADD', 'queues', @queue_name)
    @observer.call('LPUSH', "queue:#{@queue_name}", payload)
    jid
  end

  def push_traced_job
    Wurk::Client.new(config: @config).push(
      'class' => TelemetryForkWorker.name, 'args' => [], 'queue' => @queue_name
    )
  end

  def topology_n(count)
    Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
  end

  def build_config
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:timeout] = 5
    config.telemetry = true
    config
  end

  def read_spans
    @observer.call('LRANGE', @span_key, 0, -1).map { |raw| JSON.parse(raw) }
  end

  def wait_for_spans(count, timeout: 20.0, interval: 0.1)
    deadline = monotonic_now + timeout
    while monotonic_now < deadline
      spans = read_spans
      return spans if spans.size >= count

      sleep interval
    end
    nil
  end

  def monotonic_now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end
end

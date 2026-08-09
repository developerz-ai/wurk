# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# The top-level acceptance suite for Wurk::Flow: the documented Shape example
# (docs/plans/2026/08/07/101-beyond-sidekiq/11-flows.md) proven through real
# job dispatch, rather than by driving Builder/Creation/Completion internals
# directly the way flow_builder_test.rb, flow_creation_test.rb and
# flow_completion_test.rb do.
#
# `Processor#process_one` is "public so tests can drive the loop step-by-step
# without spawning a thread" (processor.rb) — real JobRetry, real
# Batch::ServerMiddleware, real death handling, real Flow::Completion, one
# synchronous step at a time. No BLMOVE thread, no fork, so no timing to get
# wrong: every round below is deterministic.
#
# The sibling *race* itself — the property this slice exists to get right —
# is deliberately not exercised here. It needs independent Redis connections
# racing the same completion call, which a single process cannot produce; see
# test/integration/flow_sibling_race_test.rb for that, under real forks.
class FlowTest < Wurk::Test::UnitCase
  parallelize_me!

  class RootJob
    include Wurk::Job

    def perform(*); end
  end

  class MergeJob
    include Wurk::Job

    def perform(*); end
  end

  # `retry: false` so the first failure goes straight to the dead set — no
  # 25-attempt backoff to fast-forward through.
  class DyingJob
    include Wurk::Job

    sidekiq_options retry: false

    def perform(*)
      raise 'boom'
    end
  end

  def setup
    super
    @queue    = "flowtest-#{Process.pid}-#{object_id}"
    @callback = "#{@queue}-cb"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    # A fresh Configuration starts with a bare chain (require-time
    # registrations only touch the global Wurk.configuration) — without
    # these two, a real ack never advances the flow and a real death never
    # reaches it either.
    @config.server_middleware.add(Wurk::Batch::ServerMiddleware)
    @config.death_handlers << Wurk::Batch::DeathHandler
    # One processor per queue rather than one processor watching both, so a
    # `process_one` call is unambiguous about which hop it drives: a node's
    # own job, or the callback that reacts to it finishing.
    @node_processor = build_processor(@queue)
    @callback_processor = build_processor(@callback)
    # Flow itself always writes through the process's global configuration
    # (Wurk.redis) — same physical Redis as @config, just a different
    # Configuration object, exactly as batch_nested_callbacks_test.rb enqueues
    # via the global Wurk::Client while a from-scratch @config processes it.
    @pool = Wurk.configuration.redis_pool
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}", "queue:#{@callback}",
                private_queue_key(@queue), private_queue_key(@callback))
    end
  ensure
    super
  end

  # --- the documented shape, run to real completion ------------------------

  def test_the_documented_diamond_runs_to_completion_through_real_dispatch
    flow = diamond.run

    @node_processor.process_one     # one root: real perform, real ack
    @callback_processor.process_one # its real :success callback -> Completion#on_success

    assert_equal 'waiting', node_record(flow, 2)['state']
    assert_equal '1', node_record(flow, 2)['remaining']
    assert_equal 1, llen(@queue), 'only the still-unprocessed root should be queued, not the merge node'

    @node_processor.process_one     # the other root
    @callback_processor.process_one # this is the one that must release the merge node

    assert_equal 'enqueued', node_record(flow, 2)['state']
    assert_equal '0', node_record(flow, 2)['remaining']
    assert_equal 1, llen(@queue), 'the merge node is now the only thing on the queue'

    @node_processor.process_one     # the merge job itself
    @callback_processor.process_one # its own :success settles the flow

    assert_equal %w[succeeded 0], flow_record(flow).values_at('state', 'pending')
    assert_equal(%w[succeeded succeeded succeeded], (0..2).map { |i| node_record(flow, i)['state'] })
  end

  # --- build-time refusals leave the flow count untouched -------------------

  def test_a_cyclic_graph_is_rejected_and_no_flow_is_ever_counted
    before = flow_count

    assert_raises(Wurk::Flow::CycleError) do
      Wurk::Flow.new do |f|
        f.job(RootJob, name: :a, depends_on: :b)
        f.job(RootJob, name: :b, depends_on: :a)
      end
    end

    assert_equal before, flow_count
  end

  def test_a_graph_past_a_cap_is_rejected_and_no_flow_is_ever_counted
    before = flow_count

    assert_raises(Wurk::Flow::LimitExceeded) do
      Wurk::Flow.new do |f|
        roots = Array.new(Wurk::Flow::MAX_WIDTH + 1) { f.job(RootJob, queue: @queue) }
        f.job(MergeJob, depends_on: roots, queue: @queue)
      end
    end

    assert_equal before, flow_count
  end

  # A graph that builds cleanly but whose #run is refused (client middleware
  # halting the push) must leave nothing behind either — not the flow header,
  # not any of its three node records, not the index. flow_creation_test.rb
  # already pins this for the flow's own header; this widens it to every node
  # record a 3-node graph would have written.
  def test_a_run_refused_by_client_middleware_leaves_no_flow_or_node_keys_behind
    halt = Class.new { def call(*); end }
    Wurk.configuration.client_middleware.add(halt)
    flow = diamond

    assert_raises(Wurk::Flow::InvalidGraph) { flow.run }

    assert_equal 0, exists(Wurk::Keys.flow(flow.fid))
    (0..2).each { |i| assert_equal 0, exists(Wurk::Keys.flow_node(flow.fid, i)) }
    assert_nil(@pool.with { |conn| conn.call('ZSCORE', Wurk::Keys::FLOWS_SET, flow.fid) })
    assert_equal 0, llen(@queue)
  ensure
    Wurk.configuration.client_middleware.remove(halt)
  end

  # --- failure, through the real retry-exhaustion path ----------------------

  # flow_completion_test.rb drives this by calling
  # Wurk::Batch::DeathHandler.call directly. This is the hop above it: a job
  # that actually raises, JobRetry deciding for real that `retry: false` means
  # no retry, and the dead set + death handlers firing from that real
  # decision — proving the wiring, not just Completion's own claim logic.
  def test_a_dead_root_through_real_retry_exhaustion_fails_the_flow_and_never_releases_its_dependent
    flow = Wurk::Flow.new do |f|
      a = f.job(DyingJob, name: :a, queue: @queue)
      f.job(MergeJob, name: :merge, depends_on: a, queue: @queue)
    end
    flow.callback_queue = @callback
    flow.run

    @node_processor.process_one     # DyingJob raises; retry:false -> dead set -> DeathHandler
    @callback_processor.process_one # the :death callback -> Completion#on_death

    assert_equal 'failed', flow_record(flow)['state']
    assert_equal 'dead', node_record(flow, 0)['state']
    assert_equal 0, llen(@queue), 'the merge node must never be released by a dead dependency'
    # Reaped by expiry, not swept: both keys carry the same clock a live flow
    # does, so an abandoned failed flow disappears on its own.
    assert_in_delta Wurk::Batch::DEFAULT_EXPIRY_SECONDS, ttl(Wurk::Keys.flow_dead(flow.fid)), 60
    assert_in_delta Wurk::Batch::DEFAULT_EXPIRY_SECONDS, ttl(Wurk::Keys.flow(flow.fid)), 60
  end

  private

  # A → C, B → C — the documented Shape example.
  def diamond
    flow = Wurk::Flow.new do |f|
      a = f.job(RootJob, name: :a, queue: @queue)
      b = f.job(RootJob, name: :b, queue: @queue)
      f.job(MergeJob, name: :merge, depends_on: [a, b], queue: @queue)
    end
    flow.callback_queue = @callback
    flow
  end

  def build_processor(queue_name)
    capsule = Wurk::Capsule.new('test', @config)
    capsule.queues = [queue_name]
    capsule.fetcher = Wurk::Fetcher::Reliable.new(capsule)
    Wurk::Processor.new(capsule)
  end

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end

  def flow_count = @pool.with { |conn| conn.call('ZCARD', Wurk::Keys::FLOWS_SET) }
  def exists(key) = @pool.with { |conn| conn.call('EXISTS', key) }
  def llen(queue) = @pool.with { |conn| conn.call('LLEN', "queue:#{queue}") }
  def ttl(key) = @pool.with { |conn| conn.call('TTL', key) }
  def flow_record(flow) = hgetall(Wurk::Keys.flow(flow.fid))
  def node_record(flow, index) = hgetall(Wurk::Keys.flow_node(flow.fid, index))

  def hgetall(key)
    raw = @pool.with { |conn| conn.call('HGETALL', key) }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end
end

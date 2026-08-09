# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Slice 11 — the write half of flows: what creation puts in Redis.
#
# The property under test throughout is all-or-nothing. A flow whose node
# records landed but whose roots never reached a queue does not raise, does not
# show up as failed, and never finishes — so every refusal here has to leave
# Redis untouched, and every acceptance has to leave the whole graph behind.
class FlowCreationTest < Wurk::Test::UnitCase
  parallelize_me!

  class FetchJob
    include Wurk::Job

    def perform(*); end
  end

  class MergeJob
    include Wurk::Job

    def perform(*); end
  end

  def setup
    super
    @pool  = Wurk.configuration.redis_pool
    @queue = "flowq-#{Process.pid}-#{object_id}"
  end

  # --- the flow record ----------------------------------------------------

  def test_writes_the_flow_record
    flow = diamond.run
    record = hgetall(Wurk::Keys.flow(flow.fid))

    assert_equal 'running', record['state']
    assert_equal '3', record['total']
    assert_equal '3', record['pending']
    assert_equal '2', record['depth']
    assert_equal '2', record['width']
    assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME), record['created_at'].to_f, 5
  end

  def test_indexes_the_flow_so_it_is_discoverable_without_its_fid
    flow = diamond.run

    refute_nil(@pool.with { |conn| conn.call('ZSCORE', Wurk::Keys::FLOWS_SET, flow.fid) })
  end

  # Nothing else ever shrinks either index, and a flow adds one member plus one
  # per node — so creation carries the same two-axis trim a batch's first flush
  # does, on both sets it writes to.
  def test_creation_trims_both_indexes_it_writes_to
    stale = "stale-#{Process.pid}-#{object_id}"
    @pool.with do |conn|
      conn.call('ZADD', Wurk::Keys::FLOWS_SET, '1', stale)
      conn.call('ZADD', 'batches', '1', stale)
    end

    diamond.run

    assert_nil(@pool.with { |conn| conn.call('ZSCORE', Wurk::Keys::FLOWS_SET, stale) })
    assert_nil(@pool.with { |conn| conn.call('ZSCORE', 'batches', stale) })
  end

  # --- node records -------------------------------------------------------

  def test_writes_one_record_per_node_carrying_both_directions_of_the_graph
    flow = diamond.run

    assert_equal(%w[0 1 2], (0..2).map { |i| node_record(flow, i)['index'] })
    assert_equal(['a', 'b', ''], (0..2).map { |i| node_record(flow, i)['name'] })
    assert_equal([[], [], [0, 1]], (0..2).map { |i| JSON.parse(node_record(flow, i)['deps']) })
    assert_equal([[2], [2], []], (0..2).map { |i| JSON.parse(node_record(flow, i)['dependents']) })
    assert_equal(%w[0 0 2], (0..2).map { |i| node_record(flow, i)['remaining'] })
  end

  def test_only_the_roots_are_marked_enqueued
    flow = diamond.run

    assert_equal(%w[enqueued enqueued waiting], (0..2).map { |i| node_record(flow, i)['state'] })
  end

  def test_node_records_address_the_job_and_its_batch
    flow = diamond.run

    assert_equal(flow.jids, (0..2).map { |i| node_record(flow, i)['jid'] })
    assert_equal(flow.bids, (0..2).map { |i| node_record(flow, i)['bid'] })
    assert_equal([@queue] * 3, (0..2).map { |i| node_record(flow, i)['queue'] })
    assert_equal([FetchJob.name, FetchJob.name, MergeJob.name], (0..2).map { |i| node_record(flow, i)['class'] })
  end

  def test_a_waiting_node_stores_the_payload_its_gate_will_enqueue
    flow = diamond.run
    payload = JSON.parse(node_record(flow, 2)['payload'])

    assert_equal MergeJob.name, payload['class']
    assert_equal flow.jids[2], payload['jid']
    assert_equal flow.bids[2], payload['bid']
    assert_equal @queue, payload['queue']
    # `enqueued_at` marks arrival on an immediate queue. This node has not
    # arrived anywhere yet, and a stale stamp would misreport its latency.
    refute payload.key?('enqueued_at'), 'a waiting node must not carry enqueued_at'
  end

  # A forward reference makes declaration order and topological order disagree,
  # and only one of them addresses a node: `Node#index` is what its record is
  # keyed by and what every edge is written as. A flow built from configuration
  # rather than from a literal block is exactly this shape.
  def test_a_forward_reference_keys_every_node_by_its_declaration_index
    flow = Wurk::Flow.new do |f|
      f.job(MergeJob, name: :merge, depends_on: %i[a b], queue: @queue)
      f.job(FetchJob, 'a', name: :a, queue: @queue)
      f.job(FetchJob, 'b', name: :b, queue: @queue)
    end.run

    assert_equal(%w[merge a b], (0..2).map { |i| node_record(flow, i)['name'] })
    assert_equal(%w[waiting enqueued enqueued], (0..2).map { |i| node_record(flow, i)['state'] })
    assert_equal([[1, 2], [], []], (0..2).map { |i| JSON.parse(node_record(flow, i)['deps']) })
    assert_equal(flow.jids, (0..2).map { |i| node_record(flow, i)['jid'] })
    assert_equal flow.jids[1, 2].sort, queued_payloads.map { |p| p['jid'] }.sort
    # The payload each record holds has to be its own node's, not the one that
    # happened to sit at the same position in the topological order.
    assert_equal([MergeJob.name, FetchJob.name, FetchJob.name],
                 (0..2).map { |i| node_record(flow, i)['class'] })
    assert_equal([[], ['a'], ['b']], (0..2).map { |i| JSON.parse(node_record(flow, i)['payload'])['args'] })
  end

  # --- what actually goes out ---------------------------------------------

  def test_enqueues_the_roots_and_nothing_else
    flow = diamond.run

    assert_equal 2, llen(@queue)
    assert_equal flow.jids[0, 2].sort, queued_payloads.map { |p| p['jid'] }.sort
    assert_includes @pool.with { |conn| conn.call('SMEMBERS', 'queues') }, @queue
  end

  def test_queued_roots_carry_enqueued_at
    diamond.run

    queued_payloads.each { |payload| assert_in_delta now_in_millis, payload['enqueued_at'], 5_000 }
  end

  def test_declared_options_reach_the_payload
    flow = Wurk::Flow.new { |f| f.job(FetchJob, 1, queue: @queue, retry: 3, track: true) }.run
    payload = queued_payloads.first

    assert_equal [1], payload['args']
    assert_equal 3, payload['retry']
    assert payload['track']
    assert_equal flow.bids[0], payload['bid']
  end

  # cjson maps every JSON number to a double, so a graph decoded and re-encoded
  # inside the creation script would silently round a snowflake id. The payload
  # travels as a string for exactly this reason — on the way to the queue and
  # on the way into the record a waiting node's gate will enqueue from.
  def test_large_integer_arguments_survive_the_write_byte_for_byte
    big  = 2**62
    flow = Wurk::Flow.new do |f|
      a = f.job(FetchJob, big, name: :a, queue: @queue)
      f.job(MergeJob, big + 1, depends_on: a, queue: @queue)
    end.run

    assert_equal [big], queued_payloads.first['args']
    assert_equal [big + 1], JSON.parse(node_record(flow, 1)['payload'])['args']
  end

  # --- the batch behind each node -----------------------------------------

  def test_every_node_batch_is_born_with_both_completion_callbacks
    flow = diamond.run

    (0..2).each do |i|
      callbacks = JSON.parse(hgetall("b-#{flow.bids[i]}")['callbacks'])
      options   = { 'fid' => flow.fid, 'node' => i }

      assert_equal [['success', 'Wurk::Flow::Completion', options],
                    ['death', 'Wurk::Flow::Completion', options]], callbacks
    end
  end

  def test_a_root_batch_holds_its_job_and_a_waiting_one_holds_nothing
    flow = diamond.run
    root = hgetall("b-#{flow.bids[0]}")

    assert_equal %w[1 1 0], [root['total'], root['pending'], root['failures']]
    assert_equal([flow.jids[0]], @pool.with { |conn| conn.call('SMEMBERS', "b-#{flow.bids[0]}-jids") })

    waiting = hgetall("b-#{flow.bids[2]}")

    assert_equal %w[0 0], [waiting['total'], waiting['pending']]
    assert_equal(0, @pool.with { |conn| conn.call('EXISTS', "b-#{flow.bids[2]}-jids") })
  end

  def test_node_batches_describe_themselves_and_join_the_batch_index
    flow = diamond.run

    assert_equal "#{MergeJob}[#2]", hgetall("b-#{flow.bids[2]}")['description']
    flow.bids.each { |bid| refute_nil(@pool.with { |conn| conn.call('ZSCORE', 'batches', bid) }) }
  end

  def test_callbacks_run_on_the_flows_callback_queue
    flow = diamond
    flow.callback_queue = "#{@queue}-cb"
    flow.run

    assert_equal "#{@queue}-cb", hgetall("b-#{flow.bids[0]}")['callback_queue']
  end

  # --- retention ----------------------------------------------------------

  def test_every_key_it_creates_carries_the_batch_clock
    flow = diamond.run

    keys_of(flow).each do |key|
      assert_in_delta Wurk::Batch::DEFAULT_EXPIRY_SECONDS, ttl(key), 60, "#{key} has no default TTL"
    end
  end

  def test_expires_in_overrides_the_clock_on_every_key
    flow = diamond.expires_in(600).run

    keys_of(flow).each { |key| assert_in_delta 600, ttl(key), 60, "#{key} kept the default TTL" }
  end

  # The keys a node's release creates — its batch's live-jid set — are written
  # by a script that has only the fid to go on, so the clock they stamp has to
  # be readable from the record rather than guessed at.
  def test_the_flow_record_carries_the_clock_its_later_writes_need
    assert_equal Wurk::Batch::DEFAULT_EXPIRY_SECONDS.to_s, hgetall(Wurk::Keys.flow(diamond.run.fid))['expiry']
    assert_equal '600', hgetall(Wurk::Keys.flow(diamond.expires_in(600).run.fid))['expiry']
  end

  # --- refusals leave nothing behind --------------------------------------

  def test_non_json_arguments_are_refused_before_anything_is_written
    flow = Wurk::Flow.new do |f|
      f.job(FetchJob, 'fine', queue: @queue)
      f.job(MergeJob, :symbol, queue: @queue)
    end

    assert_raises(ArgumentError) { flow.run }
    assert_nothing_written(flow)
  end

  def test_a_halting_client_middleware_refuses_the_whole_flow
    halt = Class.new do
      def call(_worker, _job, _queue, _pool); end
    end
    Wurk.configuration.client_middleware.add(halt)
    flow = diamond
    error = assert_raises(Wurk::Flow::InvalidGraph) { flow.run }

    assert_match(/client middleware halted the push/, error.message)
    assert_nothing_written(flow)
  ensure
    Wurk.configuration.client_middleware.remove(halt)
  end

  # --- the claim ----------------------------------------------------------

  def test_a_second_run_is_refused_rather_than_creating_a_second_flow
    flow = diamond.run

    assert_raises(RuntimeError) { flow.run }
    assert_equal 2, llen(@queue)
  end

  # A creation whose reply was lost is replayed by the pool. The replay must
  # find the flow already there and write nothing — otherwise every root runs
  # twice, and the graph's jids stop matching what the flow record says.
  def test_a_replayed_creation_writes_nothing_and_enqueues_nothing
    flow = diamond.run
    first_jids = flow.jids

    Wurk::Flow::Creation.new(flow).call

    assert_equal 2, llen(@queue)
    assert_equal(first_jids, (0..2).map { |i| node_record(flow, i)['jid'] })
  end

  # --- interaction with batches -------------------------------------------

  # `Batch::ClientMiddleware` stamps the active batch's bid over whatever a
  # payload carries. Left armed, every node would ack against the enclosing
  # batch and the node batches holding the flow's callbacks would wait forever.
  def test_a_flow_declared_inside_a_batch_keeps_its_own_bids
    batch = Wurk::Batch.new
    flow  = nil
    batch.jobs { flow = diamond.run }

    assert_equal flow.bids[0, 2].sort, queued_payloads.map { |p| p['bid'] }.sort
    refute_includes flow.bids, batch.bid
    adopted = @pool.with { |conn| conn.call('SMEMBERS', "b-#{batch.bid}-jids") }

    assert_empty(adopted & flow.jids)
  end

  # --- handles ------------------------------------------------------------

  def test_run_returns_self_and_publishes_one_jid_and_bid_per_node
    flow = diamond

    assert_nil flow.jids
    refute_predicate flow, :created?
    assert_same flow, flow.run
    assert_predicate flow, :created?
    assert_equal 3, flow.jids.size
    assert_equal 3, flow.bids.uniq.size
  end

  private

  # A → C, B → C: the smallest graph with both a fan-in and a node that has to
  # wait, so one creation covers both halves of what the script writes.
  def diamond
    Wurk::Flow.new do |f|
      a = f.job(FetchJob, 'a', name: :a, queue: @queue)
      b = f.job(FetchJob, 'b', name: :b, queue: @queue)
      f.job(MergeJob, depends_on: [a, b], queue: @queue)
    end
  end

  def keys_of(flow)
    [Wurk::Keys.flow(flow.fid),
     *(0..2).map { |i| Wurk::Keys.flow_node(flow.fid, i) },
     *flow.bids.map { |bid| "b-#{bid}" },
     "b-#{flow.bids[0]}-jids"]
  end

  def assert_nothing_written(flow)
    assert_equal(0, @pool.with { |conn| conn.call('EXISTS', Wurk::Keys.flow(flow.fid)) })
    assert_equal 0, llen(@queue)
    assert_nil(@pool.with { |conn| conn.call('ZSCORE', Wurk::Keys::FLOWS_SET, flow.fid) })
  end

  def node_record(flow, index) = hgetall(Wurk::Keys.flow_node(flow.fid, index))

  def hgetall(key)
    raw = @pool.with { |conn| conn.call('HGETALL', key) }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end

  def llen(queue) = @pool.with { |conn| conn.call('LLEN', "queue:#{queue}") }
  def ttl(key)    = @pool.with { |conn| conn.call('TTL', key) }

  def queued_payloads
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end

  def now_in_millis = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
end

# Split out for the statsd mutex: the emitter is a process-global singleton and
# serializes with every other class that swaps the configured client.
class FlowCreationMetricsTest < Wurk::Test::UnitCase
  parallelize_me!

  def run(*args, &)
    Wurk::Test::STATSD_MUTEX.synchronize { super }
  end

  class FlowMetricJob
    include Wurk::Job

    def perform(*); end
  end

  class FakeClient
    attr_reader :calls

    def initialize = @calls = []
    def increment(metric, **opts) = @calls << [metric, opts]
  end

  def setup
    super
    @queue = "flowmq-#{Process.pid}-#{object_id}"
    @prev  = Wurk.configuration.dogstatsd
    Wurk::Metrics::Statsd.reset!
    @fake = FakeClient.new
    Wurk.configuration.dogstatsd = @fake
  end

  def teardown
    Wurk.configuration.dogstatsd = @prev
    Wurk::Metrics::Statsd.reset!
  ensure
    super
  end

  # `jobs.enqueued` counts jobs put on a queue. A waiting node is recorded, not
  # queued — counting it here would book work twice, once now and once when its
  # gate actually enqueues it.
  def test_only_the_queued_roots_are_counted_as_enqueued
    chain.run
    enqueued = @fake.calls.select { |call| call.first == 'sidekiq.jobs.enqueued' }

    assert_equal 1, enqueued.size
    assert_equal ["worker:#{FlowMetricJob.name}", "queue:#{@queue}"], enqueued.first[1][:tags]
  end

  def test_nothing_is_read_from_the_payloads_without_a_client
    Wurk.configuration.dogstatsd = nil
    Wurk::Metrics::Statsd.reset!

    assert_equal 2, chain.run.jids.size
    assert_empty @fake.calls
  end

  private

  def chain
    Wurk::Flow.new do |f|
      a = f.job(FlowMetricJob, name: :a, queue: @queue)
      f.job(FlowMetricJob, depends_on: a, queue: @queue)
    end
  end
end

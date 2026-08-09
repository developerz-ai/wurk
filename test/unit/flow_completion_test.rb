# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Slice 11 — the correctness core: what a node finishing means for the graph.
#
# One property runs through all of it. A node is released exactly once, by
# exactly one of the siblings it was waiting on, no matter how those siblings
# interleave and no matter how often a callback job is redelivered. Both
# failure modes are silent — a parent released twice runs twice, a parent
# released by nobody hangs forever with nothing raised — so every test here
# counts, rather than asserting that something happened.
class FlowCompletionTest < Wurk::Test::UnitCase
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
    @pool     = Wurk.configuration.redis_pool
    @queue    = "flowcq-#{Process.pid}-#{object_id}"
    @callback = "#{@queue}-cb"
  end

  # --- sibling readiness --------------------------------------------------

  def test_a_dependent_waits_until_the_last_dependency_it_has_succeeds
    flow = diamond.run

    succeed(flow, 0)

    assert_equal 'waiting', node_record(flow, 2)['state']
    assert_equal '1', node_record(flow, 2)['remaining']
    assert_equal 2, queued.size

    succeed(flow, 1)

    assert_equal 'enqueued', node_record(flow, 2)['state']
    assert_equal '0', node_record(flow, 2)['remaining']
    assert_equal(1, queued.count { |job| job['jid'] == flow.jids[2] })
  end

  # The race the slice exists to get right, plus the one that hides inside it:
  # `Callbacks#fire_complete` enqueues before it marks, deliberately preferring
  # a duplicate `:success` over a lost one, so every sibling can arrive twice.
  # Read-then-decide fails both ways here — two siblings reading "one left"
  # release nobody, two reading "I am last" release twice.
  def test_siblings_finishing_at_once_release_their_parent_exactly_once
    flow  = fan_in(8).run
    ready = Thread::Queue.new
    threads = (0...8).flat_map do |index|
      Array.new(2) do
        Thread.new do
          ready.pop
          succeed(flow, index)
        end
      end
    end
    16.times { ready << true }
    threads.each(&:join)

    assert_equal(1, queued.count { |job| job['jid'] == flow.jids[8] })
    assert_equal 'enqueued', node_record(flow, 8)['state']
    assert_equal '0', node_record(flow, 8)['remaining']
    assert_equal %w[running 1], flow_record(flow).values_at('state', 'pending')
  end

  def test_a_replayed_completion_releases_nothing_a_second_time
    flow = diamond.run

    3.times { succeed(flow, 0) }

    assert_equal '1', node_record(flow, 2)['remaining']
    assert_equal '2', flow_record(flow)['pending']

    succeed(flow, 1)

    assert_equal(1, queued.count { |job| job['jid'] == flow.jids[2] })
  end

  # --- what a release actually pushes --------------------------------------

  def test_a_release_pushes_the_payload_creation_stored_for_it
    flow = chain.run
    stored = JSON.parse(node_record(flow, 1)['payload'])

    succeed(flow, 0)
    pushed = queued.find { |job| job['jid'] == flow.jids[1] }

    assert_equal stored.merge('enqueued_at' => pushed['enqueued_at']), pushed
    assert_equal MergeJob.name, pushed['class']
    assert_includes @pool.with { |conn| conn.call('SMEMBERS', 'queues') }, @queue
  end

  # `enqueued_at` marks arrival on an immediate queue, and a waiting node has
  # not arrived anywhere — creation deliberately left it off, so the release is
  # what has to stamp it or every flow node reports an unbounded queue latency.
  def test_a_released_node_is_stamped_as_it_reaches_the_queue
    flow = chain.run

    refute JSON.parse(node_record(flow, 1)['payload']).key?('enqueued_at')
    succeed(flow, 0)

    stamp = queued.find { |job| job['jid'] == flow.jids[1] }['enqueued_at']

    assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond), stamp, 5_000
  end

  # The stamp is spliced into the stored bytes rather than re-encoded: cjson
  # maps every JSON number to a double, so a round trip would round a snowflake
  # id on its way out of the record and into the queue.
  def test_a_release_keeps_64_bit_arguments_exact
    big  = 2**62
    flow = Wurk::Flow.new do |f|
      a = f.job(FetchJob, name: :a, queue: @queue)
      f.job(MergeJob, big, depends_on: a, queue: @queue)
    end.run

    succeed(flow, 0)

    assert_equal [big], queued.find { |job| job['jid'] == flow.jids[1] }['args']
  end

  # A node's batch is born empty — creation queues the roots and only records
  # the rest — so the release has to register the job the way BATCH_PUSH would,
  # or the batch fires `:success` having never held one and the flow runs away
  # from its own jobs.
  def test_a_release_registers_the_job_with_its_node_batch
    flow = chain.run
    bid  = flow.bids[1]

    succeed(flow, 0)
    batch = hgetall("b-#{bid}")

    assert_equal %w[1 1], batch.values_at('total', 'pending')
    assert_equal([flow.jids[1]], @pool.with { |conn| conn.call('SMEMBERS', "b-#{bid}-jids") })
    assert_in_delta Wurk::Batch::DEFAULT_EXPIRY_SECONDS, ttl("b-#{bid}-jids"), 60
  end

  def test_a_release_stamps_the_live_jid_set_with_the_flows_own_clock
    flow = chain.expires_in(600).run

    succeed(flow, 0)

    assert_in_delta 600, ttl("b-#{flow.bids[1]}-jids"), 60
  end

  # --- settling the flow ---------------------------------------------------

  def test_pending_counts_the_nodes_that_have_not_succeeded
    flow = diamond.run

    assert_equal %w[running 3], flow_record(flow).values_at('state', 'pending')

    succeed(flow, 0)

    assert_equal %w[running 2], flow_record(flow).values_at('state', 'pending')
  end

  def test_the_flow_is_marked_succeeded_when_its_last_node_is
    flow = diamond.run

    [0, 1, 2].each { |index| succeed(flow, index) }
    record = flow_record(flow)

    assert_equal %w[succeeded 0], record.values_at('state', 'pending')
    assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME), record['finished_at'].to_f, 5
    assert_equal(%w[succeeded succeeded succeeded], (0..2).map { |i| node_record(flow, i)['state'] })
  end

  # HSET and HINCRBY both create the hash they address, so a completion arriving
  # for a flow whose record is gone — expired, or released by hand — would
  # rebuild it out of the jobs still finishing against it, with no clock on the
  # rebuilt keys and no way for anything to collect them. The record is the
  # flow: without it there is nothing to advance and nothing to fail.
  def test_a_completion_for_a_flow_whose_record_is_gone_resurrects_nothing
    flow = diamond.run
    @pool.with { |conn| conn.call('DEL', Wurk::Keys.flow(flow.fid)) }

    succeed(flow, 0)
    kill_node(flow, 1)

    assert_equal 0, exists(Wurk::Keys.flow(flow.fid))
    assert_equal 0, exists(Wurk::Keys.flow_dead(flow.fid))
    assert_equal(%w[enqueued enqueued waiting], (0..2).map { |i| node_record(flow, i)['state'] })
    assert_equal 2, queued.size
  end

  # --- death ---------------------------------------------------------------

  # Nothing here stops the graph: a batch holding a dead job never fires
  # `:success`, so a dead node's dependents are never released rather than
  # cancelled. The write only stops the record from reading `running` forever.
  def test_a_dead_node_fails_the_flow_and_releases_nothing
    flow = diamond.run

    kill_node(flow, 0)
    record = flow_record(flow)

    assert_equal 'failed', record['state']
    assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME), record['failed_at'].to_f, 5
    assert_equal '3', record['pending']
    assert_equal 'dead', node_record(flow, 0)['state']
    assert_equal '2', node_record(flow, 2)['remaining']
    assert_equal 2, queued.size
    assert_in_delta Wurk::Batch::DEFAULT_EXPIRY_SECONDS, ttl(Wurk::Keys.flow_dead(flow.fid)), 60
  end

  # The two callbacks race each other whenever an operator retries a dead job
  # while its `:death` callback is still failing and being redelivered. The
  # retry has to win: it is the newer fact, and a death re-applied over it would
  # fail a flow that is running and hold a node nothing is waiting on any more.
  def test_a_death_redelivered_after_a_recovery_does_not_re_fail_the_flow
    flow = diamond.run
    kill_node(flow, 0)
    succeed(flow, 0)

    kill_node(flow, 0)

    assert_equal 'running', flow_record(flow)['state']
    assert_equal 'succeeded', node_record(flow, 0)['state']
    assert_empty dead_nodes(flow)
  end

  def test_every_dead_node_is_named_and_the_first_owns_the_timestamp
    flow = diamond.run

    kill_node(flow, 0)
    first = flow_record(flow)['failed_at']
    kill_node(flow, 1)

    assert_equal %w[0 1], dead_nodes(flow).sort
    assert_equal first, flow_record(flow)['failed_at']
  end

  # The callback job carrying a death retries like any other, so the one line
  # that tells an operator their graph stopped has to be the one that marked it
  # — otherwise a callback failing in a loop reports the same death forever.
  def test_a_replayed_death_marks_the_node_once_and_says_so_once
    flow = diamond.run

    log = capture_log { 3.times { kill_node(flow, 0) } }

    assert_equal ['0'], dead_nodes(flow)
    assert_equal '3', flow_record(flow)['pending']
    assert_equal 1, log.scan('node 0 died').size
    assert_match(/flow #{flow.fid}: node 0 died; nothing downstream of it will run/, log)
  end

  # `failed` is a state, not a tombstone: retrying the dead job out of the
  # morgue to success clears the batch's death mark, and its `:success` then
  # arrives here — so the node has to be claimable from `dead` too, or the flow
  # that decision 1 says resumes would stall for good.
  def test_a_dead_node_retried_to_success_resumes_the_flow
    flow = diamond.run

    kill_node(flow, 0)
    succeed(flow, 0)

    assert_empty dead_nodes(flow)
    assert_equal 'running', flow_record(flow)['state']
    refute flow_record(flow).key?('failed_at')
    assert_equal 'succeeded', node_record(flow, 0)['state']
    assert_equal '1', node_record(flow, 2)['remaining']
  end

  def test_a_flow_stays_failed_while_any_node_is_still_dead
    flow = diamond.run

    kill_node(flow, 0)
    kill_node(flow, 1)
    succeed(flow, 0)

    assert_equal ['1'], dead_nodes(flow)
    assert_equal 'failed', flow_record(flow)['state']
  end

  def test_a_flow_that_recovered_from_a_death_still_ends_succeeded
    flow = diamond.run

    kill_node(flow, 0)
    [0, 1, 2].each { |index| succeed(flow, index) }
    record = flow_record(flow)

    assert_equal 'succeeded', record['state']
    refute record.key?('failed_at')
  end

  # --- the callback path creation actually wires up ------------------------

  # Everything above calls the completion directly. This is the hop that gets
  # it called at all: a node's job acks, its batch fires `:success`, and the
  # callback spec creation wrote turns into a job that lands here. A rename on
  # either side breaks a flow silently, so it is worth driving end to end once.
  def test_a_node_batch_succeeding_advances_the_flow_through_its_own_callback
    flow = diamond.run

    ack_success(flow.bids[0], flow.jids[0])
    run_callbacks

    assert_equal 'succeeded', node_record(flow, 0)['state']
    assert_equal '1', node_record(flow, 2)['remaining']

    ack_success(flow.bids[1], flow.jids[1])
    run_callbacks

    assert_equal(1, queued.count { |job| job['jid'] == flow.jids[2] })
  end

  def test_a_node_batch_dying_fails_the_flow_through_its_own_callback
    flow = diamond.run

    Wurk::Batch::DeathHandler.call({ 'bid' => flow.bids[0], 'jid' => flow.jids[0] }, RuntimeError.new('boom'))
    run_callbacks

    assert_equal 'failed', flow_record(flow)['state']
    assert_equal ['0'], dead_nodes(flow)
  end

  # The whole recovery story on the real path: a node dies, the flow is marked
  # failed, the dead job is retried out of the morgue exactly as SortedEntry#retry
  # re-pushes it, and the flow picks up where it stopped.
  def test_a_flow_resumes_when_a_dead_node_is_retried_out_of_the_morgue
    flow = diamond.run
    Wurk::Batch::DeathHandler.call({ 'bid' => flow.bids[0], 'jid' => flow.jids[0] }, RuntimeError.new('boom'))
    run_callbacks

    Wurk::Client.push(JSON.parse(node_record(flow, 0)['payload']))
    ack_success(flow.bids[0], flow.jids[0])
    run_callbacks

    assert_equal 'running', flow_record(flow)['state']
    assert_equal 'succeeded', node_record(flow, 0)['state']
    assert_equal '1', node_record(flow, 2)['remaining']
  end

  private

  # A → C, B → C: the smallest graph with a fan-in, so one flow covers both a
  # node that has to wait and the siblings racing to release it.
  def diamond
    build do |f|
      a = f.job(FetchJob, 'a', name: :a, queue: @queue)
      b = f.job(FetchJob, 'b', name: :b, queue: @queue)
      f.job(MergeJob, depends_on: [a, b], queue: @queue)
    end
  end

  def chain
    build do |f|
      a = f.job(FetchJob, name: :a, queue: @queue)
      f.job(MergeJob, depends_on: a, queue: @queue)
    end
  end

  def fan_in(count)
    build do |f|
      roots = Array.new(count) { |i| f.job(FetchJob, i, queue: @queue) }
      f.job(MergeJob, depends_on: roots, queue: @queue)
    end
  end

  def build(&)
    flow = Wurk::Flow.new(&)
    flow.callback_queue = @callback
    flow
  end

  def succeed(flow, index)
    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => index })
  end

  def kill_node(flow, index)
    Wurk::Flow::Completion.new.on_death(nil, { 'fid' => flow.fid, 'node' => index })
  end

  # The real ack path — the server middleware, not the script under it.
  def ack_success(bid, jid)
    middleware = Wurk::Batch::ServerMiddleware.new
    middleware.config = Wurk.configuration
    middleware.call(nil, { 'bid' => bid, 'jid' => jid }, @queue) {}
  end

  # Drain whatever the batch callbacks enqueued and run it, the way a worker
  # fetching from the callback queue would.
  def run_callbacks
    payloads = @pool.with { |conn| conn.call('LRANGE', "queue:#{@callback}", 0, -1) }
    @pool.with { |conn| conn.call('DEL', "queue:#{@callback}") }
    payloads.reverse_each do |raw|
      job = JSON.parse(raw)

      assert_equal 'Wurk::Batch::CallbackJob', job['class']
      Wurk::Batch::CallbackJob.new.perform(*job['args'])
    end
  end

  # Swaps the process-global logger under the suite-wide mutex the other
  # global-state tests use, rather than racing a parallel class's own swap.
  def capture_log
    io = StringIO.new
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      previous = Wurk.logger
      Wurk.logger = ::Logger.new(io)
      begin
        yield
      ensure
        Wurk.logger = previous
      end
    end
    io.string
  end

  def exists(key) = @pool.with { |conn| conn.call('EXISTS', key) }
  def dead_nodes(flow) = @pool.with { |conn| conn.call('SMEMBERS', Wurk::Keys.flow_dead(flow.fid)) }.sort
  def flow_record(flow) = hgetall(Wurk::Keys.flow(flow.fid))
  def node_record(flow, index) = hgetall(Wurk::Keys.flow_node(flow.fid, index))
  def ttl(key) = @pool.with { |conn| conn.call('TTL', key) }

  def hgetall(key)
    raw = @pool.with { |conn| conn.call('HGETALL', key) }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end

  def queued
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end
end

# Split out for the statsd mutex: the emitter is a process-global singleton and
# serializes with every other class that swaps the configured client.
class FlowCompletionMetricsTest < Wurk::Test::UnitCase
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
    @queue = "flowcmq-#{Process.pid}-#{object_id}"
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

  # Creation counted only the roots it queued, on the grounds that a recorded
  # node is counted by its own enqueue. This is that enqueue.
  def test_a_released_node_is_counted_as_enqueued_when_it_is_queued
    flow = fan_out.run
    @fake.calls.clear

    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => 0 })
    enqueued = @fake.calls.select { |call| call.first == 'sidekiq.jobs.enqueued' }

    assert_equal 2, enqueued.size
    assert_equal ["worker:#{FlowMetricJob.name}", "queue:#{@queue}"], enqueued.first[1][:tags]
  end

  def test_a_leaf_completing_counts_nothing
    flow = fan_out.run
    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => 0 })
    @fake.calls.clear

    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => 1 })

    assert_empty @fake.calls
  end

  private

  def fan_out
    Wurk::Flow.new do |f|
      root = f.job(FlowMetricJob, name: :root, queue: @queue)
      f.job(FlowMetricJob, 'left', depends_on: root, queue: @queue)
      f.job(FlowMetricJob, 'right', depends_on: root, queue: @queue)
    end
  end
end

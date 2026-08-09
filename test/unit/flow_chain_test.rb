# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Slice 11, step 4 — chains: a linear flow where every node is handed the node
# before it.
#
# The property under all of it is that a chain link runs with the *upstream's
# result* or does not run at all. Every other answer is silent: a truncated
# result is a wrong argument the job will happily succeed on, a missing one is
# a job running with a sentinel string where its input should be. So each way
# the result can fail to be there gets its own refusal, and the refusals are
# what most of this file counts.
class FlowChainTest < Wurk::Test::UnitCase
  parallelize_me!

  class FetchJob
    include Wurk::Job

    def perform(*); end
  end

  class ParseJob
    include Wurk::Job

    def perform(*); end
  end

  class StoreJob
    include Wurk::Job

    def perform(*); end
  end

  class SecretJob
    include Wurk::Job

    sidekiq_options encrypt: true

    def perform(*); end
  end

  class UntrackedJob
    include Wurk::Job

    sidekiq_options track: false

    def perform(*); end
  end

  def setup
    super
    @pool     = Wurk.configuration.redis_pool
    @queue    = "flowchain-#{Process.pid}-#{object_id}"
    @callback = "#{@queue}-cb"
  end

  # --- the graph a chain is ------------------------------------------------

  def test_a_chain_is_a_linear_flow
    flow = chain.run

    assert_equal 3, flow.size
    assert_equal([[], [0], [1]], flow.nodes.map { |node| node.dependencies.map(&:index) })
    assert_equal 3, flow.depth
    assert_equal 1, flow.width
  end

  # The guard is not `Flow.new`'s spare: `chain` always hands `new` a block of
  # its own, so without this the caller's mistake surfaces as a NoMethodError
  # on nil from inside the builder.
  def test_a_chain_without_a_block_is_refused_the_way_a_flow_is
    assert_raises(ArgumentError) { Wurk::Flow.chain }
  end

  # Only the head is queued at creation: the rest are records waiting on a
  # result that does not exist yet, exactly as any other flow's non-roots are.
  def test_only_the_head_of_a_chain_is_enqueued
    flow = chain.run

    assert_equal([flow.jids[0]], queued.map { |job| job['jid'] })
    assert_equal(%w[enqueued waiting waiting], (0..2).map { |i| node_record(flow, i)['state'] })
  end

  # A pipe reads Wurk::Status, and tracking is opt-in per job — so a node whose
  # result something downstream needs is enqueued tracked whether or not the
  # caller thought to say so. The tail is not: nothing reads its result.
  def test_every_node_a_pipe_reads_is_enqueued_tracked
    flow = chain.run

    assert_equal([true, true, nil], (0..2).map { |i| stored_payload(flow, i)['track'] })
  end

  def test_an_ordinary_flow_node_is_not_tracked_for_a_pipe_that_is_not_there
    flow = build { |f| f.job(FetchJob, queue: @queue) }.run

    assert_nil stored_payload(flow, 0)['track']
  end

  # --- what a pipe actually delivers ---------------------------------------

  def test_a_link_runs_with_its_upstreams_result_appended_to_its_own_arguments
    flow = build do |f|
      a = f.job(FetchJob, 'https://example.com', queue: @queue)
      f.job(StoreJob, 'reports', pipe: a, queue: @queue)
    end.run

    complete(flow, 0, { 'body' => 'hi', 'code' => 200 })
    succeed(flow, 0)

    assert_equal ['reports', { 'body' => 'hi', 'code' => 200 }], released(flow, 1)['args']
  end

  # The stored payload is valid JSON with a sentinel where the argument goes,
  # so a flow caught mid-flight reads as a job — and the release is a byte
  # splice over that sentinel, not a decode and re-encode.
  def test_a_waiting_link_stores_a_sentinel_naming_what_it_waits_for
    flow = chain.run
    sentinel = stored_payload(flow, 1)['args'].last

    assert_equal "wurk.flow.pipe:#{flow.fid}:1", sentinel
    assert_equal sentinel, node_record(flow, 1)['pipe']
    assert_empty node_record(flow, 0)['pipe']
  end

  # cjson maps every JSON number to a double, so a decode-and-re-encode of the
  # payload would round a snowflake id in a *neighbouring* argument on its way
  # to the queue, and round the piped value itself the same way.
  def test_a_splice_keeps_64_bit_numbers_exact_on_both_sides_of_it
    big   = 2**62
    other = (2**62) + 1
    flow  = build do |f|
      a = f.job(FetchJob, queue: @queue)
      f.job(StoreJob, other, pipe: a, queue: @queue)
    end.run

    complete(flow, 0, big)
    succeed(flow, 0)

    assert_equal [other, big], released(flow, 1)['args']
  end

  # `%` is a capture reference to gsub and nothing at all to the job that
  # returned it, so the splice cannot go through a pattern replacement.
  def test_a_result_full_of_pattern_metacharacters_arrives_verbatim
    value = '100%% off %1 [a-z]+ \\ "quoted"'
    flow  = two_step.run

    complete(flow, 0, value)
    succeed(flow, 0)

    assert_equal [value], released(flow, 1)['args']
  end

  # A job that returned nil stores no result field at all, and nil is a
  # perfectly good argument — the distinction that matters is between "returned
  # nothing" and "left nothing behind", and only the second one refuses.
  def test_a_nil_result_pipes_as_nil
    flow = two_step.run

    complete(flow, 0, nil)
    succeed(flow, 0)

    assert_equal [nil], released(flow, 1)['args']
  end

  def test_a_chain_runs_end_to_end_one_link_at_a_time
    flow = chain.run

    complete(flow, 0, 'fetched')
    succeed(flow, 0)

    assert_equal ['fetched'], released(flow, 1)['args']

    complete(flow, 1, %w[parsed rows])
    succeed(flow, 1)

    assert_equal [[%w[parsed rows]]], [released(flow, 2)['args']]
    assert_equal '1', flow_record(flow)['pending']
  end

  # A chain is still a graph: a branch off one of its links is an ordinary
  # dependent, released by the same call that pipes into the next link.
  def test_a_branch_off_a_chain_link_is_released_alongside_the_pipe
    flow = build do |f|
      a = f.job(FetchJob, queue: @queue)
      f.job(ParseJob, pipe: a, queue: @queue)
      f.job(StoreJob, depends_on: a, queue: @queue)
    end.run

    complete(flow, 0, 'x')
    succeed(flow, 0)

    assert_equal ['x'], released(flow, 1)['args']
    assert_empty released(flow, 2)['args']
  end

  # --- the hop that has to line up -----------------------------------------

  # Everything above writes the status row by hand. This is the one that proves
  # the row is there to write over: the head's job runs through the real server
  # chain, where Middleware::Status stores `perform`'s return value *inside*
  # Batch::ServerMiddleware's ack — so the result exists before the batch can
  # fire `:success`, and therefore before the callback that pipes it. Reverse
  # that registration order and every chain in the world breaks with "piped
  # result is missing", which is exactly what this asserts is not happening.
  def test_a_chain_pipes_what_perform_returned_over_the_real_middleware_chain
    flow = two_step.run

    run_node(flow, 0) { { 'rows' => 41 } }
    run_callbacks

    assert_equal 'complete', Wurk::Status.get(flow.jids[0]).state
    assert_equal [{ 'rows' => 41 }], released(flow, 1)['args']
    assert_equal 'enqueued', node_record(flow, 1)['state']
  end

  # The cap end to end, with nothing about it staged: a job returns more than
  # Middleware::Status will store, Status keeps the head and says so, and the
  # chain refuses the head rather than running the next job on it.
  def test_a_result_past_the_stored_result_cap_stops_the_chain
    flow = two_step.run

    run_node(flow, 0) { 'x' * (Wurk::Middleware::Status::MAX_RESULT_BYTES + 1) }
    run_callbacks

    assert_predicate Wurk::Status.get(flow.jids[0]), :result_truncated?
    assert_equal 'broken', node_record(flow, 1)['state']
    assert_match(/truncated at the stored-result cap/, node_record(flow, 1)['error'])
    assert_empty(queued.select { |job| job['jid'] == flow.jids[1] })
    assert_equal 'failed', flow_record(flow)['state']
  end

  # --- the refusals, at run time -------------------------------------------

  # The headline of the slice plan's decision 2: past slice 06's cap the stored
  # result is a head with the rest dropped. Piping it would hand the job an
  # argument that is not what the upstream returned, and the job would succeed
  # on it.
  def test_a_truncated_upstream_result_breaks_the_link_instead_of_piping_the_head
    flow = two_step.run
    Wurk::Status.write(flow.jids[0], state: 'complete', result: '["huge', result_truncated: '1')

    log = capture_log { succeed(flow, 0) }
    node = node_record(flow, 1)

    assert_equal 'broken', node['state']
    assert_match(/truncated at the stored-result cap/, node['error'])
    assert_empty(queued.select { |job| job['jid'] == flow.jids[1] })
    assert_match(/flow #{flow.fid}: node 1 cannot run — .*truncated.*flow is marked failed/, log)
  end

  def test_a_withheld_upstream_result_breaks_the_link
    flow = two_step.run
    Wurk::Status.write(flow.jids[0], state: 'complete', result_withheld: '1')

    succeed(flow, 0)

    assert_match(/withheld/, node_record(flow, 1)['error'])
    assert_empty(queued.select { |job| job['jid'] == flow.jids[1] })
  end

  # `status_retention: 0`, a row past its TTL, a Redis blip while the terminal
  # write went out: all of them leave the same nothing, and a chain that ran
  # anyway would run with a sentinel string as its argument.
  def test_a_missing_upstream_row_breaks_the_link
    flow = two_step.run

    succeed(flow, 0)

    assert_match(/missing/, node_record(flow, 1)['error'])
    assert_empty(queued.select { |job| job['jid'] == flow.jids[1] })
  end

  # An upstream that is `running` again — retried after the release already
  # happened once, say — has no result yet either. Only `complete` does.
  def test_a_non_terminal_upstream_row_breaks_the_link
    flow = two_step.run
    Wurk::Status.write(flow.jids[0], state: 'running')

    succeed(flow, 0)

    assert_match(/missing/, node_record(flow, 1)['error'])
  end

  # A broken node is why the flow is failed, so it joins the same set the dead
  # ones do — and unlike them it never leaves it, because there is no job in
  # the morgue for anyone to retry.
  def test_a_broken_link_fails_the_flow_and_stays_that_way
    flow = chain.run

    succeed(flow, 0)
    record = flow_record(flow)

    assert_equal 'failed', record['state']
    assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME), record['failed_at'].to_f, 5
    assert_equal ['1'], dead_nodes(flow)
    assert_equal '2', record['pending']
    assert_in_delta Wurk::Batch::DEFAULT_EXPIRY_SECONDS, ttl(Wurk::Keys.flow_dead(flow.fid)), 60
    assert_equal 'waiting', node_record(flow, 2)['state']
  end

  # The claim is the same one every other advance takes, so a callback job
  # redelivered against a link already broken re-breaks nothing and re-reports
  # nothing: `remaining` is already below zero for it, and only a decrement
  # that lands exactly on zero releases.
  def test_a_replayed_completion_breaks_the_link_once
    flow = two_step.run

    log = capture_log { 3.times { succeed(flow, 0) } }

    assert_equal ['1'], dead_nodes(flow)
    assert_equal 1, log.scan('cannot run').size
  end

  # --- the refusals, at build and create time ------------------------------

  # Decision 2 declines to synthesise an aggregate argument for a fan-in, so
  # `pipe:` names one dependency and cannot be combined with a second set.
  def test_a_pipe_cannot_be_combined_with_depends_on
    error = assert_raises(Wurk::Flow::InvalidGraph) do
      Wurk::Flow.new do |f|
        a = f.job(FetchJob, name: :a)
        b = f.job(FetchJob, name: :b)
        f.job(ParseJob, pipe: a, depends_on: b)
      end
    end

    assert_match(/cannot be combined with depends_on/, error.message)
  end

  def test_a_pipe_refuses_a_list_of_sources
    error = assert_raises(Wurk::Flow::InvalidGraph) do
      Wurk::Flow.new do |f|
        a = f.job(FetchJob, name: :a)
        f.job(ParseJob, pipe: [a])
      end
    end

    assert_match(/pipe: takes one node or name/, error.message)
  end

  # Creation fills in `track: true` for a node a pipe reads. An explicit
  # `track: false` on that same node is the one thing it will not overrule:
  # the two say opposite things, and picking a winner silently is how a chain
  # ends up refusing to run for a reason nobody wrote down.
  def test_a_pipe_from_an_explicitly_untracked_node_is_refused
    error = assert_raises(Wurk::Flow::InvalidGraph) do
      Wurk::Flow.new do |f|
        a = f.job(FetchJob, name: :a, track: false)
        f.job(ParseJob, pipe: a)
      end
    end

    assert_match(/declared track: false/, error.message)
  end

  # A class-level `track: false` is a default, not a contradiction — the node's
  # own option wins the way any job option does, so the chain still runs.
  def test_a_class_default_of_track_false_is_overruled_rather_than_refused
    flow = build do |f|
      a = f.job(UntrackedJob, queue: @queue)
      f.job(ParseJob, pipe: a, queue: @queue)
    end.run

    assert stored_payload(flow, 0)['track']
  end

  # An encrypted job's return value is deliberately never stored, so a pipe
  # from one can never carry anything. Refused before the write rather than at
  # the release that would discover it minutes later — and `encrypt` can come
  # from the class, which is why the check needs a normalized payload.
  def test_a_pipe_from_an_encrypted_node_is_refused_before_anything_is_written
    flow = build do |f|
      a = f.job(SecretJob, 'secret', queue: @queue)
      f.job(ParseJob, pipe: a, queue: @queue)
    end
    error = assert_raises(Wurk::Flow::InvalidGraph) { flow.run }

    assert_match(/declares encrypt: true/, error.message)
    assert_equal 0, exists(Wurk::Keys.flow(flow.fid))
    assert_empty queued
  end

  # A middleware that rewrote `args` would leave a job running with the wrong
  # number of arguments, or with the sentinel itself as its input. Both are
  # silent; neither reaches Redis.
  def test_a_middleware_that_rewrites_the_piped_argument_is_refused
    Wurk.configuration.client_middleware.add(ArgumentEater)
    flow  = two_step
    error = assert_raises(Wurk::Flow::InvalidGraph) { flow.run }

    assert_match(/rewrote the argument its pipe writes into/, error.message)
    assert_equal 0, exists(Wurk::Keys.flow(flow.fid))
    assert_empty queued
  ensure
    Wurk.configuration.client_middleware.remove(ArgumentEater)
  end

  class ArgumentEater
    include Wurk::Middleware::ClientMiddleware

    def call(_klass, job, _queue, _pool)
      job['args'] = []
      yield
    end
  end

  private

  def chain
    flow = Wurk::Flow.chain do |c|
      c.job(FetchJob, queue: @queue)
      c.job(ParseJob, queue: @queue)
      c.job(StoreJob, queue: @queue)
    end
    flow.callback_queue = @callback
    flow
  end

  def two_step
    build do |f|
      a = f.job(FetchJob, queue: @queue)
      f.job(ParseJob, pipe: a, queue: @queue)
    end
  end

  def build(&)
    flow = Wurk::Flow.new(&)
    flow.callback_queue = @callback
    flow
  end

  # The row Middleware::Status would have written when the node's job returned.
  # nil is stored as *no field at all* (Middleware::Status#encode_result drops
  # it), which is the case the pipe has to tell apart from a row that is not
  # there — so the helper has to reproduce the absence, not write "null".
  def complete(flow, index, value)
    fields = value.nil? ? {} : { result: Wurk.dump_json(value) }
    Wurk::Status.write(flow.jids[index], state: 'complete', **fields)
  end

  def succeed(flow, index)
    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => index })
  end

  # The bound chain the Processor invokes (lib/wurk/processor.rb), not a
  # middleware built by hand: the registration order of Status inside
  # Batch::ServerMiddleware is the thing under test.
  def run_node(flow, index, &)
    payload = stored_payload(flow, index)
    Wurk.configuration.default_capsule.server_middleware.invoke(nil, payload, payload['queue'], &)
  end

  # Drain whatever the batch callbacks enqueued and run it, the way a worker
  # fetching from the callback queue would.
  def run_callbacks
    payloads = @pool.with { |conn| conn.call('LRANGE', "queue:#{@callback}", 0, -1) }
    @pool.with { |conn| conn.call('DEL', "queue:#{@callback}") }
    payloads.reverse_each { |raw| Wurk::Batch::CallbackJob.new.perform(*JSON.parse(raw)['args']) }
  end

  def released(flow, index)
    queued.find { |job| job['jid'] == flow.jids[index] } || flunk("node #{index} was never queued")
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

  def stored_payload(flow, index) = JSON.parse(node_record(flow, index)['payload'])
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

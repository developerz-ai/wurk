# frozen_string_literal: true

require_relative '../test_helper'

# Slice 11 — the read side of a flow: Wurk::Flow::Status and Wurk::FlowSet, the
# canonical inspectors both the dashboard and the /v1 API go through.
#
# Every fixture is a real flow created by Wurk::Flow#run and moved by the real
# completion scripts, never a hand-written hash: the point of a single reader is
# that it agrees with the writers, and a test that seeds its own keys would
# agree with itself instead.
class FlowStatusTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns = "#{Process.pid}_#{object_id}"
    @queue = "flowq-#{@ns}"
  end

  def test_reads_the_header_a_created_flow_wrote
    flow = diamond

    status = Wurk::Flow::Status.new(flow.fid)

    assert_predicate status, :exists?
    assert_predicate status, :running?
    refute_predicate status, :terminal?
    assert_equal 3, status.total
    assert_equal 3, status.pending
    assert_equal 0, status.succeeded_count
    assert_equal 2, status.depth
    assert_equal 2, status.width
    assert_in_delta Time.now.to_f, status.created_at, 5.0
    assert_nil status.finished_at
    assert_empty status.dead_indexes
  end

  def test_unknown_fid_exists_is_false_and_reads_nothing
    status = Wurk::Flow::Status.new("no-such-flow-#{@ns}")

    refute_predicate status, :exists?
    assert_equal 0, status.total
    assert_empty status.nodes
    assert_nil status.created_at
  end

  def test_blank_fid_is_refused_rather_than_reading_the_key_prefix
    assert_raises(ArgumentError) { Wurk::Flow::Status.new('') }
    assert_raises(ArgumentError) { Wurk::Flow::Status.new(nil) }
  end

  def test_nodes_identify_their_jobs_in_declaration_order
    flow = diamond

    nodes = Wurk::Flow::Status.new(flow.fid).nodes

    assert_equal [0, 1, 2], nodes.map(&:index)
    assert_equal(%w[Alpha Beta Merge].map { |k| "#{k}#{@ns}" }, nodes.map(&:klass))
    assert_equal [nil, nil, 'merge'], nodes.map(&:name)
    assert_equal flow.jids, nodes.map(&:jid)
    assert_equal flow.bids, nodes.map(&:bid)
    refute(nodes.any?(&:piped?))
  end

  def test_nodes_carry_both_directions_of_every_edge
    flow = diamond

    nodes = Wurk::Flow::Status.new(flow.fid).nodes

    assert_equal [[], [], [0, 1]], nodes.map(&:dependencies)
    assert_equal [[2], [2], []], nodes.map(&:dependents)
    assert_equal [0, 0, 2], nodes.map(&:remaining)
    assert_equal %w[enqueued enqueued waiting], nodes.map(&:state)
  end

  # Declaration order is what addresses a node, and it is not topological order
  # the moment a `depends_on:` names something declared later in the block.
  def test_forward_references_still_read_back_in_declaration_order
    flow = Wurk::Flow.new do |f|
      f.job("Merge#{@ns}", name: :merge, depends_on: %i[a b], queue: @queue)
      f.job("Alpha#{@ns}", name: :a, queue: @queue)
      f.job("Beta#{@ns}", name: :b, queue: @queue)
    end.run

    nodes = Wurk::Flow::Status.new(flow.fid).nodes

    assert_equal %w[merge a b], nodes.map(&:name)
    assert_equal [[1, 2], [], []], nodes.map(&:dependencies)
    assert_equal %w[waiting enqueued enqueued], nodes.map(&:state)
  end

  def test_a_succeeding_node_moves_both_the_header_and_its_dependents
    flow = diamond
    advance(flow, 0)

    status = Wurk::Flow::Status.new(flow.fid)

    assert_equal 2, status.pending
    assert_equal 1, status.succeeded_count
    assert_equal %w[succeeded enqueued waiting], status.nodes.map(&:state)
    assert_equal 1, status.nodes[2].remaining
  end

  def test_the_last_node_settles_the_flow
    flow = Wurk::Flow.new { |f| f.job("Solo#{@ns}", queue: @queue) }.run
    advance(flow, 0)

    status = Wurk::Flow::Status.new(flow.fid)

    assert_predicate status, :succeeded?
    assert_predicate status, :terminal?
    assert_equal 0, status.pending
    assert_in_delta Time.now.to_f, status.finished_at, 5.0
  end

  def test_a_dead_node_shows_on_the_flow_and_in_the_dead_set
    flow = diamond
    Wurk::Flow::Completion.new.on_death(nil, { 'fid' => flow.fid, 'node' => 1 })

    status = Wurk::Flow::Status.new(flow.fid)

    assert_predicate status, :failed?
    # Recoverable: retrying the job out of the morgue resumes the flow, so this
    # is not one of the states nothing can move again.
    refute_predicate status, :terminal?
    assert_equal [1], status.dead_indexes
    assert_equal 'dead', status.nodes[1].state
    assert_in_delta Time.now.to_f, status.failed_at, 5.0
  end

  # The one node state whose cause is nowhere else: no job ran, so there is no
  # failure in the morgue to read the reason off.
  def test_a_broken_pipe_carries_its_reason
    flow = Wurk::Flow.chain do |c|
      c.job("Head#{@ns}", queue: @queue)
      c.job("Tail#{@ns}", queue: @queue)
    end.run
    advance(flow, 0)

    status = Wurk::Flow::Status.new(flow.fid)
    tail = status.nodes[1]

    assert_equal 'broken', tail.state
    assert_predicate tail, :piped?
    assert_includes tail.error, 'piped result is missing'
    assert_equal [1], status.dead_indexes
    assert_predicate status, :failed?
  end

  def test_abandonment_leaves_a_header_and_no_nodes
    flow = diamond

    assert Wurk::Flow.abandon(flow.fid)

    status = Wurk::Flow::Status.new(flow.fid)

    assert_predicate status, :exists?
    assert_predicate status, :abandoned?
    assert_predicate status, :terminal?
    assert_in_delta Time.now.to_f, status.abandoned_at, 5.0
    assert_empty status.nodes
    assert_empty status.dead_indexes
  end

  # A read that raises takes the whole graph — and the page rendering it — down
  # over one field nothing here wrote.
  def test_a_corrupt_edge_list_reads_as_no_edges_rather_than_raising
    flow = diamond
    Wurk.redis { |conn| conn.call('HSET', Wurk::Keys.flow_node(flow.fid, 2), 'deps', 'not json') }

    node = Wurk::Flow::Status.new(flow.fid).nodes[2]

    assert_empty node.dependencies
    assert_equal 'waiting', node.state
  end

  def test_a_corrupt_timestamp_reads_as_no_timestamp
    flow = diamond
    Wurk.redis { |conn| conn.call('HSET', Wurk::Keys.flow(flow.fid), 'created_at', 'yesterday') }

    assert_nil Wurk::Flow::Status.new(flow.fid).created_at
  end

  def test_data_is_json_serializable_and_carries_the_nodes
    flow = diamond

    payload = JSON.parse(JSON.generate(Wurk::Flow::Status.new(flow.fid).data))

    assert_equal flow.fid, payload['fid']
    assert_equal 'running', payload['state']
    assert_equal 3, payload['nodes'].size
    assert_equal [0, 1], payload['nodes'][2]['depends_on']
    assert_nil payload['nodes'][0]['error']
  end

  def test_reload_picks_up_a_move_the_snapshot_predates
    flow = diamond
    status = Wurk::Flow::Status.new(flow.fid)

    assert_equal 3, status.pending
    advance(flow, 0)
    status.reload!

    assert_equal 2, status.pending
    assert_equal 'succeeded', status.nodes[0].state
  end

  # --- FlowSet -----------------------------------------------------------

  def test_flow_set_yields_created_flows_newest_first
    older = diamond
    newer = Wurk::Flow.new { |f| f.job("Solo#{@ns}", queue: @queue) }.run

    fids = Wurk::FlowSet.new.map(&:fid)

    assert_equal 2, Wurk::FlowSet.new.size
    assert_equal [newer.fid, older.fid], fids
    assert(Wurk::FlowSet.new.all?(Wurk::Flow::Status))
  end

  def test_flow_set_each_without_a_block_is_an_enumerator
    diamond

    assert_kind_of Enumerator, Wurk::FlowSet.new.each
    assert_equal 1, Wurk::FlowSet.new.each.to_a.size
  end

  # Seeded straight into the index, which also covers the documented case of a
  # member whose record has expired out from under it: the walk yields a status
  # that says so rather than silently shortening the page.
  def test_flow_set_pages_past_its_page_size
    fids = Array.new(Wurk::FlowSet::PAGE_SIZE + 2) { |i| "paged-#{@ns}-#{i}" }
    Wurk.redis { |conn| fids.each_with_index { |fid, score| conn.call('ZADD', Wurk::Keys::FLOWS_SET, score, fid) } }

    walked = Wurk::FlowSet.new.to_a

    assert_equal fids.size, Wurk::FlowSet.new.size
    assert_equal fids.reverse, walked.map(&:fid)
    refute(walked.any?(&:exists?))
  end

  private

  # A,B → C. The graph every decision in slice 11 is argued over.
  def diamond
    Wurk::Flow.new do |f|
      a = f.job("Alpha#{@ns}", queue: @queue)
      b = f.job("Beta#{@ns}", queue: @queue)
      f.job("Merge#{@ns}", name: :merge, depends_on: [a, b], queue: @queue)
    end.run
  end

  # The real callback, so the real script decides what moves.
  def advance(flow, index)
    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => index })
  end
end

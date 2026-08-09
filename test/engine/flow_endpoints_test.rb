# frozen_string_literal: true

require_relative '../engine_test_helper'

# Slice 11 — the dashboard's flow endpoints: `GET /api/flows`,
# `GET /api/flows/:fid` and the `POST /api/flows/:fid/abandon` kill switch.
#
# Fixtures are real flows built by Wurk::Flow#run and moved by the real
# completion callbacks, because the wire shape these tests pin is only worth
# anything if it is the state the writers actually produce.
#
# Like the other engine suites, we talk to the engine through Rack::Test and
# read `last_response` directly. Engine tests share a Redis DB rather than
# flushing it, so every flow this creates is torn down by fid in teardown.
#
# The read-only case flips the process-wide `Wurk::Web.config`, so — like
# api_read_only_test.rb — this class does not declare `parallelize_me!` and
# serializes its own methods through GLOBAL_STATE_MUTEX.
class FlowEndpointsTest < Wurk::Test::EngineCase
  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  def setup
    super
    # SameOriginGuard 403s unsafe methods lacking this header; a same-origin SPA
    # fetch always sends it, so default it for the abandon POSTs below.
    header 'Sec-Fetch-Site', 'same-origin'
    @ns = "wurkflow:#{::Process.pid}:#{object_id}"
    @queue = "#{@ns}-q"
    @flows = []
  end

  def teardown
    ::Wurk.redis do |conn|
      @flows.each { |flow| release(conn, flow) }
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
    end
    ::Wurk::Web.reset_config!
  ensure
    super
  end

  def test_flows_listing_carries_the_envelope_and_a_row_per_flow
    flow = diamond
    get '/wurk/api/flows'

    assert_ok
    payload = json_body

    assert_equal 0, payload[:page]
    row = payload[:flows].find { |f| f[:fid] == flow.fid }

    refute_nil row, 'expected the created flow in the listing'
    assert_equal({ state: 'running', total: 3, pending: 3, succeeded: 0, depth: 2, width: 2 },
                 row.slice(:state, :total, :pending, :succeeded, :depth, :width))
    refute_nil row[:created_at]
  end

  # The listing walks headers only — a page of flows must not pay for every
  # node record it is not going to render.
  def test_flows_listing_rows_carry_no_node_graph
    diamond
    get '/wurk/api/flows'

    assert_ok
    refute(json_body[:flows].any? { |row| row.key?(:nodes) })
  end

  def test_flow_detail_carries_the_graph
    flow = diamond
    get "/wurk/api/flows/#{flow.fid}"

    assert_ok
    payload = json_body

    assert_equal flow.fid, payload[:fid]
    assert_equal 'running', payload[:state]
    assert_equal 3, payload[:nodes].size
    assert_equal([0, 1, 2], payload[:nodes].map { |n| n[:index] })
    assert_equal([[], [], [0, 1]], payload[:nodes].map { |n| n[:depends_on] })
    assert_equal(%w[enqueued enqueued waiting], payload[:nodes].map { |n| n[:state] })
    assert_equal(flow.bids, payload[:nodes].map { |n| n[:bid] })
    assert_empty payload[:dead_nodes]
  end

  def test_flow_detail_follows_a_node_completing
    flow = diamond
    advance(flow, 0)
    get "/wurk/api/flows/#{flow.fid}"

    assert_ok
    payload = json_body

    assert_equal 1, payload[:succeeded]
    assert_equal(%w[succeeded enqueued waiting], payload[:nodes].map { |n| n[:state] })
  end

  def test_flow_detail_surfaces_a_broken_link_and_its_reason
    flow = chain
    advance(flow, 0)
    get "/wurk/api/flows/#{flow.fid}"

    assert_ok
    payload = json_body

    assert_equal 'failed', payload[:state]
    assert_equal [1], payload[:dead_nodes]
    assert_equal 'broken', payload[:nodes].last[:state]
    assert payload[:nodes].last[:piped]
    assert_includes payload[:nodes].last[:error], 'piped result is missing'
  end

  def test_flow_detail_unknown_fid_returns_404
    get "/wurk/api/flows/no-such-flow-#{::Process.pid}"

    assert_equal 404, last_response.status
    assert_equal 'unknown flow', json_body[:error]
  end

  def test_abandon_marks_the_flow_and_releases_its_nodes
    flow = diamond
    post "/wurk/api/flows/#{flow.fid}/abandon"

    assert_ok
    assert json_body[:abandoned]

    status = ::Wurk::Flow::Status.new(flow.fid)

    assert_predicate status, :abandoned?
    assert_empty status.nodes
  end

  # The script claims on a live flow, so a second call is a no-op rather than a
  # second decision with a fresher timestamp.
  def test_abandoning_twice_reports_the_second_call_did_nothing
    flow = diamond
    post "/wurk/api/flows/#{flow.fid}/abandon"

    assert_ok
    at = ::Wurk::Flow::Status.new(flow.fid).abandoned_at

    post "/wurk/api/flows/#{flow.fid}/abandon"

    assert_ok
    refute json_body[:abandoned]
    assert_in_delta at, ::Wurk::Flow::Status.new(flow.fid).abandoned_at, 0.0001
  end

  def test_abandon_unknown_fid_returns_404
    post "/wurk/api/flows/no-such-flow-#{::Process.pid}/abandon"

    assert_equal 404, last_response.status
    assert_equal 'unknown flow', json_body[:error]
  end

  def test_read_only_blocks_abandon
    ::Wurk::Web.configure { |c| c.read_only = true }
    flow = diamond
    post "/wurk/api/flows/#{flow.fid}/abandon"

    assert_equal 403, last_response.status
    assert_predicate ::Wurk::Flow::Status.new(flow.fid), :running?, 'read-only must not mutate'
  end

  private

  def diamond
    track(::Wurk::Flow.new do |f|
      a = f.job("FlowAlpha#{@ns}", queue: @queue)
      b = f.job("FlowBeta#{@ns}", queue: @queue)
      f.job("FlowMerge#{@ns}", name: :merge, depends_on: [a, b], queue: @queue)
    end.run)
  end

  def chain
    track(::Wurk::Flow.chain do |c|
      c.job("FlowHead#{@ns}", queue: @queue)
      c.job("FlowTail#{@ns}", queue: @queue)
    end.run)
  end

  def track(flow)
    @flows << flow
    flow
  end

  def advance(flow, index)
    ::Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => index })
  end

  # Abandonment already drops the node keys and batches; this is the same sweep
  # for the flows the test never abandoned, plus the record abandonment keeps.
  def release(conn, flow)
    ::Wurk::Flow.abandon(flow.fid)
    conn.call('DEL', ::Wurk::Keys.flow(flow.fid))
    conn.call('ZREM', ::Wurk::Keys::FLOWS_SET, flow.fid)
    flow.jids.each_index { |i| conn.call('DEL', ::Wurk::Keys.flow_node(flow.fid, i)) }
  end

  def json_body = ::JSON.parse(last_response.body, symbolize_names: true)

  def assert_ok
    assert_equal 200, last_response.status, "non-200 response: body=#{last_response.body[0, 500]}"
  end
end

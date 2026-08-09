# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'stringio'

# Slice 11 — `GET /v1/flows/:fid`, the machine API's whole flow surface.
#
# Fixtures are real flows created by Wurk::Flow#run and moved by the real
# completion callbacks: the route reads through Wurk::Flow::Status, and the
# thing worth pinning is that the HTTP answer is the one that inspector gives.
#
# Auth mechanics live in api_auth_test.rb and routing in api_app_test.rb; the
# scope checks here only pin which scope this route demands.
class ApiFlowsTest < Wurk::Test::UnitCase
  parallelize_me!

  ADMIN_TOKEN = 'api-flows-admin-token-0123456789'
  READ_TOKEN = 'api-flows-read-token-0123456789'
  ENQUEUE_TOKEN = 'api-flows-enqueue-token-0123456789'

  def setup
    super
    @ns = "#{Process.pid}_#{object_id}"
    @queue = "flowq-#{@ns}"
  end

  def test_reports_the_header_and_the_whole_graph
    flow = diamond

    status, headers, body = get("/v1/flows/#{flow.fid}", token: READ_TOKEN)

    assert_equal 200, status
    assert_equal 'application/json', headers['content-type']
    assert_equal flow.fid, body['fid']
    assert_equal 'running', body['state']
    refute body['terminal']
    assert_equal({ 'total' => 3, 'pending' => 3, 'succeeded' => 0, 'depth' => 2, 'width' => 2 },
                 body.slice('total', 'pending', 'succeeded', 'depth', 'width'))
    assert_empty body['dead_nodes']
    assert_equal(flow.jids, body['nodes'].map { |node| node['jid'] })
    assert_equal(flow.bids, body['nodes'].map { |node| node['bid'] })
  end

  def test_a_node_row_carries_its_edges_and_state
    flow = diamond

    _, _, body = get("/v1/flows/#{flow.fid}", token: READ_TOKEN)
    merge = body['nodes'].last

    assert_equal 2, merge['index']
    assert_equal 'merge', merge['name']
    assert_equal "Merge#{@ns}", merge['class']
    assert_equal @queue, merge['queue']
    assert_equal 'waiting', merge['state']
    assert_equal [0, 1], merge['depends_on']
    assert_empty merge['dependents']
    assert_equal 2, merge['remaining']
    refute merge['piped']
    assert_nil merge['error']
  end

  def test_progress_follows_the_completion_callback
    flow = diamond
    advance(flow, 0)

    _, _, body = get("/v1/flows/#{flow.fid}", token: READ_TOKEN)

    assert_equal 2, body['pending']
    assert_equal 1, body['succeeded']
    assert_equal(%w[succeeded enqueued waiting], body['nodes'].map { |node| node['state'] })
  end

  def test_a_broken_chain_link_publishes_its_reason
    flow = Wurk::Flow.chain do |c|
      c.job("Head#{@ns}", queue: @queue)
      c.job("Tail#{@ns}", queue: @queue)
    end.run
    advance(flow, 0)

    _, _, body = get("/v1/flows/#{flow.fid}", token: READ_TOKEN)
    tail = body['nodes'].last

    assert_equal 'failed', body['state']
    assert_equal [1], body['dead_nodes']
    assert_equal 'broken', tail['state']
    assert tail['piped']
    assert_includes tail['error'], 'piped result is missing'
  end

  def test_an_abandoned_flow_reports_its_header_and_no_nodes
    flow = diamond
    Wurk::Flow.abandon(flow.fid)

    _, _, body = get("/v1/flows/#{flow.fid}", token: READ_TOKEN)

    assert_equal 'abandoned', body['state']
    assert body['terminal']
    assert_empty body['nodes']
    refute_nil body['abandoned_at']
  end

  def test_unknown_fid_is_a_flow_not_found_problem
    status, headers, body = get("/v1/flows/no-such-flow-#{@ns}", token: READ_TOKEN)

    assert_equal 404, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'flow_not_found', body['type']
    assert_equal 'Flow Not Found', body['title']
    assert_equal "no-such-flow-#{@ns}", body['fid']
    assert_includes body['detail'], 'expired'
  end

  # A fid interpolates into a key name, so the shape is checked before the read.
  def test_a_malformed_fid_is_refused_before_redis
    status, _, body = get('/v1/flows/not%20a%20fid', token: READ_TOKEN)

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], 'flow id'
  end

  def test_reading_needs_the_read_scope
    flow = diamond

    assert_equal 403, get("/v1/flows/#{flow.fid}", token: ENQUEUE_TOKEN).first
    assert_equal 200, get("/v1/flows/#{flow.fid}", token: READ_TOKEN).first
    assert_equal 200, get("/v1/flows/#{flow.fid}", token: ADMIN_TOKEN).first
  end

  # Deliberate: a producer holds the fid of the flow it created, and browsing
  # or killing flows is an operator action the dashboard owns.
  def test_there_is_no_listing_and_no_write
    assert_equal 404, get('/v1/flows', token: ADMIN_TOKEN).first

    flow = diamond
    status, headers, body = request('POST', "/v1/flows/#{flow.fid}/abandon", token: ADMIN_TOKEN)

    assert_equal 404, status
    assert_equal 'not_found', body['type']
    assert_nil headers['allow']
    assert_predicate Wurk::Flow::Status.new(flow.fid), :running?
  end

  def test_the_verb_table_for_a_flow_is_get_only
    flow = diamond

    status, headers, = request('DELETE', "/v1/flows/#{flow.fid}", token: ADMIN_TOKEN)

    assert_equal 405, status
    assert_equal 'GET, HEAD', headers['allow']
  end

  private

  def diamond
    Wurk::Flow.new do |f|
      a = f.job("Alpha#{@ns}", queue: @queue)
      b = f.job("Beta#{@ns}", queue: @queue)
      f.job("Merge#{@ns}", name: :merge, depends_on: [a, b], queue: @queue)
    end.run
  end

  def advance(flow, index)
    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => index })
  end

  def app = @app ||= Wurk::API::App.new(config: config)

  def config
    @config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
      cfg.api_token(READ_TOKEN, scopes: %i[read])
      cfg.api_token(ENQUEUE_TOKEN, scopes: %i[enqueue])
    end
  end

  def get(path, token: ADMIN_TOKEN) = request('GET', path, token: token)

  def request(method, path, token:)
    info, _, query = path.partition('?')
    status, headers, body = app.call(env_for(method, info, query: query, token: token))
    [status, headers, JSON.parse(body.join)]
  end

  def env_for(method, path, query: '', token: ADMIN_TOKEN)
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => query,
      'rack.input' => StringIO.new,
      'rack.errors' => StringIO.new,
      'HTTP_AUTHORIZATION' => "Bearer #{token}"
    }
  end
end

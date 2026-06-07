# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives the Sidekiq::Pro::BatchStatus polling middleware (#116) against real
# Redis. Mounts it in a bare Rack stack and asserts the JSON shape, the 404 on
# unknown bid, and pass-through for unrelated requests.
class WebBatchStatusTest < Wurk::Test::UnitCase
  parallelize_me!

  # Inner app records whether it was reached and echoes a sentinel body.
  APP = lambda do |_env|
    [200, { 'content-type' => 'text/plain' }, ['downstream']]
  end

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @bid  = "wbs-#{Process.pid}-#{object_id}"
    @mw   = Sidekiq::Pro::BatchStatus.new(APP)
  end

  def teardown
    @pool.with { |c| c.call('UNLINK', *Wurk::Batch.keys_for(@bid)) }
  ensure
    super
  end

  def test_alias_resolves_to_web_batch_status
    assert_same Wurk::Web::BatchStatus, Sidekiq::Pro::BatchStatus
  end

  def test_serves_status_json_for_known_bid
    @pool.with { |c| c.call('HSET', "b-#{@bid}", 'total', 3, 'pending', 1, 'description', 'import') }

    code, headers, body = @mw.call(rack_env("/batch_status/#{@bid}.json"))
    payload = JSON.parse(body.join)

    assert_equal 200, code
    assert_equal 'application/json', headers['content-type']
    assert_equal @bid, payload['bid']
    assert_equal 3, payload['total']
    assert_equal 1, payload['pending']
    assert_equal 'import', payload['description']
  end

  def test_includes_failures_and_failed_jids
    @pool.with do |c|
      c.call('HSET', "b-#{@bid}", 'total', 2, 'pending', 2, 'failures', 1)
      c.call('SADD', "b-#{@bid}-failed", 'jid1')
    end

    _code, _headers, body = @mw.call(rack_env("/batch_status/#{@bid}.json"))
    payload = JSON.parse(body.join)

    assert_equal 1, payload['failures']
    assert_equal ['jid1'], payload['failed_jids']
  end

  def test_404_for_unknown_bid
    code, _headers, body = @mw.call(rack_env('/batch_status/does-not-exist.json'))

    assert_equal 404, code
    assert_equal 'not_found', JSON.parse(body.join)['error']
  end

  def test_passes_through_unrelated_paths
    code, _headers, body = @mw.call(rack_env('/some/other/path'))

    assert_equal 200, code
    assert_equal 'downstream', body.join
  end

  def test_passes_through_non_get_methods
    @pool.with { |c| c.call('HSET', "b-#{@bid}", 'total', 1) }

    _code, _headers, body = @mw.call(rack_env("/batch_status/#{@bid}.json", method: 'POST'))

    assert_equal 'downstream', body.join
  end

  private

  def rack_env(path, method: 'GET')
    { 'REQUEST_METHOD' => method, 'PATH_INFO' => path }
  end
end

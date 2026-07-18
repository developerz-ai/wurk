# frozen_string_literal: true

require_relative '../engine_test_helper'

# Proves a Redis blip surfacing inside an engine action renders as a
# structured, retryable signal instead of Rails' generic 500 error page
# (#101 debrief: the SPA needs something to branch on, not a backtrace).
#
# Forces the failure at the `Wurk::Api::Serializers.stats_payload` boundary —
# the one place both the plain JSON `#stats` action and the SSE `#stream`
# tick read Redis — rather than mocking the Redis client itself (never mock
# Redis in engine/integration tests; this simulates the *exception class*
# RedisPool already raises after exhausting its own retries, not the
# transport).
class RedisUnavailableTest < Wurk::Test::EngineCase
  parallelize_me!

  def test_json_action_returns_structured_503_on_redis_error
    with_stats_payload_raising(RedisClient::CannotConnectError.new('boom')) do
      get '/wurk/api/stats'
    end

    assert_equal 503, last_response.status
    assert_equal 'redis_unavailable', json_body[:error]
  end

  def test_json_action_returns_structured_503_on_pool_timeout
    with_stats_payload_raising(ConnectionPool::TimeoutError.new('boom')) do
      get '/wurk/api/stats'
    end

    assert_equal 503, last_response.status
    assert_equal 'redis_unavailable', json_body[:error]
  end

  # Headers are already flushed by the time an SSE tick hits Redis, so the
  # stream can't switch to a 503 status — it emits a structured `error` event
  # and closes instead of dying mid-stream with a raw exception.
  def test_stream_emits_structured_error_event_on_redis_error
    with_stats_payload_raising(RedisClient::CannotConnectError.new('boom')) do
      get '/wurk/api/stream?max_duration=0&tick=0'
    end

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'event: error'
    assert_equal 'redis_unavailable', stream_event_payload['error']
  end

  private

  def stream_event_payload
    payload_line = last_response.body.lines.find { |l| l.start_with?('data: ') }
    ::JSON.parse(payload_line.delete_prefix('data: '))
  end

  def with_stats_payload_raising(error)
    original = ::Wurk::Api::Serializers.method(:stats_payload)
    ::Wurk::Api::Serializers.define_singleton_method(:stats_payload) { |*| raise error }
    yield
  ensure
    ::Wurk::Api::Serializers.define_singleton_method(:stats_payload, original)
  end

  def json_body
    ::JSON.parse(last_response.body, symbolize_names: true)
  end
end

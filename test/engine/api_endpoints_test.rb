# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives Wurk::ApiController against the booted dummy app. The dashboard
# wire-shape is the contract for every frontend page (Task #49+); these
# tests assert each endpoint's JSON keys match what the SPA queries against.
#
# We talk to the engine via Rack::Test (the helper mixes it into EngineCase),
# so all assertions read `last_response` directly — `assert_response` relies on
# ActionDispatch's `@response` ivar which Rack::Test does not populate.
class ApiEndpointsTest < Wurk::Test::EngineCase
  parallelize_me!

  def setup
    super
    @ns = "wurkapi:#{::Process.pid}:#{object_id}"
    @queue = "#{@ns}-q"
    @class_name = "ApiEndpointJob@#{@ns}"
    @pool = ::Wurk.configuration.redis_pool
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
      cleanup_zset(conn, 'retry')
      cleanup_zset(conn, 'schedule')
      cleanup_zset(conn, 'dead')
    end
  ensure
    super
  end

  STATS_KEYS = %i[
    processed failed expired enqueued busy scheduled retries dead
    processes latency queues
  ].freeze

  def test_stats_payload_includes_every_documented_key
    get '/wurk/api/stats'

    assert_ok
    assert_equal STATS_KEYS.sort, (json_body.keys & STATS_KEYS).sort
  end

  def test_stats_payload_uses_numeric_types
    get '/wurk/api/stats'
    payload = json_body

    assert_kind_of Float, payload[:latency]
  end

  def test_stats_payload_includes_queues_array
    push_to_queue
    get '/wurk/api/stats'
    payload = json_body

    assert_kind_of Array, payload[:queues]
    row = payload[:queues].find { |q| q[:name] == @queue }

    refute_nil row, "expected queue #{@queue} embedded in stats payload"
    assert_equal({ size: 1, paused: false }, row.slice(:size, :paused))
    assert_kind_of Numeric, row[:latency]
  end

  def test_queues_returns_array_of_summaries
    push_to_queue
    get '/wurk/api/queues'

    assert_ok
    row = json_body.find { |q| q[:name] == @queue }

    refute_nil row, "expected queue #{@queue} in response"
    assert_equal({ name: @queue, size: 1, paused: false }, row.slice(:name, :size, :paused))
  end

  def test_queue_returns_jobs_page_envelope
    push_to_queue
    get "/wurk/api/queues/#{@queue}?count=10&page=0"

    assert_ok
    assert_equal({ name: @queue, size: 1, page: 0, count: 10 }, json_body.slice(:name, :size, :page, :count))
  end

  def test_queue_returns_job_record_with_canonical_fields
    jid = push_to_queue
    get "/wurk/api/queues/#{@queue}"
    job = json_body[:jobs].first

    assert_equal({ jid: jid, klass: @class_name, queue: @queue }, job.slice(:jid, :klass, :queue))
  end

  def test_queue_substr_filter
    push_to_queue
    get "/wurk/api/queues/#{@queue}?substr=does-not-match-anything-xyz"

    assert_ok
    assert_empty json_body[:jobs]
  end

  def test_retries_returns_paged_envelope
    push_to_zset('retry')
    get '/wurk/api/retries?count=5'

    assert_ok
    entry = json_body[:entries].find { |e| e[:klass] == @class_name }

    refute_nil entry
    assert_kind_of Float, entry[:score]
  end

  def test_scheduled_returns_paged_envelope
    push_to_zset('schedule')
    get '/wurk/api/scheduled'

    assert_ok
    payload = json_body

    assert_operator payload[:total], :>=, 1
    assert(payload[:entries].any? { |e| e[:klass] == @class_name })
  end

  def test_dead_returns_paged_envelope
    push_to_zset('dead')
    get '/wurk/api/dead'

    assert_ok
    payload = json_body

    assert_operator payload[:total], :>=, 1
    assert(payload[:entries].any? { |e| e[:klass] == @class_name })
  end

  def test_processes_returns_array
    get '/wurk/api/processes'

    assert_ok
    assert_kind_of Array, json_body
  end

  def test_batches_envelope
    get '/wurk/api/batches'

    assert_ok
    payload = json_body

    assert_kind_of Array, payload[:batches]
    assert_equal 0, payload[:page]
  end

  def test_limiters_array # rubocop:disable Minitest/MultipleAssertions
    name = seed_limiter
    get '/wurk/api/limiters'

    assert_ok
    row = json_body.find { |r| r[:name] == name }

    assert_equal({ name: name, type: 'concurrent' }, row.slice(:name, :type))
    # #16: each limiter row carries its uniform live status (concurrent
    # additionally merges its metric counters, so assert a subset).
    status = row[:status]

    refute_nil status, 'limiter row should include a status'
    %i[used limit reset_at available?].each { |k| assert status.key?(k), "status missing #{k}" }
  ensure
    cleanup_limiter(name)
  end

  def test_cron_array
    lid = seed_cron_loop
    get '/wurk/api/cron'

    assert_ok
    row = json_body.find { |r| r[:lid] == lid }

    assert_equal(
      { schedule: '* * * * *', klass: @class_name, queue: 'default' },
      row.slice(:schedule, :klass, :queue)
    )
  ensure
    cleanup_cron_loop(lid)
  end

  def test_metrics_returns_top_jobs
    get '/wurk/api/metrics?minutes=5'

    assert_ok
    payload = json_body

    assert_equal 5, payload[:minutes]
    assert_kind_of Array, payload[:top_jobs]
  end

  def test_metrics_clamps_oversize_window
    get '/wurk/api/metrics?minutes=99999'

    assert_ok
    assert_equal ::Wurk::Metrics::Query::MAX_MINUTES, json_body[:minutes]
  end

  # The SSE stream emits one `event: stats` tick and closes when
  # `?max_duration=0` is supplied. Production callers omit the param and the
  # loop runs until `STREAM_MAX_DURATION`.
  def test_stream_sets_sse_headers
    get '/wurk/api/stream?max_duration=0&tick=0'

    assert_match %r{text/event-stream}, last_response.content_type.to_s
    assert_equal 'no-cache', last_response.headers['Cache-Control']
  end

  def test_stream_emits_stats_event_with_payload
    get '/wurk/api/stream?max_duration=0&tick=0'
    payload_line = last_response.body.lines.find { |l| l.start_with?('data: ') }
    decoded = ::JSON.parse(payload_line.delete_prefix('data: '))

    assert_includes last_response.body, 'event: stats'
    assert decoded.key?('processed'), "decoded payload missing :processed key, got #{decoded.keys.inspect}"
  end

  private

  def json_body
    ::JSON.parse(last_response.body, symbolize_names: true)
  end

  def assert_ok
    assert_equal 200, last_response.status, "non-200 response: body=#{last_response.body[0, 500]}"
  end

  def push_to_queue
    payload = job_payload
    ::Wurk.redis do |c|
      c.call('SADD', 'queues', @queue)
      c.call('LPUSH', "queue:#{@queue}", ::Wurk.dump_json(payload))
    end
    payload['jid']
  end

  def push_to_zset(name)
    payload = job_payload
    ::Wurk.redis do |c|
      c.call('ZADD', name, ::Time.now.to_f.to_s, ::Wurk.dump_json(payload))
    end
    payload['jid']
  end

  def job_payload
    {
      'class' => @class_name,
      'args' => [1, 2],
      'queue' => @queue,
      'jid' => SecureRandom.hex(12),
      'created_at' => ::Time.now.to_f,
      'enqueued_at' => ::Time.now.to_f,
      'retry_count' => 0,
      'error_class' => 'RuntimeError',
      'error_message' => 'boom'
    }
  end

  def seed_limiter
    name = "lmt-#{@ns}"
    ::Wurk.redis do |c|
      c.call('SADD', ::Wurk::Limiter::LIST_KEY, name)
      c.call('HSET', "lmtr:#{name}", 'type', 'concurrent', 'fingerprint', 'fp', 'options', '{"limit":5}')
    end
    name
  end

  def cleanup_limiter(name)
    ::Wurk.redis do |c|
      c.call('SREM', ::Wurk::Limiter::LIST_KEY, name)
      c.call('DEL', "lmtr:#{name}")
    end
  end

  def seed_cron_loop
    lid = "lid-#{@ns}"[0, 16]
    ::Wurk.redis do |c|
      c.call('SADD', ::Wurk::Cron::PERIODIC_KEY, lid)
      c.call(
        'HSET', "#{::Wurk::Cron::LOOP_PREFIX}#{lid}",
        'schedule', '* * * * *',
        'klass', @class_name,
        'options', '{}',
        'tz', '',
        'paused', '0'
      )
    end
    lid
  end

  def cleanup_cron_loop(lid)
    ::Wurk.redis do |c|
      c.call('SREM', ::Wurk::Cron::PERIODIC_KEY, lid)
      c.call('DEL', "#{::Wurk::Cron::LOOP_PREFIX}#{lid}")
    end
  end

  def cleanup_zset(conn, key)
    conn.call('ZRANGEBYSCORE', key, '-inf', '+inf').each do |raw|
      parsed = begin
        ::Wurk.load_json(raw)
      rescue ::JSON::ParserError
        nil
      end
      next unless parsed.is_a?(Hash) && parsed['class'] == @class_name

      conn.call('ZREM', key, raw)
    end
  end
end

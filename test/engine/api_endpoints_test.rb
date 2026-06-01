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

  def test_batches_row_carries_status_and_progress # rubocop:disable Minitest/MultipleAssertions
    bid = seed_batch
    get '/wurk/api/batches'

    assert_ok
    row = json_body[:batches].find { |b| b[:bid] == bid }

    refute_nil row, 'expected seeded batch in list'
    assert_equal({ bid: bid, total: 10, pending: 4, failures: 1 }, row.slice(:bid, :total, :pending, :failures))
    refute row[:complete]
  ensure
    cleanup_batch(bid)
  end

  def test_batch_detail_by_bid # rubocop:disable Minitest/MultipleAssertions
    bid = seed_batch
    get "/wurk/api/batches/#{bid}"

    assert_ok
    payload = json_body

    assert_equal bid, payload[:bid]
    assert_equal 10, payload[:total]
    assert_equal 'Nightly export', payload[:description]
    assert_kind_of Array, payload[:failed_jids]
  ensure
    cleanup_batch(bid)
  end

  def test_batch_detail_unknown_bid_returns_404
    get "/wurk/api/batches/no-such-batch-#{@ns}"

    assert_equal 404, last_response.status
    assert_equal 'unknown batch', json_body[:error]
  end

  def test_limiters_envelope
    name = seed_limiter
    get '/wurk/api/limiters'

    assert_ok
    row = json_body[:limiters].find { |r| r[:name] == name }

    assert_equal({ name: name, type: 'concurrent' }, row.slice(:name, :type))
    # #16: each row carries the uniform live status keys (concurrent merges
    # extra metric counters on top; asserted in the counters test).
    assert_equal(%i[available? limit reset_at used],
                 row[:status].slice(:used, :limit, :reset_at, :available?).keys.sort)
  ensure
    cleanup_limiter(name)
  end

  def test_limiter_row_carries_concurrent_status_counters
    name = seed_limiter
    ::Wurk.redis { |c| c.call('HSET', "lmtr-stats:#{name}", 'held', '3', 'immediate', '120', 'overages', '2') }
    get '/wurk/api/limiters'

    assert_ok
    status = json_body[:limiters].find { |r| r[:name] == name }[:status]

    assert_equal({ held: 3, immediate: 120, overages: 2, reclaimed: 0 },
                 status.slice(:held, :immediate, :overages, :reclaimed))
  ensure
    ::Wurk.redis { |c| c.call('DEL', "lmtr-stats:#{name}") }
    cleanup_limiter(name)
  end

  def test_limiters_pagination_second_page_offsets
    names = (0..2).map { |i| seed_limiter(i.to_s) }
    first = limiter_page_names(0)
    second = limiter_page_names(1)

    assert_equal 2, first.size
    assert_empty(first & second)
  ensure
    names&.each { |n| cleanup_limiter(n) }
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

  def test_cron_row_carries_last_fire_at
    lid = seed_cron_loop
    fired_at = ::Time.now.to_i - 30
    push_fire_history(lid, fired_at)
    get '/wurk/api/cron'

    assert_ok
    row = json_body.find { |r| r[:lid] == lid }

    assert_equal fired_at, row[:last_fire_at]
  ensure
    ::Wurk.redis { |c| c.call('DEL', "#{::Wurk::Cron::HISTORY_PREFIX}#{lid}") }
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

  def test_history_returns_recharts_series
    epoch = ((::Time.now.to_i / 60) * 60) - 60
    ::Wurk.redis { |c| c.call('HSET', "jr|1m|#{epoch}", 'p', 12, 'f', 3, 'ms', 400) }
    get '/wurk/api/history/1m?window=10m'

    assert_ok
    point = json_body[:series].find { |row| row[:at] == epoch }

    assert_equal({ at: epoch, processed: 12, failed: 3, runtime_ms: 400 }, point)
  ensure
    ::Wurk.redis { |c| c.call('DEL', "jr|1m|#{epoch}") }
  end

  def test_history_rejects_unknown_bucket
    get '/wurk/api/history/2m?window=1h'

    assert_equal 400, last_response.status
    assert_match(/bucket/, json_body[:error])
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

  def push_fire_history(lid, fired_at)
    ::Wurk.redis do |c|
      c.call('LPUSH', "#{::Wurk::Cron::HISTORY_PREFIX}#{lid}", ::Wurk.dump_json([fired_at, 'abc123']))
    end
  end

  def seed_batch
    bid = "bid-#{@ns}"[0, 24]
    ::Wurk.redis do |c|
      c.call('ZADD', 'batches', ::Time.now.to_f.to_s, bid)
      c.call(
        'HSET', "b-#{bid}",
        'total', '10', 'pending', '4', 'failures', '1',
        'created_at', ::Time.now.to_f.to_s, 'description', 'Nightly export'
      )
      # Status#complete? recomputes from the live jids set when the `complete`
      # field is absent; seed live jids so the batch reads as in-progress.
      c.call('SADD', "b-#{bid}-jids", 'j1', 'j2', 'j3', 'j4')
    end
    bid
  end

  def cleanup_batch(bid)
    ::Wurk.redis do |c|
      c.call('ZREM', 'batches', bid)
      c.call('DEL', "b-#{bid}", "b-#{bid}-jids", "b-#{bid}-failed", "b-#{bid}-died", "b-#{bid}-kids")
    end
  end

  def seed_limiter(suffix = '')
    name = "lmt-#{@ns}#{suffix}"
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

  def limiter_page_names(page)
    get "/wurk/api/limiters?page=#{page}&count=2"

    assert_ok
    json_body[:limiters].map { |r| r[:name] }
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

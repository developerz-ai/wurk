# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives the Pro/Ent web extensions through the engine: search + cron
# pause/unpause/enqueue/history + limiter reset + per-class metrics.
# The wire shape here is what the SPA's Limits / Periodic / Historical
# tabs render against.
class WebExtensionsTest < Wurk::Test::EngineCase
  def setup
    super
    @ns = "wurkwebx:#{Process.pid}:#{object_id}"
    @queue = "#{@ns}-q"
    @class_name = "WebExtJob@#{@ns}"
    @needle = "needle-#{@ns}"
    @limiter = "lmt-#{@ns}"
    @lid = ::Digest::SHA1.hexdigest(@ns)[0, 16]
  end

  def teardown
    Wurk.redis do |c|
      c.call('DEL', "queue:#{@queue}")
      c.call('SREM', 'queues', @queue)
      cleanup_zset(c, 'retry')
      cleanup_zset(c, 'schedule')
      cleanup_zset(c, 'dead')
      c.call('SREM', Wurk::Limiter::LIST_KEY, @limiter)
      %W[lmtr:#{@limiter} lmtr-stats:#{@limiter} lmtr-cs:#{@limiter}].each { |k| c.call('DEL', k) }
      c.call('SREM', Wurk::Cron::PERIODIC_KEY, @lid)
      c.call('DEL', "#{Wurk::Cron::LOOP_PREFIX}#{@lid}", "#{Wurk::Cron::HISTORY_PREFIX}#{@lid}")
    end
  ensure
    super
  end

  # --- Search -----------------------------------------------------------

  def test_search_empty_substr_returns_empty_hits
    get '/wurk/api/search'

    assert_ok
    assert_equal 0, json_body[:total]
    assert_empty json_body[:hits]
  end

  def test_search_finds_queue_hit
    push_to_queue([@needle])
    get "/wurk/api/search?substr=#{@needle}"

    assert_ok
    refute_empty json_body[:hits]
    assert_equal @needle, json_body[:substr]
  end

  def test_search_kinds_filter
    push_to_zset('retry', [@needle])
    push_to_zset('dead', [@needle])
    get "/wurk/api/search?substr=#{@needle}&kinds=retry"

    assert_ok
    kinds = json_body[:hits].map { |h| h[:kind] }.uniq

    assert_equal ['retry'], kinds
  end

  # --- Limiter reset ----------------------------------------------------

  def test_limiter_reset_clears_stats
    seed_limiter
    Wurk.redis { |c| c.call('HSET', "lmtr-stats:#{@limiter}", 'held', '7') }

    post "/wurk/api/limiters/#{@limiter}/reset"

    assert_ok
    assert json_body[:ok]
    assert_equal(0, Wurk.redis { |c| c.call('EXISTS', "lmtr-stats:#{@limiter}").to_i })
  end

  def test_limiter_substr_filter
    seed_limiter
    get "/wurk/api/limiters?substr=#{@ns.split(':').last}"

    assert_ok
    row = json_body.find { |r| r[:name] == @limiter }

    refute_nil row
  end

  # --- Periodic actions -------------------------------------------------

  def test_pause_cron_sets_flag
    seed_loop

    post "/wurk/api/cron/#{@lid}/pause"

    assert_ok
    assert_predicate Wurk::Cron::LoopSet.new.fetch(@lid), :paused?
  end

  def test_unpause_cron_clears_flag
    seed_loop(paused: '1')

    post "/wurk/api/cron/#{@lid}/unpause"

    assert_ok
    refute_predicate Wurk::Cron::LoopSet.new.fetch(@lid), :paused?
  end

  def test_pause_unknown_returns_404
    post '/wurk/api/cron/no-such/pause'

    assert_equal 404, last_response.status
  end

  def test_enqueue_cron_pushes_job
    seed_loop(queue: @queue)

    post "/wurk/api/cron/#{@lid}/enqueue"

    assert_ok
    payload = Wurk.redis { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.first

    refute_nil payload
    assert_equal @class_name, Wurk.load_json(payload)['class']
  end

  def test_enqueue_unknown_returns_404
    post '/wurk/api/cron/no-such/enqueue'

    assert_equal 404, last_response.status
  end

  def test_cron_history_envelope
    seed_loop
    entry = Wurk.dump_json([Time.now.to_i, 'jid-1'])
    Wurk.redis { |c| c.call('LPUSH', "#{Wurk::Cron::HISTORY_PREFIX}#{@lid}", entry) }

    get "/wurk/api/cron/#{@lid}/history"

    assert_ok
    assert_equal @lid, json_body[:lid]
    assert_equal 1, json_body[:history].size
  end

  # --- Per-class metrics ------------------------------------------------

  def test_metrics_for_job_returns_series
    get "/wurk/api/metrics/#{@class_name}?minutes=3"

    assert_ok
    assert_equal @class_name, json_body[:klass]
    assert_equal 3, json_body[:series].size
  end

  def test_metrics_for_job_rejects_oversize_minutes
    get "/wurk/api/metrics/#{@class_name}?minutes=99999"

    # clamped to MAX_MINUTES — no error.
    assert_ok
    assert_equal Wurk::Metrics::Query::MAX_MINUTES, json_body[:series].size
  end

  private

  def json_body
    ::JSON.parse(last_response.body, symbolize_names: true)
  end

  def assert_ok
    assert_equal 200, last_response.status, "non-200: body=#{last_response.body[0, 500]}"
  end

  def push_to_queue(args)
    payload = job_payload(args)
    Wurk.redis do |c|
      c.call('SADD', 'queues', @queue)
      c.call('LPUSH', "queue:#{@queue}", Wurk.dump_json(payload))
    end
    payload['jid']
  end

  def push_to_zset(name, args)
    payload = job_payload(args)
    Wurk.redis { |c| c.call('ZADD', name, ::Time.now.to_f.to_s, Wurk.dump_json(payload)) }
    payload['jid']
  end

  def job_payload(args)
    {
      'class' => @class_name,
      'args' => args,
      'queue' => @queue,
      'jid' => SecureRandom.hex(12),
      'created_at' => ::Time.now.to_f,
      'enqueued_at' => ::Time.now.to_f,
      'retry_count' => 0
    }
  end

  def cleanup_zset(conn, key)
    conn.call('ZRANGEBYSCORE', key, '-inf', '+inf').each do |raw|
      parsed = begin
        Wurk.load_json(raw)
      rescue ::JSON::ParserError
        nil
      end
      next unless parsed.is_a?(Hash) && parsed['class'] == @class_name

      conn.call('ZREM', key, raw)
    end
  end

  def seed_limiter
    Wurk.redis do |c|
      c.call('SADD', Wurk::Limiter::LIST_KEY, @limiter)
      c.call('HSET', "lmtr:#{@limiter}", 'type', 'concurrent', 'fingerprint', 'fp', 'options', '{"limit":5}')
    end
  end

  def seed_loop(paused: '0', queue: 'default')
    Wurk.redis do |c|
      c.call('SADD', Wurk::Cron::PERIODIC_KEY, @lid)
      c.call(
        'HSET', "#{Wurk::Cron::LOOP_PREFIX}#{@lid}",
        'schedule', '* * * * *',
        'klass', @class_name,
        'options', JSON.dump('queue' => queue, 'args' => [1]),
        'tz', '',
        'paused', paused
      )
    end
  end
end

# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives the Web UI mutation endpoints (issue #102, spec §25.4) against the
# booted dummy app and real Redis: retry/delete/kill/requeue/clear across the
# retry, scheduled, and dead sets plus per-queue clear/delete.
#
# Like ApiEndpointsTest we talk to the engine via Rack::Test and read
# `last_response` directly.
#
# Intra-class serial: many tests POST `/wurk/api/<set>/all/<cmd>`, and those
# endpoints drain the *global* retry/scheduled/dead zsets (wire-compat with
# Sidekiq — we can't namespace them per test). A parallel `test_all_retry_*`
# can therefore re-enqueue another test's pushed jid before that test's
# `test_all_kill_*` calls kill, so kill drains an empty zset and the jid lands
# in a queue instead of dead. Exposed by COVERAGE-mode timing (CI failure on
# #209) but pre-existing. Cross-class parallelism via minitest-parallel_fork
# is unaffected — each worker still gets its own Redis DB.
class ApiMutationsTest < Wurk::Test::EngineCase
  def setup
    super
    # SameOriginGuard 403s unsafe methods lacking this header; a same-origin SPA
    # fetch always sends it, so default it for every mutation in this suite.
    header 'Sec-Fetch-Site', 'same-origin'
    @ns = "wurkmut:#{::Process.pid}:#{object_id}"
    @queue = "#{@ns}-q"
    @class_name = "ApiMutationJob@#{@ns}"
  end

  def teardown
    ::Wurk.redis do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
      conn.call('SREM', ::Wurk::Keys::PAUSED_SET, @queue)
      cleanup_zset(conn, 'retry')
      cleanup_zset(conn, 'schedule')
      cleanup_zset(conn, 'dead')
    end
    ::Wurk::Web.reset_config!
  ensure
    super
  end

  # --- Retries: single ----------------------------------------------------

  def test_retry_single_requeues_job
    score, jid = push_to_zset('retry')
    post "/wurk/api/retries/#{ekey(score, jid)}", { cmd: 'retry' }

    assert_ok
    assert_equal 1, json_body[:count]
    assert_empty fetch_set('retry')
    assert queue_has_jid?(jid), 'expected job re-enqueued onto its queue'
  end

  def test_delete_single_removes_from_retry_set
    score, jid = push_to_zset('retry')
    post "/wurk/api/retries/#{ekey(score, jid)}", { cmd: 'delete' }

    assert_ok
    assert_empty fetch_set('retry')
    refute queue_has_jid?(jid), 'delete must not re-enqueue'
  end

  def test_kill_single_moves_to_dead_set
    score, jid = push_to_zset('retry')
    post "/wurk/api/retries/#{ekey(score, jid)}", { cmd: 'kill' }

    assert_ok
    assert_empty fetch_set('retry')
    assert(fetch_set('dead').any? { |j| j['jid'] == jid }, 'expected job in dead set')
  end

  def test_single_unknown_action_is_400
    score, jid = push_to_zset('retry')
    post "/wurk/api/retries/#{ekey(score, jid)}", { cmd: 'nope' }

    assert_equal 400, last_response.status
  end

  def test_single_unknown_key_is_404
    post "/wurk/api/retries/#{ekey(123.0, 'deadbeef')}", { cmd: 'retry' }

    assert_equal 404, last_response.status
  end

  # --- Retries: bulk + all ------------------------------------------------

  def test_bulk_delete_removes_each_key
    a = push_to_zset('retry')
    b = push_to_zset('retry')
    post '/wurk/api/retries', { keys: ["#{a[0]}|#{a[1]}", "#{b[0]}|#{b[1]}"], cmd: 'delete' }

    assert_ok
    assert_equal 2, json_body[:count]
    assert_empty fetch_set('retry')
  end

  def test_all_retry_drains_set
    push_to_zset('retry')
    push_to_zset('retry')
    post '/wurk/api/retries/all/retry'

    assert_ok
    assert_operator json_body[:count], :>=, 2
    assert_empty fetch_set('retry')
  end

  def test_all_delete_clears_set
    push_to_zset('retry')
    post '/wurk/api/retries/all/delete'

    assert_ok
    assert_empty fetch_set('retry')
  end

  def test_all_kill_moves_to_dead
    _score, jid = push_to_zset('retry')
    post '/wurk/api/retries/all/kill'

    assert_ok
    assert_empty fetch_set('retry')
    assert(fetch_set('dead').any? { |j| j['jid'] == jid })
  end

  def test_all_unknown_action_is_400
    push_to_zset('retry')
    post '/wurk/api/retries/all/frobnicate'

    assert_equal 400, last_response.status
    assert_equal 1, fetch_set('retry').size, 'unknown all-action must not mutate'
  end

  def test_dead_all_kill_is_rejected
    push_to_zset('dead')
    post '/wurk/api/dead/all/kill'

    assert_equal 400, last_response.status
    assert_equal 1, fetch_set('dead').size
  end

  def test_bulk_deduplicates_repeated_keys
    score, jid = push_to_zset('retry')
    key = "#{score}|#{jid}"
    post '/wurk/api/retries', { keys: [key, key], cmd: 'retry' }

    assert_ok
    assert_equal 1, json_body[:count], 'duplicate keys must act on the entry once'
    assert_empty fetch_set('retry')
  end

  # --- Scheduled ----------------------------------------------------------

  def test_scheduled_add_to_queue_single
    score, jid = push_to_zset('schedule')
    post "/wurk/api/scheduled/#{ekey(score, jid)}", { cmd: 'add_to_queue' }

    assert_ok
    assert_empty fetch_set('schedule')
    assert queue_has_jid?(jid)
  end

  def test_scheduled_all_add_to_queue_drains_set
    push_to_zset('schedule')
    push_to_zset('schedule')
    post '/wurk/api/scheduled/all/add_to_queue'

    assert_ok
    assert_empty fetch_set('schedule')
  end

  def test_scheduled_kill_is_rejected
    score, jid = push_to_zset('schedule')
    post "/wurk/api/scheduled/#{ekey(score, jid)}", { cmd: 'kill' }

    assert_equal 400, last_response.status
  end

  # --- Dead (morgue) ------------------------------------------------------

  def test_dead_retry_single_requeues
    score, jid = push_to_zset('dead')
    post "/wurk/api/dead/#{ekey(score, jid)}", { cmd: 'retry' }

    assert_ok
    assert_empty fetch_set('dead')
    assert queue_has_jid?(jid)
  end

  def test_dead_all_retry
    push_to_zset('dead')
    post '/wurk/api/dead/all/retry'

    assert_ok
    assert_empty fetch_set('dead')
  end

  # --- Queues -------------------------------------------------------------

  def test_clear_queue_empties_list
    push_to_queue
    post "/wurk/api/queues/#{@queue}/clear"

    assert_ok
    assert_equal 0, ::Wurk::Queue.new(@queue).size
  end

  def test_delete_queue_job_by_jid
    jid = push_to_queue
    post "/wurk/api/queues/#{@queue}/delete", { jid: jid }

    assert_ok
    refute queue_has_jid?(jid)
  end

  def test_delete_queue_job_unknown_is_404
    push_to_queue
    post "/wurk/api/queues/#{@queue}/delete", { jid: 'no-such-jid' }

    assert_equal 404, last_response.status
  end

  # --- Per-queue pause / unpause (#114) -----------------------------------

  def test_pause_queue_sets_paused
    post "/wurk/api/queues/#{@queue}/pause"

    assert_ok
    assert json_body[:paused], 'response should report paused: true'
    assert_predicate ::Wurk::Queue.new(@queue), :paused?
  end

  def test_unpause_queue_clears_paused
    ::Wurk::Queue.new(@queue).pause!
    post "/wurk/api/queues/#{@queue}/unpause"

    assert_ok
    refute json_body[:paused], 'response should report paused: false'
    refute_predicate ::Wurk::Queue.new(@queue), :paused?
  end

  def test_read_only_blocks_pause
    ::Wurk::Web.configure { |c| c.read_only = true }
    post "/wurk/api/queues/#{@queue}/pause"

    assert_equal 403, last_response.status
    refute_predicate ::Wurk::Queue.new(@queue), :paused?, 'read-only must not mutate'
  end

  # --- Read-only / forgery ------------------------------------------------

  def test_read_only_blocks_mutation
    ::Wurk::Web.configure { |c| c.read_only = true }
    score, jid = push_to_zset('retry')
    post "/wurk/api/retries/#{ekey(score, jid)}", { cmd: 'delete' }

    assert_equal 403, last_response.status
    assert_equal 1, fetch_set('retry').size, 'read-only must not mutate'
  end

  private

  def json_body = ::JSON.parse(last_response.body, symbolize_names: true)

  # URL-encodes the "<score>|<jid>" route key exactly as the SPA does
  # (encodeURIComponent) so the `|` survives Rack::Test's URI parser.
  def ekey(score, jid) = ::CGI.escape("#{score}|#{jid}")

  def assert_ok
    assert_equal 200, last_response.status, "non-200 response: body=#{last_response.body[0, 500]}"
  end

  def job_payload
    {
      'class' => @class_name,
      'args' => [1, 2],
      'queue' => @queue,
      'jid' => SecureRandom.hex(12),
      'created_at' => ::Time.now.to_f,
      'enqueued_at' => ::Time.now.to_f,
      'retry_count' => 1,
      'error_class' => 'RuntimeError',
      'error_message' => 'boom'
    }
  end

  def push_to_queue
    payload = job_payload
    ::Wurk.redis do |c|
      c.call('SADD', 'queues', @queue)
      c.call('LPUSH', "queue:#{@queue}", ::Wurk.dump_json(payload))
    end
    payload['jid']
  end

  # Returns [score, jid] so callers can build the "<score>|<jid>" route key.
  def push_to_zset(name)
    payload = job_payload
    score = ::Time.now.to_f
    ::Wurk.redis { |c| c.call('ZADD', name, score.to_s, ::Wurk.dump_json(payload)) }
    [score, payload['jid']]
  end

  # Parsed payloads for this test's class only, across a whole zset.
  def fetch_set(name)
    ::Wurk.redis { |c| c.call('ZRANGEBYSCORE', name, '-inf', '+inf') }
          .map { |raw| ::Wurk.load_json(raw) }
          .select { |h| h['class'] == @class_name }
  end

  def queue_has_jid?(jid)
    !::Wurk::Queue.new(@queue).find_job(jid).nil?
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

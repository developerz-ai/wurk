# frozen_string_literal: true

require_relative '../engine_test_helper'

# Proves Wurk::SameOriginGuard (#101 web/API hardening) actually rejects
# forged cross-site mutations and lets real same-origin traffic through, for
# every mutating route the engine exposes — not just the handful individual
# suites happen to cover with the header pre-set in `setup`.
#
# Route-table-driven: ALL_MUTATING_ROUTES enumerates every non-GET route in
# config/routes.rb (ApiController + ExtensionsController). The 403 direction
# needs no seeded data — the guard runs in a `before_action` and rejects
# before the action ever touches Redis, so arbitrary path params are safe to
# probe. The 2xx direction drops the three `.../all/:cmd` bulk-drain routes
# (retries/scheduled/dead): they UNLINK the *global* zset wholesale, and other
# parallelize_me! suites in this worker's Redis DB push fixtures onto those
# same un-namespaced keys — draining them here would flake sibling tests for
# a property those suites already cover directly (ApiMutationsTest).
class CsrfSameOriginTest < Wurk::Test::EngineCase
  parallelize_me!

  def setup
    super
    @ns = "wurkcsrf:#{::Process.pid}:#{object_id}"
    @queue = "#{@ns}-clear-q"
    @del_queue = "#{@ns}-del-q"
    @class_name = "CsrfJob@#{@ns}"
    @lid = ::Digest::SHA1.hexdigest(@ns)[0, 16]
    @limiter = "lmt-#{@ns}"
    @identity = "host-#{@ns}:1:aa"

    @del_jid = seed_queue_job(@del_queue)
    @retry_key = seed_zset_entry('retry')
    @sched_key = seed_zset_entry('schedule')
    @dead_key = seed_zset_entry('dead')
    seed_cron_loop
    seed_process(@identity)
  end

  def teardown
    ::Wurk.redis do |c|
      c.call('DEL', "queue:#{@del_queue}")
      c.call('SREM', 'queues', @del_queue, @queue)
      c.call('SREM', ::Wurk::Keys::PAUSED_SET, @queue)
      cleanup_zset(c, 'retry')
      cleanup_zset(c, 'schedule')
      cleanup_zset(c, 'dead')
      c.call('SREM', ::Wurk::Cron::PERIODIC_KEY, @lid)
      c.call('DEL', "#{::Wurk::Cron::LOOP_PREFIX}#{@lid}", "#{::Wurk::Cron::HISTORY_PREFIX}#{@lid}")
      c.call('SREM', ::Wurk::Keys::PROCESSES, @identity)
      c.call('DEL', @identity, "#{@identity}-signals")
    end
  ensure
    super
  end

  # Every mutating route the engine exposes, GET/HEAD/OPTIONS excluded.
  # Params are placeholders where the 403 check never reaches the action.
  def all_mutating_routes
    [
      { path: "/wurk/api/queues/#{@queue}/clear" },
      { path: "/wurk/api/queues/#{@del_queue}/delete", params: { jid: @del_jid } },
      { path: "/wurk/api/queues/#{@queue}/pause" },
      { path: "/wurk/api/queues/#{@queue}/unpause" },
      { path: '/wurk/api/retries', params: { cmd: 'delete', keys: [] } },
      { path: '/wurk/api/retries/all/delete' },
      { path: "/wurk/api/retries/#{@retry_key}", params: { cmd: 'delete' } },
      { path: '/wurk/api/scheduled', params: { cmd: 'delete', keys: [] } },
      { path: '/wurk/api/scheduled/all/delete' },
      { path: "/wurk/api/scheduled/#{@sched_key}", params: { cmd: 'delete' } },
      { path: '/wurk/api/dead', params: { cmd: 'delete', keys: [] } },
      { path: '/wurk/api/dead/all/delete' },
      { path: "/wurk/api/dead/#{@dead_key}", params: { cmd: 'retry' } },
      { path: '/wurk/api/busy/quiet', params: { identity: @identity } },
      { path: '/wurk/api/busy/stop', params: { identity: @identity } },
      { path: "/wurk/api/limiters/#{@limiter}/reset" },
      { path: "/wurk/api/cron/#{@lid}/pause" },
      { path: "/wurk/api/cron/#{@lid}/unpause" },
      { path: "/wurk/api/cron/#{@lid}/enqueue" },
      { path: "/wurk/ext/csrf-unregistered-#{@ns}" }
    ].freeze
  end

  # `.../all/:cmd` bulk-drain routes wipe the whole global zset — excluded
  # here (see class comment); everything else must reach the controller and
  # succeed for a genuine same-origin request.
  def safe_2xx_routes
    all_mutating_routes.reject { |r| r[:path].include?('/all/') }
  end

  def test_every_mutating_route_403s_without_same_origin_header
    all_mutating_routes.each do |route|
      post route[:path], route[:params] || {}

      assert_equal 403, last_response.status,
                   "expected 403 for POST #{route[:path]} without Sec-Fetch-Site, got #{last_response.status}"
    end
  end

  def test_every_safe_route_succeeds_with_same_origin_header
    header 'Sec-Fetch-Site', 'same-origin'

    safe_2xx_routes.each do |route|
      post route[:path], route[:params] || {}

      assert_includes 200..299, last_response.status,
                      "expected 2xx for POST #{route[:path]} with Sec-Fetch-Site: same-origin, " \
                      "got #{last_response.status}: #{last_response.body[0, 300]}"
    end
  end

  # Reads (GET, incl. SSE) are safe methods — SameOriginGuard never blocks
  # them, header or not. Sanity check so the guard's SAFE_METHODS allowlist
  # doesn't regress into blocking dashboard reads.
  def test_get_requests_are_never_blocked
    get '/wurk/api/stats'

    assert_equal 200, last_response.status
  end

  private

  def seed_queue_job(queue)
    jid = ::SecureRandom.hex(12)
    payload = {
      'class' => @class_name, 'args' => [1], 'queue' => queue, 'jid' => jid,
      'created_at' => ::Time.now.to_f, 'enqueued_at' => ::Time.now.to_f, 'retry_count' => 0
    }
    ::Wurk.redis do |c|
      c.call('SADD', 'queues', queue)
      c.call('LPUSH', "queue:#{queue}", ::Wurk.dump_json(payload))
    end
    jid
  end

  # Seeds one entry in the given global zset, returning its URL-encoded
  # "<score>|<jid>" route key (matches the SPA's encodeURIComponent).
  def seed_zset_entry(name)
    score = ::Time.now.to_f
    jid = ::SecureRandom.hex(12)
    payload = {
      'class' => @class_name, 'args' => [1], 'queue' => @queue, 'jid' => jid,
      'created_at' => score, 'enqueued_at' => score, 'retry_count' => 1,
      'error_class' => 'RuntimeError', 'error_message' => 'boom'
    }
    ::Wurk.redis { |c| c.call('ZADD', name, score.to_s, ::Wurk.dump_json(payload)) }
    ::CGI.escape("#{score}|#{jid}")
  end

  def seed_cron_loop
    ::Wurk.redis do |c|
      c.call('SADD', ::Wurk::Cron::PERIODIC_KEY, @lid)
      c.call(
        'HSET', "#{::Wurk::Cron::LOOP_PREFIX}#{@lid}",
        'schedule', '* * * * *', 'klass', @class_name,
        'options', ::JSON.dump('queue' => @queue, 'args' => [1]), 'tz', '', 'paused', '0'
      )
    end
  end

  def seed_process(identity)
    info = {
      'hostname' => 'testhost', 'pid' => 1234, 'tag' => @ns, 'concurrency' => 5,
      'queues' => ['default'], 'identity' => identity, 'version' => ::Wurk::VERSION, 'embedded' => false
    }
    ::Wurk.redis do |c|
      c.call('SADD', ::Wurk::Keys::PROCESSES, identity)
      c.call('HSET', identity, 'info', ::Wurk.dump_json(info),
             'busy', '0', 'beat', ::Time.now.to_f.to_s, 'quiet', 'false', 'rss', '1000',
             'rtt_us', '10', 'concurrency', '5')
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

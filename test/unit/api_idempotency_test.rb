# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'digest'
require 'json'
require 'stringio'

# Slice 07 — `Idempotency-Key` replay protection on the produce plane.
#
# A producer whose connection drops mid-POST cannot tell a lost request from a
# lost response, so it retries; without this that retry is a second job. Every
# assertion below is on what actually landed in Redis, because a replay that
# answered correctly and enqueued anyway would be the only failure worth
# catching.
#
# Parallel safety: queue and class names carry a per-instance namespace, and
# the worker's Redis DB is flushed after every test (RedisNamespace).
class ApiIdempotencyTest < Wurk::Test::UnitCase
  parallelize_me!

  ADMIN_TOKEN = 'api-idem-admin-token-0123456789'
  OTHER_TOKEN = 'api-idem-other-token-0123456789'

  # A middleware that fails the push the way an unreachable Redis would: after
  # the key is claimed, before there is an answer to pin to it.
  BoomMiddleware = Class.new do
    include Wurk::Middleware::ClientMiddleware

    def call(*) = raise('boom')
  end

  # What a `collapse:`/`unique_for:` drop does to a duplicate.
  HaltMiddleware = Class.new do
    include Wurk::Middleware::ClientMiddleware

    def call(*) = nil
  end

  def setup
    super
    @ns = "#{Process.pid}_#{object_id}"
    @queue = "q-#{@ns}"
    @class_name = "ApiIdemWorker#{@ns}"
    @pool = Wurk.configuration.redis_pool
  end

  # --- The replay ---------------------------------------------------------

  def test_a_repeated_key_enqueues_once_and_replays_the_first_answer
    first = post('/v1/jobs', job, key: 'k1')
    second = post('/v1/jobs', job, key: 'k1')

    assert_equal 201, first[0]
    assert_equal first[0], second[0]
    assert_equal first[2], second[2]
    assert_equal 1, queued_payloads.size
    assert_equal first[2]['jid'], queued_payloads.fetch(0)['jid']
  end

  def test_a_replay_says_so
    post('/v1/jobs', job, key: 'k1')
    _status, headers, = post('/v1/jobs', job, key: 'k1')

    assert_equal 'true', headers[Wurk::API::Idempotency::REPLAY_HEADER]
    assert_equal 'application/json', headers['content-type']
  end

  def test_a_first_answer_is_not_marked_as_a_replay
    _status, headers, = post('/v1/jobs', job, key: 'k1')

    refute headers.key?(Wurk::API::Idempotency::REPLAY_HEADER)
  end

  def test_different_keys_are_different_requests
    post('/v1/jobs', job, key: 'k1')
    post('/v1/jobs', job, key: 'k2')

    assert_equal 2, queued_payloads.size
  end

  def test_no_key_means_no_record_and_no_round_trip
    post('/v1/jobs', job)
    post('/v1/jobs', job)

    assert_equal 2, queued_payloads.size
    assert_empty idempotency_keys
  end

  def test_the_bulk_route_is_guarded_too
    first = post('/v1/jobs/bulk', job(args: [[1], [2]]), key: 'k1')
    second = post('/v1/jobs/bulk', job(args: [[1], [2]]), key: 'k1')

    assert_equal first[2]['jids'], second[2]['jids']
    assert_equal 2, queued_payloads.size
  end

  # --- Scoping ------------------------------------------------------------

  # The key is a string the client chose: two producers that both sent `1` must
  # not see each other's jids.
  def test_a_key_belongs_to_the_credential_that_chose_it
    mine = post('/v1/jobs', job, key: 'k1')
    theirs = post('/v1/jobs', job, key: 'k1', token: OTHER_TOKEN)

    refute_equal mine[2]['jid'], theirs[2]['jid']
    assert_equal 2, queued_payloads.size
  end

  def test_the_same_key_on_two_routes_addresses_two_requests
    post('/v1/jobs', job, key: 'k1')
    status, = post('/v1/jobs/bulk', job(args: [[1]]), key: 'k1')

    assert_equal 201, status
    assert_equal 2, queued_payloads.size
  end

  # Hashed, so what a client chose never reaches Redis in the clear.
  def test_the_clients_own_key_never_reaches_redis
    post('/v1/jobs', job, key: 'a-very-recognisable-key')

    assert_equal 1, idempotency_keys.size
    refute_includes idempotency_keys.first, 'recognisable'
  end

  # --- Collisions ---------------------------------------------------------

  def test_the_same_key_with_a_different_body_is_a_client_bug
    post('/v1/jobs', job, key: 'k1')
    status, headers, body = post('/v1/jobs', job(args: [1]), key: 'k1')

    assert_equal 409, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'idempotency_key_reused', body['type']
    assert_equal 'Idempotency Key Reused', body['title']
    assert_equal 1, queued_payloads.size
  end

  def test_a_claim_still_in_flight_answers_try_again
    claim('k1', job)
    status, headers, body = post('/v1/jobs', job, key: 'k1')

    assert_equal 409, status
    assert_equal 'request_in_progress', body['type']
    assert_equal '1', headers['retry-after']
    assert_empty queued_payloads
  end

  # A record has to be read back under contention, so an unreadable one
  # degrades to "still in flight" rather than to an exception on the request
  # path — the safe answer, since it never enqueues a second job.
  def test_an_unreadable_record_degrades_to_in_progress
    @pool.with { |conn| conn.call('SET', slot_for('k1'), 'not a record', 'EX', 60) }
    status, _headers, body = post('/v1/jobs', job, key: 'k1')

    assert_equal 'request_in_progress', body['type']
    assert_equal 409, status
    assert_empty queued_payloads
  end

  # --- Releasing --------------------------------------------------------

  # A rejected body is a request the client should be able to correct and send
  # again under the same key.
  def test_a_refused_request_does_not_burn_the_key
    status, = post('/v1/jobs', job(at: 'soon'), key: 'k1')

    assert_equal 400, status
    assert_empty idempotency_keys

    status, = post('/v1/jobs', job, key: 'k1')

    assert_equal 201, status
  end

  # A raise is a request whose outcome nobody knows, so nothing is pinned to
  # the key — the client's retry gets a real attempt, not a replayed 500.
  def test_a_raising_push_does_not_burn_the_key
    status, = with_client_middleware(BoomMiddleware) { post('/v1/jobs', job, key: 'k1') }

    assert_equal 500, status
    assert_empty idempotency_keys

    status, = post('/v1/jobs', job, key: 'k1')

    assert_equal 201, status
  end

  # A middleware-halted push is a real, successful outcome — the producer's own
  # policy working — so it is replayed like any other 2xx.
  def test_a_halted_push_is_recorded_like_any_other_success
    status, _headers, body = with_client_middleware(HaltMiddleware) { post('/v1/jobs', job, key: 'k1') }

    assert_equal 200, status
    assert_nil body['jid']

    _status, headers, = post('/v1/jobs', job, key: 'k1')

    assert_equal 'true', headers[Wurk::API::Idempotency::REPLAY_HEADER]
  end

  # --- Lifetime -----------------------------------------------------------

  def test_a_record_expires_on_the_configured_window
    @config = build_config { |cfg| cfg.api_idempotency_ttl = 120 }
    post('/v1/jobs', job, key: 'k1')

    assert_in_delta 120, ttl_of(slot_for('k1')), 5
  end

  # KEEPTTL, so the window belongs to the first request rather than restarting
  # when its answer is written — and XX, so a claim whose window lapsed
  # mid-flight is not resurrected as a record that never expires.
  def test_the_answer_does_not_restart_the_window
    @config = build_config { |cfg| cfg.api_idempotency_ttl = 120 }
    post('/v1/jobs', job, key: 'k1')
    slot = slot_for('k1')
    @pool.with { |conn| conn.call('EXPIRE', slot, 30) }
    post('/v1/jobs', job, key: 'k1')

    assert_operator ttl_of(slot), :<=, 30
  end

  # --- The key itself -----------------------------------------------------

  def test_a_key_that_could_not_survive_a_header_is_refused
    ["has spaces#{'a' * 5}", "tab\there", "nul\0here", 'ü', 'x' * 256, ''].each do |key|
      status, _headers, body = post('/v1/jobs', job, key: key)

      assert_equal 400, status, "#{key.inspect} was accepted"
      assert_equal 'invalid_request', body['type']
    end
    assert_empty queued_payloads
  end

  private

  def app = @app ||= Wurk::API::App.new(config: config)

  def config
    @config ||= build_config
  end

  def build_config
    Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
      cfg.api_token(OTHER_TOKEN, scopes: %i[admin])
      cfg.api_enqueue_classes = [@class_name]
      yield cfg if block_given?
    end
  end

  def job(**overrides)
    { 'class' => @class_name, 'args' => [], 'queue' => @queue }.merge(overrides.transform_keys(&:to_s))
  end

  def queued_payloads
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end

  def idempotency_keys
    @pool.with { |conn| conn.call('KEYS', "#{Wurk::Keys::IDEMPOTENCY_PREFIX}*") }
  end

  def ttl_of(slot) = @pool.with { |conn| conn.call('TTL', slot) }

  # Locates a record the way production does, rather than restating the digest
  # here — a test that computed its own would still pass if the two drifted.
  def slot_for(key, path: '/v1/jobs', token: ADMIN_TOKEN)
    request = Wurk::API::Request.new(env_for('POST', path, token: token))
    request.principal = Wurk::API::Auth.authenticate(request, config)
    Wurk::API::Idempotency.slot_for(request, key)
  end

  # Leaves a claim with no answer pinned to it — what a request still in flight
  # looks like from another process.
  def claim(key, payload)
    digest = Digest::SHA256.hexdigest(JSON.generate(payload))
    record = Wurk::API::Idempotency.encode(Wurk::API::Idempotency::PENDING, digest, '')
    @pool.with { |conn| conn.call('SET', slot_for(key), record, 'EX', 60) }
  end

  def with_client_middleware(klass)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      Wurk.configuration.client_middleware.add(klass)
      yield
    ensure
      Wurk.configuration.client_middleware.remove(klass)
    end
  end

  def post(path, payload, key: nil, token: ADMIN_TOKEN)
    raw = JSON.generate(payload)
    env = env_for('POST', path, body: raw, token: token)
    env['HTTP_IDEMPOTENCY_KEY'] = key if key
    status, headers, body = app.call(env)
    [status, headers, JSON.parse(body.join)]
  end

  def env_for(method, path, body: '', token: ADMIN_TOKEN)
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => '',
      'CONTENT_TYPE' => 'application/json',
      'CONTENT_LENGTH' => body.bytesize.to_s,
      'HTTP_AUTHORIZATION' => "Bearer #{token}",
      'rack.input' => StringIO.new(body),
      'rack.errors' => StringIO.new
    }
  end
end
